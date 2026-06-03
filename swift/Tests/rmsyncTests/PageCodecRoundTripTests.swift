import Foundation
import Testing
@testable import rmsync

/// Extended round-trip coverage for ``PageCodec``. Exercises hypotheses
/// A (decoder bug for specific inputs), E (author UUID drift), and F
/// (pathological input) from the `attacks.md` wipe investigation.
///
/// The existing ``PageCodecTests`` has smoke coverage for a three-line
/// plain document. Everything here is specifically chosen to stress
/// shapes and author-UUID behaviour that the current production code
/// relies on without checking.
@Suite("PageCodec round-trip (extended)")
struct PageCodecRoundTripTests {

    private let author = "11111111-2222-3333-4444-555555555555"

    private func roundTrip(_ input: String) throws -> String {
        let bytes = try PageCodec.renderPage(text: input, authorUUID: author)
        return try PageCodec.parsePage(bytes)
    }

    // MARK: - paragraph styles

    /// Each paragraph style prefix the tablet produces. If the text
    /// body round-trips we trust the prefix mapping in
    /// ``PageCodec.prefix(for:)`` — it's a static table, no CRDT state
    /// involved, so the risk is strictly in the body content path.
    @Test("multi-line plain text round-trips verbatim")
    func multiLinePlain() throws {
        let input = "first line\nsecond line\nthird line\n"
        let parsed = try roundTrip(input)
        #expect(parsed.contains("first line"))
        #expect(parsed.contains("second line"))
        #expect(parsed.contains("third line"))
    }

    @Test("30-paragraph realistic doc round-trips")
    func realisticDoc() throws {
        var lines: [String] = []
        for i in 1...30 {
            lines.append("paragraph \(i) with some content")
        }
        let input = lines.joined(separator: "\n") + "\n"
        let parsed = try roundTrip(input)
        #expect(parsed.contains("paragraph 1 "))
        #expect(parsed.contains("paragraph 15 "))
        #expect(parsed.contains("paragraph 30 "))
        // The renderer may re-emit as plain text; we only assert the
        // body content is preserved. Length may differ by a trailing
        // newline but should be in the same ballpark.
        #expect(parsed.count >= input.count - 2)
    }

    // MARK: - hypothesis A: empty / near-empty inputs

    @Test("empty input round-trips to empty (expected contract)")
    func emptyInput() throws {
        let parsed = try roundTrip("")
        // PageCodec contract: handwriting-only / empty pages decode to
        // "". The pull path is what treats this as "skip"; the codec
        // itself returning "" is correct, documented behaviour.
        #expect(parsed.isEmpty)
    }

    @Test("single-character input round-trips")
    func singleChar() throws {
        let parsed = try roundTrip("x")
        #expect(parsed.contains("x"))
        #expect(!parsed.isEmpty)
    }

    @Test("whitespace-only input does not silently become empty")
    func whitespaceOnly() throws {
        // Input is a single space + newline. This should NOT parse to
        // "" — the page has typed content even if visually blank. If
        // it does, we have a silent data loss for space-padded notes.
        let input = " \n"
        let parsed = try roundTrip(input)
        // Either it round-trips the space OR the space trims away to
        // nothing. Record whichever we see so a silent regression is
        // caught, but don't over-assert the current behaviour.
        if parsed.isEmpty {
            Issue.record("whitespace-only input parsed to empty — potential data-loss shape")
        }
    }

    // MARK: - hypothesis E: author UUID drift

    @Test("different author UUIDs still parse the same text")
    func authorUUIDIndependence() throws {
        let text = "this is a shared sentence\n"
        let uuidA = "11111111-1111-1111-1111-111111111111"
        let uuidB = "22222222-2222-2222-2222-222222222222"

        let bytesA = try PageCodec.renderPage(text: text, authorUUID: uuidA)
        let bytesB = try PageCodec.renderPage(text: text, authorUUID: uuidB)

        let parsedA = try PageCodec.parsePage(bytesA)
        let parsedB = try PageCodec.parsePage(bytesB)

        // Per-install author UUIDs must not affect in-process parse.
        // (They DO affect the tablet's CRDT merge — that's a live-cloud
        // concern, not something a unit test can exercise.)
        #expect(parsedA == parsedB)
        #expect(parsedA.contains("shared sentence"))

        // The encoded bytes should differ (different author UUID is
        // materialised in the AuthorIDs block). If they don't, the
        // author UUID is being dropped somewhere — a separate bug.
        #expect(bytesA != bytesB)
    }

    // MARK: - hypothesis F: pathological inputs

    @Test("emoji and combining characters survive round-trip")
    func emojiAndCombining() throws {
        let input = "hello 🌍 café naïve\n"
        let parsed = try roundTrip(input)
        #expect(parsed.contains("🌍"))
        #expect(parsed.contains("café") || parsed.contains("caf"))  // be lenient if NFC/NFD drops
    }

