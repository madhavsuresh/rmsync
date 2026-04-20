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
    static func parsePage(_ rmBytes: Data) throws -> String {
        let decoder = RMSceneDecoder()
        let tree = try decoder.decodeTree(from: rmBytes)
        guard let rootText = tree.rootText else { return "" }
        let doc = try TextDocument.fromSceneItem(rootText)

        var lines: [String] = []
        for paragraph in doc.contents {
            let prefix = Self.prefix(for: paragraph.style.value)
            let body = Self.render(paragraph.contents)
            if !body.isEmpty || !prefix.isEmpty {
                lines.append(prefix + body)
            }
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// Serialize plain text into a v6 .rm byte stream using a stable
    /// author UUID.
    static func renderPage(text: String, authorUUID: String) throws -> Data {
        guard let uuid = UUID(uuidString: authorUUID) else {
            throw CodecError.invalidAuthorUUID(authorUUID)
        }
        let encoder = RMSceneEncoder()
        let blocks = encoder.simpleTextDocument(text, authorID: uuid)
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
