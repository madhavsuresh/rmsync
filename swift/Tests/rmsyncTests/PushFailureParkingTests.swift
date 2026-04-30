import Foundation
import Testing
@testable import rmsync

/// Regression tests for v0.2.23 bug 1: when ``rmapi put`` fails
/// for a brand-new file (no state.db row), the daemon used to
/// fail silently and re-enqueue the same push on every reconcile
/// pass — an infinite retry loop on a permanent error (e.g.
/// rmapi v0.0.29 hitting cloud schema-v4 rejection with HTTP 400).
///
/// The fix parks the failure as a ``Document`` row with
/// ``error_state = "push_failed"``. The reconcile pass then
/// treats it as a tracked-but-unchanged file (skip) UNLESS the
/// user actually edits the file (hash differs → retry).
///
/// Tests below pin the reconcile semantics; the worker→state
/// integration is exercised by the end-to-end live smoke tests.
@Suite("push-failure parking")
struct PushFailureParkingTests {
    @Test("Reconcile skips re-enqueue when error_state set + hash matches")
    func parkedRowSkipsReEnqueue() async throws {
        let dir = try tempDir()
        let state = try State(path: dir.appendingPathComponent("state.db"))
        let queue = JobQueue()

        let content = "stays the same"
        let mdPath = dir.appendingPathComponent("parked.md")
        try content.write(to: mdPath, atomically: true, encoding: .utf8)
        let hash = PathUtilities.sha256(content)

        // Get the path string the enumerator will produce for
        // this file (macOS tempdirs symlink /var → /private/var,
        // so the enumerator's URL.path differs from the URL we
        // constructed). Storing the wrong path makes
        // state.byLocalPath miss and Reconcile treats the file
        // as untracked.
        let canonical = try Self.canonicalPath(in: dir, leaf: "parked.md")

        try await state.upsert(Document(
            docID: "parked-doc",
            docType: "DocumentType",
            title: "parked",
            remotePath: "/Writing/parked",
            localPath: canonical,
            lastSyncedMDHash: hash,
            errorState: "push_failed"
        ))

        let cfg = Config(syncDir: dir)
        try await Reconcile.localCreatesAndEdits(
            state: state, cfg: cfg, queue: queue
        )

        // No push job — the file is "tracked + hash matches",
        // and reconcile only re-enqueues on hash divergence.
        // The error_state row stays parked until the user
        // edits.
        #expect(await queue.dequeue(timeout: 0.05) == nil)
    }

    @Test("Reconcile re-enqueues on user edit, even with error_state")
    func userEditTriggersRetry() async throws {
        let dir = try tempDir()
        let state = try State(path: dir.appendingPathComponent("state.db"))
        let queue = JobQueue()

        let mdPath = dir.appendingPathComponent("edited.md")
        try "v1".write(to: mdPath, atomically: true, encoding: .utf8)
        let oldHash = PathUtilities.sha256("v1")

        let canonical = try Self.canonicalPath(in: dir, leaf: "edited.md")

        try await state.upsert(Document(
            docID: "edited-doc",
            docType: "DocumentType",
            title: "edited",
            remotePath: "/Writing/edited",
            localPath: canonical,
            lastSyncedMDHash: oldHash,
            errorState: "push_failed"
        ))

        // User edits the file — hash now differs from
        // lastSyncedMDHash. Reconcile should re-enqueue.
        try "v2 edited content".write(
            to: mdPath, atomically: true, encoding: .utf8
        )

        let cfg = Config(syncDir: dir)
        try await Reconcile.localCreatesAndEdits(
            state: state, cfg: cfg, queue: queue
        )

        let job = await queue.dequeue(timeout: 0.05)
        #expect(job?.kind == .push)
        #expect(job?.docID == "edited-doc")
        // The retry uses the same docID so the worker can
        // ``--force`` against any half-created cloud state.
        await queue.taskDone()
    }

    // MARK: - rmapi version pin (v0.2.23)

    @Test("rmapi minimum is 0.0.32 to dodge cloud schema-v4 break")
    func rmapiMinimumIsBumped() {
        // Symbol-level pin; if a future commit downgrades the
        // minimum below 0.0.32 without paired comments
        // explaining why, this catches it.
        let (maj, min, patch) = Cloud.rmapiMin
        #expect(maj == 0)
        #expect(min == 0)
        #expect(patch >= 32)
    }

    // MARK: - helpers

    /// Find the path string the ``FileManager.enumerator``
    /// will produce for ``leaf`` inside ``dir``. macOS tempdirs
    /// live under a ``/var`` → ``/private/var`` symlink, and the
    /// enumerator yields the resolved form; storing the
    /// unresolved form in state.db means
    /// ``state.byLocalPath`` misses the lookup. Walking the
    /// dir once with the same enumerator the production code
    /// uses guarantees we record the same string.
    private static func canonicalPath(in dir: URL, leaf: String) throws -> String {
        let fm = FileManager.default
        let enumerator = fm.enumerator(
            at: dir, includingPropertiesForKeys: nil, options: []
        )
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == leaf { return url.path }
        }
        throw NSError(
            domain: "PushFailureParkingTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "didn't find \(leaf) in \(dir.path)"]
        )
    }

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmsync-pushfail-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        return url
    }
}
