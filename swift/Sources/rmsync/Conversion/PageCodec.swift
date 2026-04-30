import Foundation
import RMScene

/// In-process encoder/decoder for reMarkable v6 ``.rm`` pages.
///
/// Replaces the previous Python subprocess bridge. The ``RMScene``
/// target in this repo is a Swift port of Rick Lupton's Python
/// ``rmscene`` (https://github.com/ricklupton/rmscene, MIT) and
/// produces byte-identical output when encoding at
/// ``RemarkableVersion("3.4")``, which is what we use across the
/// daemon.
///
/// Two operations mirror the Python bridge's ``parse_page`` and
/// ``render_page`` commands, minus the base64 + JSON framing:
///
///   - ``parsePage(_:)`` — .rm bytes → Markdown text (empty string when
///     the page has no typed text, i.e. handwriting-only).
///   - ``renderPage(text:authorUUID:)`` — Markdown text + stable author
///     UUID → .rm bytes. The author UUID must be the same across every
///     push of the same document (see CHANGES_FROM_SPEC.md) or the
///     tablet's CRDT engine will interleave text character-by-character.
///
/// No actor: both operations are pure functions over their inputs and
/// hold no shared state. Callers don't need to serialize anything.
enum PageCodec {

    // MARK: - public API

    /// Parse one .rm page to Markdown. Returns the empty string when the
    /// page has no typed text (handwriting-only notebooks / drawing
    /// pages); our pull path treats that as "skip".
    ///
    /// Block paragraphs join with `\n\n` (canonical CommonMark paragraph
    /// break) so pandoc renders the file the same way the tablet shows
    /// it. Adjacent items of the same list family stay tight (single
    /// `\n`). Empty model paragraphs collapse into the block separator
    /// rather than emitting extra blank lines — see ``renderPage`` for
    /// the symmetric push-side normalization.
    static func parsePage(_ rmBytes: Data) throws -> String {
        let decoder = RMSceneDecoder()
        let tree = try decoder.decodeTree(from: rmBytes)
        guard let rootText = tree.rootText else { return "" }
        let doc = try TextDocument.fromSceneItem(rootText)

        let listStyles: Set<ParagraphStyle> = [.bullet, .bullet2, .checkbox, .checkboxChecked]
        var out = ""
        var prevWasContent = false
        var prevWasListItem = false
        var pendingBlockBreak = false   // empty paragraph seen since last content
        for paragraph in doc.contents {
            let style = paragraph.style.value
            let prefix = Self.prefix(for: style)
            let body = Self.render(paragraph.contents)
            let isListItem = listStyles.contains(style)
            let isEmpty = body.isEmpty && prefix.isEmpty

            if isEmpty {
                // Defer the block break until we see another content
                // paragraph — otherwise a trailing empty paragraph (which
                // any text ending in `\n` produces) would emit a phantom
                // blank line at the end.
                if prevWasContent {
                    pendingBlockBreak = true
                    prevWasListItem = false
                }
                continue
            }

            if prevWasContent {
                if pendingBlockBreak {
                    out += "\n\n"
                } else if prevWasListItem && isListItem {
                    out += "\n"
                } else {
                    out += "\n\n"
                }
            }
            pendingBlockBreak = false
            out += prefix + body
            prevWasContent = true
            prevWasListItem = isListItem
        }
        return out.isEmpty ? "" : out + "\n"
    }

    /// Serialize Markdown into a v6 ``.rm`` byte stream using a stable
    /// author UUID, preserving every paragraph and inline style the
    /// tablet supports.
    ///
    /// Two transforms run before the bytes hit the encoder:
    ///
    ///   1. **Blank-line collapse.** `\n{2,}` → `\n`. The tablet
    ///      renders empty paragraphs as visible blank lines on top of
    ///      its own paragraph spacing, which doesn't match pandoc's
    ///      collapse-to-one-paragraph-break rule. Normalising here
    ///      keeps the tablet view ≈ pandoc PDF for the same source.
    ///   2. **Markdown → styled paragraphs.** Each line's leading
    ///      prefix (`# `, `## `, `- `, `  - `, `- [ ] `, `- [x] `) maps
    ///      to a tablet ``ParagraphStyle``; the prefix is stripped
    ///      from the body. Within each body, `***x***` / `**x**` /
    ///      `*x*` runs become inline bold / italic / bold+italic spans.
    ///
    /// The resulting `.rm` round-trips back through ``parsePage`` to
    /// the same canonical Markdown.
    static func renderPage(text: String, authorUUID: String) throws -> Data {
        guard let uuid = UUID(uuidString: authorUUID) else {
            throw CodecError.invalidAuthorUUID(authorUUID)
        }
        let normalized = text.replacingOccurrences(
            of: #"\n{2,}"#, with: "\n", options: .regularExpression
        )
        let paragraphs = parseMarkdown(normalized)
        let encoder = RMSceneEncoder()
        let blocks = encoder.richTextDocument(paragraphs, authorID: uuid)
        // Wire version for ``.rm`` files we write. Verified
        // byte-identical against Python ``rmscene.write_blocks`` output
        // for ``simple_text_document``; any v3.4+ produces the same
        // bytes for plain-text documents because later revisions only
        // add fields our simple encoding path never touches.
        //
        // Constructed per-call because the upstream type isn't
        // ``Sendable`` yet and we don't want to modify vendored code.
        return try encoder.encode(blocks, version: RemarkableVersion("3.4"))
    }

    // MARK: - private

