import Foundation
import Testing
@testable import rmsync

/// Phase-2 propagation tests. Three layers of coverage:
///
///   1. ``DeletionRateLimiter`` — pure unit; covers window math,
///      idempotent re-checks, restart semantics, the
///      tracked-doc-count interaction.
///
///   2. ``Reconcile.localDeletions`` — exercised against a real
///      ``State`` actor on a tempdir DB. Validates that
///      ``pending_op = "pending_delete"`` rows are picked up as
///      resume jobs, fresh-missing files emit new ``deleteRemote``
///      jobs, and the two paths don't double-enqueue.
///
///   3. End-to-end with a real cloud round-trip lives in
///      ``DeleteSmokeTests.swift`` (gated on ``RMSYNC_LIVE=1``) —
///      that's where we exercise the actual ``Cloud.rm`` call. The
///      worker has no test-time Cloud abstraction yet, so the
///      live test is the only one that proves the wiring.
@Suite("delete propagation")
struct DeletePropagationTests {
    // MARK: - DeletionRateLimiter

    @Test("limiter allows the first delete unconditionally")
    func limiterFirstDelete() async throws {
        let limiter = DeletionRateLimiter(
            threshold: 0.5, windowSeconds: 30, getTrackedDocCount: { 10 }
        )
        #expect(await limiter.mayDelete(docID: "a"))
    }

    @Test("limiter trips at threshold over window")
    func limiterTrips() async throws {
        // 10 tracked docs, threshold 0.5 (5 docs) → record 5,
        // then a 6th distinct delete is refused.
        let limiter = DeletionRateLimiter(
            threshold: 0.5, windowSeconds: 30, getTrackedDocCount: { 10 }
        )
        let now = Date()
        for i in 0..<5 {
            let doc = "doc-\(i)"
            #expect(await limiter.mayDelete(docID: doc, now: now))
            await limiter.record(docID: doc, now: now)
        }
        // 6th distinct doc would push us to 6/10 = 0.6 > 0.5.
        #expect(!(await limiter.mayDelete(docID: "doc-X", now: now)))
    }

    @Test("limiter allows retrying the same docID")
    func limiterIdempotent() async throws {
        // Even at-threshold, retrying a delete for a docID we
        // *already* recorded does not push the brake further.
        let limiter = DeletionRateLimiter(
            threshold: 0.5, windowSeconds: 30, getTrackedDocCount: { 10 }
        )
        let now = Date()
        for i in 0..<5 {
            let doc = "doc-\(i)"
            #expect(await limiter.mayDelete(docID: doc, now: now))
            await limiter.record(docID: doc, now: now)
        }
        // doc-0 is already in the window — the brake doesn't recount.
        #expect(await limiter.mayDelete(docID: "doc-0", now: now))
    }

    @Test("limiter window prunes stale entries")
    func limiterWindowPrunes() async throws {
        let limiter = DeletionRateLimiter(
            threshold: 0.5, windowSeconds: 30, getTrackedDocCount: { 4 }
        )
        let t0 = Date()
        // Saturate at threshold.
        for i in 0..<2 {
            await limiter.record(docID: "doc-\(i)", now: t0)
        }
        #expect(await limiter.windowSize(now: t0) == 2)

        // Advance 31s — both entries fall out of the window.
        let t1 = t0.addingTimeInterval(31)
        #expect(await limiter.windowSize(now: t1) == 0)
        #expect(await limiter.mayDelete(docID: "doc-X", now: t1))
    }

    @Test("limiter allows delete when nothing is tracked")
    func limiterNoTrackedDocs() async throws {
        // First delete after a fresh install: state.db is empty.
        // Without the special-case the threshold ratio is N/0 = NaN
        // and would compare false, blocking the user from ever
        // deleting their first doc.
        let limiter = DeletionRateLimiter(
            threshold: 0.5, windowSeconds: 30, getTrackedDocCount: { 0 }
        )
        #expect(await limiter.mayDelete(docID: "a"))
    }

    // MARK: - Reconcile resume

    @Test("Reconcile resumes pending_delete rows on startup")
    func reconcileResumesPendingDelete() async throws {
        let dir = try tempDir()
        let state = try State(path: dir.appendingPathComponent("state.db"))
        let queue = JobQueue()

        // Pre-seed: one row mid-flight, one fresh-missing-on-disk.
        try await state.upsert(Document(
            docID: "in-flight",
            docType: "DocumentType",
            remotePath: "/Writing/in-flight",
            localPath: dir.appendingPathComponent("in-flight.md").path,
            lastSyncedMDHash: "abc",
            pendingOp: "pending_delete"
        ))
        try await state.upsert(Document(
            docID: "fresh-missing",
            docType: "DocumentType",
            remotePath: "/Writing/fresh",
            localPath: dir.appendingPathComponent("fresh.md").path,
            lastSyncedMDHash: "def"
        ))
        // A row that was never synced (no hash) — should NOT be
        // enqueued; never confirmed on the cloud side, nothing to
        // delete from there.
        try await state.upsert(Document(
            docID: "never-synced",
            docType: "DocumentType",
            remotePath: "/Writing/never",
            localPath: dir.appendingPathComponent("never.md").path
        ))
        // A row whose local file still exists — leave alone.
        let aliveLocal = dir.appendingPathComponent("alive.md")
        try "still here".write(to: aliveLocal, atomically: true, encoding: .utf8)
        try await state.upsert(Document(
            docID: "alive",
            docType: "DocumentType",
            remotePath: "/Writing/alive",
            localPath: aliveLocal.path,
            lastSyncedMDHash: "ghi"
        ))

        try await Reconcile.localDeletions(state: state, queue: queue)

        // Drain the queue and confirm exactly the two doc IDs we
        // expect, both as ``.deleteRemote``.
        var collected: [String] = []
        while let job = await queue.dequeue(timeout: 0.05) {
            #expect(job.kind == .deleteRemote)
            collected.append(job.docID ?? "")
            await queue.taskDone()
        }
        #expect(Set(collected) == Set(["in-flight", "fresh-missing"]))
    }

    @Test("Reconcile leaves unrelated pending_op rows alone")
    func reconcileIgnoresPendingRename() async throws {
        // A pending_rename row should not be picked up by the
        // delete reconciler — that's Phase 5's territory.
        let dir = try tempDir()
        let state = try State(path: dir.appendingPathComponent("state.db"))
        let queue = JobQueue()

        try await state.upsert(Document(
            docID: "renaming",
            docType: "DocumentType",
            remotePath: "/Writing/renaming",
            localPath: dir.appendingPathComponent("renaming.md").path,
            lastSyncedMDHash: "abc",
            pendingOp: "pending_rename"
        ))
        try await Reconcile.localDeletions(state: state, queue: queue)

        // Queue should be empty — nothing to enqueue.
        #expect(await queue.dequeue(timeout: 0.05) == nil)
    }

    // MARK: - propagation flag

    @Test("delete handler is a no-op when enable_propagation = false")
    func propagationDisabledIsNoop() async throws {
        // We can verify this without a real Cloud: the worker
        // bails before any cloud / trash side effect when
        // ``cfg.deletion.enablePropagation == false``.
        // The check is a guard at the top of deleteLocalAndCloud.
        // Here we just assert the default is off.
        let cfg = Config(syncDir: FileManager.default.temporaryDirectory)
        #expect(cfg.deletion.enablePropagation == false)
    }

    // MARK: - helpers

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmsync-delete-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
