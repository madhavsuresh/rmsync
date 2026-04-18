import Testing
@testable import rmsync

@Suite("Cloud shell path escaping")
struct CloudPathEscapingTests {
    @Test("interactive-shell paths are always quoted")
    func safePathQuoted() throws {
        #expect(try Cloud.escapeShellPath("/Writing/hello world") == "\"/Writing/hello world\"")
    }

    @Test("interactive-shell paths reject unsafe metacharacters")
    func rejectsUnsafePath() {
        #expect(throws: RmapiError.self) {
            try Cloud.escapeShellPath("/Writing/evil\"name")
        }
        #expect(throws: RmapiError.self) {
            try Cloud.escapeShellPath("/Writing/evil`name")
        }
        #expect(throws: RmapiError.self) {
            try Cloud.escapeShellPath("/Writing/evil$name")
        }
    }
}
