import Foundation
import Testing
@testable import rmsync

/// Smoke tests against the live reMarkable cloud. Opt in by setting
/// ``RMSYNC_LIVE=1`` in the environment — a fresh CI runner won't have
/// ``rmapi`` authenticated, so keep these out of the default suite.
///
/// Invocation: ``RMSYNC_LIVE=1 PATH="$HOME/bin:$PATH" swift test``
///
/// The opt-in gating is done inside each test body because Swift Testing
/// 6.0's trait expressions (``.enabled(if:)`` etc.) require literal
/// booleans at macro-expansion time.
@Suite("Cloud live smoke")
struct CloudSmokeTests {
    /// Signal a skip via ``withKnownIssue`` so these don't count as
    /// failures when the live env isn't present. Swift Testing's
    /// ``.enabled(if:)`` trait requires a literal, so we early-return
    /// from each test body instead.
    private func live() -> Bool {
        ProcessInfo.processInfo.environment["RMSYNC_LIVE"] == "1"
    }

    @Test("version parses")
    func version() async throws {
        guard live() else { return }
        let cloud = Cloud()
        let (maj, min, patch) = try await cloud.version()
        #expect(maj >= 0 && min >= 0 && patch >= 0)
    }

    @Test("stat /sync/notes returns JSON")
    func statSyncNotes() async throws {
        guard live() else { return }
        let cloud = Cloud()
        let meta = try await cloud.stat("/sync/notes")
        #expect(meta != nil)
        #expect(meta?.type == "CollectionType")
    }

    @Test("tree /sync/notes walks without error")
    func treeSyncNotes() async throws {
        guard live() else { return }
        let cloud = Cloud()
        let nodes = try await cloud.tree("/sync/notes")
        for n in nodes {
            #expect(n.remotePath.hasPrefix("/sync/notes/"))
            #expect(!n.id.isEmpty)
        }
    }
}