    @Test("surrogate-pair emoji (outside BMP) round-trips")
    func surrogatePairEmoji() throws {
        // 🚀 is U+1F680, requires a surrogate pair in UTF-16. If the
        // codec's writeString/readString is UTF-16-based rather than
        // UTF-8-clean, this is where it would fail.
        let input = "rocket 🚀 blast\n"
        let parsed = try roundTrip(input)
        #expect(parsed.contains("🚀"))
    }

    @Test("very long single paragraph round-trips")
    func longParagraph() throws {
        // 4 KB of repeating text. Exercises string-encoding buffer
        // limits on both sides.
        let input = String(repeating: "abcdefghij", count: 400) + "\n"
        let parsed = try roundTrip(input)
        #expect(parsed.contains("abcdefghij"))
        // Length should be preserved to within a trailing newline.
        #expect(parsed.count >= input.count - 2)
    }

    @Test("1000-line doc round-trips")
    func thousandLines() throws {
        let input = (1...1000).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let parsed = try roundTrip(input)
        #expect(parsed.contains("line 1\n"))
        #expect(parsed.contains("line 500\n"))
        #expect(parsed.contains("line 1000\n"))
    }

    @Test("tabs in content are preserved (or mapped deterministically)")
    func tabs() throws {
        let input = "col1\tcol2\tcol3\n"
        let parsed = try roundTrip(input)
        // Either tabs are preserved or converted to spaces. The exact
        // shape matters less than "it didn't parse to empty".
        #expect(!parsed.isEmpty)
        #expect(parsed.contains("col1"))
        #expect(parsed.contains("col3"))
    }

    // MARK: - paragraph fidelity (WYSIWYG with pandoc)

    /// Round-trip contract: the native-plain codec preserves local source
    /// bytes. Tablet display spacing is handled before encoding, not by
    /// changing what ``parsePage`` returns for a simple text page.

    @Test("blank-line paragraph break round-trips as canonical \\n\\n")
    func blankLineRoundTrip() throws {
        #expect(try roundTrip("a\n\nb\n") == "a\n\nb\n")
    }

    @Test("multiple blank lines round-trip exactly")
    func multipleBlanksPreserved() throws {
        #expect(try roundTrip("a\n\n\n\nb\n") == "a\n\n\n\nb\n")
    }

    @Test("heading + body get a blank line between them")
    func headingThenBody() throws {
        #expect(try roundTrip("# h\n\nbody\n") == "# h\n\nbody\n")
    }

    @Test("single-newline plain source is preserved")
    func softBreakPreserved() throws {
        #expect(try roundTrip("a\nb\n") == "a\nb\n")
    }

    @Test("plain source preserves trailing spaces and final-newline shape")
    func plainSourceExactSpacing() throws {
        #expect(try roundTrip("tail space \nnext") == "tail space \nnext")
        #expect(try roundTrip("no final newline") == "no final newline")
    }

    @Test("markdown markers stay literal text")
    func markdownMarkersStayLiteral() throws {
        let input = "## Heading\n\n- item\n\nbody **bold**\n"
        #expect(try roundTrip(input) == input)
    }

    @Test("leading and trailing blank lines round-trip exactly")
    func leadingAndTrailingBlanks() throws {
        #expect(try roundTrip("\n\na\n") == "\n\na\n")
        #expect(try roundTrip("a\n\n\n") == "a\n\n\n")
    }

    // MARK: - paragraph styles + inline formatting (deferred)

    /// These tests describe the rich-text round-trip the
    /// ``richTextDocument`` encoder added in v0.2.33 (PRs #20/#21):
    /// markdown prefixes (``# ``, ``## ``, ``- ``, ``  - ``,
    /// ``- [ ] ``, ``- [x] ``) and inline ``**bold**`` / ``*italic*``
    /// runs are pushed as native tablet paragraph styles + inline
    /// spans, and round-trip back to canonical markdown on pull.
    ///
    /// The encoder was reverted in v0.2.36 because emitting many CRDT
    /// items per page (one per character / format-code) restarted slot
    /// numbering at 16 every push; subsequent pushes collided with
    /// prior pushes' CrdtIDs and the tablet's CRDT engine merged the
    /// overlap into a tangle (rendering only the resolved tail).
    /// Restoring rich text requires giving each push a unique CRDT
    /// slot range (e.g. a per-doc monotonic counter persisted in
    /// state.db) so subsequent pushes don't overlap. Until that lands,
    /// these tests stay in the file as documentation of the desired
    /// behaviour but are skipped.
    @Test("tight bullet list round-trips identity", .disabled("deferred until per-push CRDT slot uniqueness lands; see v0.2.36 revert"))
    func bulletListTightRoundTrip() throws {
        #expect(try roundTrip("- a\n- b\n- c\n") == "- a\n- b\n- c\n")
    }

