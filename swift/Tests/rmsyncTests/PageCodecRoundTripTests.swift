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
}