    /// Markdown prefix for each paragraph style the tablet produces.
    /// Mirrors the table in the original Python bridge.
    private static func prefix(for style: ParagraphStyle) -> String {
        switch style {
        case .plain, .basic: return ""
        case .heading: return "# "
        case .bold: return "## "
        case .bullet: return "- "
        case .bullet2: return "  - "
        case .checkbox: return "- [ ] "
        case .checkboxChecked: return "- [x] "
        }
    }

    /// Turn an array of CRDT string runs into a single Markdown line,
    /// applying inline `**bold**` / `*italic*` / `***both***` wrappers.
    private static func render(_ spans: [CrdtString]) -> String {
        var out = ""
        for span in spans {
            var text = span.string
            if text.isEmpty || text == "\n" { continue }

            let bold = span.style.fontWeight == .bold
            let italic = span.style.fontStyle == .italic
            if bold && italic {
                text = "***\(text)***"
            } else if bold {
                text = "**\(text)**"
            } else if italic {
                text = "*\(text)*"
            }
            out += text
        }
        while out.hasSuffix("\n") { out.removeLast() }
        return out
    }

    // MARK: - markdown → styled paragraphs (push side)

    /// Inverse of the ``prefix(for:)`` table: detect a leading Markdown
    /// prefix on the line, return the corresponding ``ParagraphStyle``,
    /// and the rest of the line (the prefix stripped). Order matters —
    /// we check longer/more-specific prefixes (`- [ ] `, `  - `) before
    /// shorter ones (`- `) so a checkbox isn't mis-classified as a
    /// bullet, and a nested bullet isn't mis-classified as plain.
    private static func paragraphStyle(for line: String) -> (ParagraphStyle, String) {
        if line.hasPrefix("- [ ] ") {
            return (.checkbox, String(line.dropFirst(6)))
        }
        if line.hasPrefix("- [x] ") {
            return (.checkboxChecked, String(line.dropFirst(6)))
        }
        if line.hasPrefix("  - ") {
            return (.bullet2, String(line.dropFirst(4)))
        }
        if line.hasPrefix("- ") {
            return (.bullet, String(line.dropFirst(2)))
        }
        if line.hasPrefix("## ") {
            return (.bold, String(line.dropFirst(3)))
        }
        if line.hasPrefix("# ") {
            return (.heading, String(line.dropFirst(2)))
        }
        return (.plain, line)
    }

    /// Parse inline `**bold**` / `*italic*` / `***both***` markers in a
    /// stripped paragraph body into ``RMSceneEncoder.Span`` runs.
    /// Mirrors the wrappers ``render(_:)`` emits on pull, so a span
    /// round-trips: span → markdown → span. Only the three marker
    /// shapes our pull side produces are recognized; other Markdown
    /// inline syntax (links, code, strikethrough) is left as literal
    /// text — the tablet doesn't render it anyway.
    private static func parseInline(_ body: String) -> [RMSceneEncoder.Span] {
        var spans: [RMSceneEncoder.Span] = []
        var buffer = ""
        var bold = false
        var italic = false

        func flush() {
            guard !buffer.isEmpty else { return }
            spans.append(RMSceneEncoder.Span(
                text: buffer,
                style: InlineTextStyle(
                    fontWeight: bold ? .bold : .normal,
                    fontStyle: italic ? .italic : .normal
                )
            ))
            buffer = ""
        }

        var i = body.startIndex
        while i < body.endIndex {
            let rest = body[i...]
            if rest.hasPrefix("***") {
                flush()
                bold.toggle()
                italic.toggle()
                i = body.index(i, offsetBy: 3)
            } else if rest.hasPrefix("**") {
                flush()
                bold.toggle()
                i = body.index(i, offsetBy: 2)
            } else if rest.hasPrefix("*") {
                flush()
                italic.toggle()
                i = body.index(i, offsetBy: 1)
            } else {
                buffer.append(body[i])
                i = body.index(after: i)
            }
        }
        flush()
        return spans
    }

    /// Top-level parser: split on `\n`, classify each line by paragraph
    /// prefix, parse inline markers in the stripped body. Empty lines
    /// (which our blank-line collapse should already have eliminated,
    /// but a leading or trailing `\n` can still produce one) become
    /// empty paragraphs with `.plain` style. The pull side renders an
    /// empty `.plain` paragraph as nothing, so a stray empty paragraph
    /// here is harmless even if not ideal.
    static func parseMarkdown(_ text: String) -> [RMSceneEncoder.StyledParagraph] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var paragraphs: [RMSceneEncoder.StyledParagraph] = []
        for line in lines {
            let (style, stripped) = paragraphStyle(for: String(line))
            let spans = parseInline(stripped)
            paragraphs.append(RMSceneEncoder.StyledParagraph(style: style, spans: spans))
        }
        // A trailing newline on the input produces an empty trailing
        // line (omittingEmptySubsequences: false). Drop it so the
        // tablet model doesn't gain a trailing empty paragraph the user
        // didn't actually type.
        if let last = paragraphs.last,
           last.style == .plain,
           last.spans.allSatisfy({ $0.text.isEmpty }) {
            paragraphs.removeLast()
        }
        return paragraphs.isEmpty
            ? [RMSceneEncoder.StyledParagraph(style: .plain, spans: [])]
            : paragraphs
    }

    enum CodecError: Error, CustomStringConvertible, Sendable {
        case invalidAuthorUUID(String)

        var description: String {
            switch self {
            case .invalidAuthorUUID(let s):
                return "not a valid UUID string: \(s)"
            }
        }
    }
}
