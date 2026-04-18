import Foundation
import Testing
@testable import rmsync

@Suite("PageCodec (in-process RMScene)")
struct PageCodecTests {
    @Test("render then parse round-trips plain text")
    func roundTripPlain() throws {
        let author = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let input = "hello from Swift\nline two\nline three\n"
        let rmBytes = try PageCodec.renderPage(
            text: input, authorUUID: author.uuidString
        )
        #expect(rmBytes.count > 100)  // sanity: real binary output

        let parsed = try PageCodec.parsePage(rmBytes)
        #expect(parsed.contains("hello from Swift"))
        #expect(parsed.contains("line two"))
        #expect(parsed.contains("line three"))
    }

    @Test("empty input is encoded and decoded without crashing")
    func emptyInputRoundTrip() throws {
        let author = UUID().uuidString
        let rmBytes = try PageCodec.renderPage(text: "", authorUUID: author)
        let parsed = try PageCodec.parsePage(rmBytes)
        // Empty or whitespace-only content — don't assert exact shape.
        #expect(parsed.count < 5)
    }

    @Test("invalid author UUID surfaces a typed error")
    func invalidAuthorUUID() {
        #expect(throws: PageCodec.CodecError.self) {
            try PageCodec.renderPage(text: "x", authorUUID: "not-a-uuid")
        }
    }
}
