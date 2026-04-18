import Foundation
import Testing
@testable import rmsync

@Suite("Echo fence")
struct EchoFenceTests {
    @Test("marked path is recent")
    func markedPathIsRecent() async {
        let f = EchoFence(windowSeconds: 2.0)
        await f.mark("/tmp/foo.md")
        #expect(await f.isRecent("/tmp/foo.md"))
    }

    @Test("unmarked path is not recent")
    func unmarkedPathNotRecent() async {
        let f = EchoFence(windowSeconds: 2.0)
        #expect(!(await f.isRecent("/tmp/foo.md")))
    }

    @Test("marks expire after window")
    func expiresAfterWindow() async throws {
        let f = EchoFence(windowSeconds: 0.1)
        await f.mark("/tmp/x.md")
        try await Task.sleep(for: .milliseconds(200))
        #expect(!(await f.isRecent("/tmp/x.md")))
    }
}
