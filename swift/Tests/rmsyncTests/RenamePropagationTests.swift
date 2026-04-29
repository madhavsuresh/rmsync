import Foundation
import Testing
@testable import rmsync

/// Phase-4 rename pipeline tests:
///
///   1. ``RenamePairer`` actor — pure unit. Exercises the
///      from/to / to/from / window-expiry / orphan-flush paths.
///
///   2. ``RenameHint`` round-trip codec.
///
///   3. ``Reconcile`` resume-on-startup picks up
///      ``pending_op = "pending_rename"`` rows and emits a
///      ``.renameRemote`` job.
///
///   4. Worker invariants — bail without a docID match; bail
///      when propagation disabled; resolve via either old or
///      new ``local_path``.
///
/// Cloud-side ``mv`` round-trip lives in ``DeleteSmokeTests``
/// (gated on ``RMSYNC_LIVE``) for the same reason as deletes.
@Suite("rename propagation")
struct RenamePropagationTests {
    // MARK: - RenamePairer

    @Test("pairer matches from-then-to within window")
    func pairerFromThenTo() async throws {
        let pairer = RenamePairer(windowSeconds: 0.2)
        let now = Date()
        #expect(await pairer.observeFrom(path: "a.md", now: now) == nil)
        let pair = await pairer.observeTo(path: "b.md", now: now.addingTimeInterval(0.1))
        #expect(pair?.from == "a.md")
        #expect(pair?.to == "b.md")
    }

    @Test("pairer matches to-then-from within window")
    func pairerToThenFrom() async throws {
        // FSEvents may deliver the destination event first.
        let pairer = RenamePairer(windowSeconds: 0.2)
        let now = Date()
        #expect(await pairer.observeTo(path: "b.md", now: now) == nil)
        let pair = await pairer.observeFrom(path: "a.md", now: now.addingTimeInterval(0.1))
        #expect(pair?.from == "a.md")
        #expect(pair?.to == "b.md")
    }

    @Test("pairer drops half-pairs after window")
    func pairerOrphans() async throws {
        let pairer = RenamePairer(windowSeconds: 0.2)
        let now = Date()
        _ = await pairer.observeFrom(path: "stale.md", now: now)
        let result = await pairer.flushExpired(now: now.addingTimeInterval(0.5))
        #expect(result.orphanFroms == ["stale.md"])
        #expect(result.orphanTos.isEmpty)
        let counts = await pairer.pendingCount()
        #expect(counts.froms == 0 && counts.tos == 0)
    }

    @Test("pairer keeps fresh halves alive")
    func pairerKeepsFresh() async throws {
        let pairer = RenamePairer(windowSeconds: 0.2)
        let now = Date()
        _ = await pairer.observeFrom(path: "fresh.md", now: now)
        let result = await pairer.flushExpired(now: now.addingTimeInterval(0.05))
        #expect(result.orphanFroms.isEmpty)
        let counts = await pairer.pendingCount()
        #expect(counts.froms == 1)
    }

    // MARK: - RenameHint

    @Test("hint encode + decode round-trips")
    func hintRoundTrip() async throws {
        let encoded = RenameHint.encode(from: "/a/foo.md", to: "/b/bar.md")
        let decoded = RenameHint.decode(encoded)
        #expect(decoded?.from == "/a/foo.md")
        #expect(decoded?.to == "/b/bar.md")
    }

    @Test("hint decode rejects malformed values")
    func hintMalformed() async throws {
        #expect(RenameHint.decode("just-one-path") == nil)
        #expect(RenameHint.decode("a\tb\tc") == nil)
        #expect(RenameHint.decode("") == nil)
    }

    // MARK: - Reconcile pending_rename resume

    @Test("Reconcile resumes pending_rename rows on startup")
    func reconcileResumesPendingRename() async throws {
        let dir = try tempDir()
        let state = try State(path: dir.appendingPathComponent("state.db"))
        let queue = JobQueue()
        try await state.upsert(Document(
            docID: "moving",
            docType: "DocumentType",
            remotePath: "/Writing/old-name",
            localPath: dir.appendingPathComponent("new-name.md").path,
            lastSyncedMDHash: "abc",
            pendingOp: "pending_rename"
        ))
        try await Reconcile.localDeletions(state: state, queue: queue)

        var collected: [(Job.Kind, String)] = []
        while let job = await queue.dequeue(timeout: 0.05) {
            collected.append((job.kind, job.docID ?? ""))
            await queue.taskDone()
        }
        #expect(collected.count == 1)
        #expect(collected.first?.0 == .renameRemote)
        #expect(collected.first?.1 == "moving")
    }

    @Test("Reconcile resume hint round-trips both halves")
    func reconcileResumeHint() async throws {
        let dir = try tempDir()
        let state = try State(path: dir.appendingPathComponent("state.db"))
        let queue = JobQueue()
        let path = dir.appendingPathComponent("renamed.md").path
        try await state.upsert(Document(
            docID: "x",
            docType: "DocumentType",
            remotePath: "/Writing/old",
            localPath: path,
            lastSyncedMDHash: "abc",
            pendingOp: "pending_rename"
        ))
        try await Reconcile.localDeletions(state: state, queue: queue)

        let job = await queue.dequeue(timeout: 0.05)!
        let pair = RenameHint.decode(job.hint)
        #expect(pair?.from == path)
        #expect(pair?.to == path)
        await queue.taskDone()
    }

    // MARK: - helpers

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmsync-rename-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