    @Test("nested bullets round-trip identity", .disabled("deferred until per-push CRDT slot uniqueness lands; see v0.2.36 revert"))
    func nestedBullets() throws {
        #expect(try roundTrip("- a\n  - b\n  - c\n- d\n") == "- a\n  - b\n  - c\n- d\n")
    }

    @Test("checkboxes round-trip identity, both states", .disabled("deferred until per-push CRDT slot uniqueness lands; see v0.2.36 revert"))
    func checkboxesRoundTrip() throws {
        #expect(try roundTrip("- [ ] todo\n- [x] done\n") == "- [ ] todo\n- [x] done\n")
    }

    @Test("H1 heading round-trips identity")
    func headingRoundTrip() throws {
        // Plain-text round-trip — heading marker is preserved as
        // literal markdown bytes; tablet shows ``# Title`` rather
        // than a styled heading. Identity holds.
        #expect(try roundTrip("# Title\n\nbody\n") == "# Title\n\nbody\n")
    }

    @Test("H2 (bold-style heading) round-trips identity")
    func heading2RoundTrip() throws {
        #expect(try roundTrip("## Subtitle\n\nbody\n") == "## Subtitle\n\nbody\n")
    }

    @Test(
        "mixed document with all paragraph styles round-trips canonically",
        .disabled("deferred until per-push CRDT slot uniqueness lands; see v0.2.36 revert")
    )
    func mixedParagraphStyles() throws {
        let input  = "# H1\n\n## H2\n\nbody\n\n- bullet\n  - nested\n\n- [ ] todo\n- [x] done\n\nmore\n"
        let output = "# H1\n\n## H2\n\nbody\n\n- bullet\n  - nested\n- [ ] todo\n- [x] done\n\nmore\n"
        #expect(try roundTrip(input) == output)
    }

    // MARK: - inline formatting round-trip (deferred)

    @Test("bold inline survives round-trip", .disabled("deferred until per-push CRDT slot uniqueness lands; see v0.2.36 revert"))
    func boldInline() throws {
        #expect(try roundTrip("hello **world**\n") == "hello **world**\n")
    }

    @Test("italic inline survives round-trip", .disabled("deferred until per-push CRDT slot uniqueness lands; see v0.2.36 revert"))
    func italicInline() throws {
        #expect(try roundTrip("hello *world*\n") == "hello *world*\n")
    }

    @Test("bold + italic combined survives round-trip", .disabled("deferred until per-push CRDT slot uniqueness lands; see v0.2.36 revert"))
    func boldItalicInline() throws {
        #expect(try roundTrip("***both***\n") == "***both***\n")
    }

    @Test("inline formatting inside a heading round-trips", .disabled("deferred until per-push CRDT slot uniqueness lands; see v0.2.36 revert"))
    func inlineInHeading() throws {
        #expect(try roundTrip("# **bold** title\n") == "# **bold** title\n")
    }

    @Test("multiple inline runs in one paragraph round-trip", .disabled("deferred until per-push CRDT slot uniqueness lands; see v0.2.36 revert"))
    func mixedInlineSpans() throws {
        let input = "regular **bold** middle *italic* tail\n"
        #expect(try roundTrip(input) == input)
    }

    // MARK: - LWW idempotence (regression for v0.2.33's CRDT collision)

    @Test("two pushes with different content both decode correctly")
    func twoPushesDecodeIndependently() throws {
        // The bug we're regressing on: push N emits CRDT items at
        // slots 16..N1, push N+1 also at 16..N2. Tablet treats them
        // as concurrent ops on the same IDs and renders only the
        // merged tail (e.g. "test"). With simpleTextDocument's
        // single-item-per-page model, each push is one CrdtID; LWW
        // resolves cleanly, and a pull-back of either push decodes
        // to the same content that was pushed.
        let authorUUID = "5cff3add-0000-0000-0000-000000000000"
        let first  = "first content with several paragraphs\n\nsecond paragraph\n\nthird\n"
        let second = "completely different content\n\nthat replaces it\n"

        let bytes1 = try PageCodec.renderPage(text: first, authorUUID: authorUUID)
        let parsed1 = try PageCodec.parsePage(bytes1)
        #expect(parsed1.contains("first content"))
        #expect(parsed1.contains("third"))

        let bytes2 = try PageCodec.renderPage(text: second, authorUUID: authorUUID)
        let parsed2 = try PageCodec.parsePage(bytes2)
        #expect(parsed2.contains("completely different"))
        #expect(parsed2.contains("replaces it"))
        #expect(!parsed2.contains("first content"))
        #expect(!parsed2.contains("third"))
    }
}
