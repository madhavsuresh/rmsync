import Foundation
import Testing
@testable import rmsync

/// Tests for the v0.2.31 first-start-after-upgrade guard:
/// ``Reconcile.localDeletions(skipDeletePropagation:)``.
///
/// Why this matters: pre-v0.2.27 users had
/// ``[deletion].enable_propagation = false`` as the default, so
/// any local rm sat in state.db as a tracked-but-locally-missing
/// row indefinitely without cloud action. v0.2.27 flipped the
/// default to true. Without a guard, the FIRST daemon start
/// after the upgrade would call ``localDeletions``, see those
/// historical orphan rows, and cascade delete-to-cloud — silent
/// data loss for files the user had no intent to remove from the
/// tablet.
///
/// The guard parks them with ``error_state =
/// "missing_pre_upgrade"`` so the user sees them in
/// ``rmsync errors`` and chooses what to do.
@Suite("upgrade-refresh guard")
struct UpgradeRefreshTests {
    @Test("skipDeletePropagation parks orphans without enqueuing")
    func skipParksOrphans() async throws {
        let dir = try tempDir()
        let state = try State(path: dir.appendingPathComponent("state.db"))
        let queue = JobQueue()

        // Pre-seed: tracked doc whose local file doesn't exist.
        // Mimics the "user rm'd this on v0.2.18, propagation was
        // off, the row sat orphaned through the upgrade".
        try await state.upsert(Document(
            docID: "ghost",
            docType: "DocumentType",
            remotePath: "/Writing/ghost",
            localPath: dir.appendingPathComponent("ghost.md").path,
            lastSyncedMDHash: "abc"
        ))

        try await Reconcile.localDeletions(
            state: state, queue: queue, skipDeletePropagation: true
        )

        // No deleteRemote enqueued.
        #expect(await queue.dequeue(timeout: 0.05) == nil)

        // Row picked up the guard's marker.
        let row = try await state.get(docID: "ghost")
        #expect(row?.errorState == "missing_pre_upgrade")
    }

    @Test("normal mode (skip=false) DOES enqueue deletes for missing files")
    func normalModeEnqueues() async throws {
        let dir = try tempDir()
        let state = try State(path: dir.appendingPathComponent("state.db"))
        let queue = JobQueue()
        try await state.upsert(Document(
            docID: "ghost",
            docType: "DocumentType",
            remotePath: "/Writing/ghost",
            localPath: dir.appendingPathComponent("ghost.md").path,
            lastSyncedMDHash: "abc"
        ))

        try await Reconcile.localDeletions(
            state: state, queue: queue, skipDeletePropagation: false
        )

        let job = await queue.dequeue(timeout: 0.05)
        #expect(job?.kind == .deleteRemote)
        #expect(job?.docID == "ghost")
        await queue.taskDone()

        // Row not parked — normal flow leaves error_state alone
        // (the worker handles state-clearing on success).
        let row = try await state.get(docID: "ghost")
        #expect(row?.errorState == nil)
    }

    @Test("pending_op resumes ALWAYS fire, even with skip enabled")
    func pendingResumesUnaffected() async throws {
        // The skip flag is for "old deletes from before
        // propagation was on", not for "in-flight ops the
        // daemon was already committed to". Pending-op resumes
        // (pending_delete, pending_rename) should still fire on
        // first start after upgrade — they're not retroactive
        // policy decisions, they're crash-recovery.
        let dir = try tempDir()
        let state = try State(path: dir.appendingPathComponent("state.db"))
        let queue = JobQueue()

        try await state.upsert(Document(
            docID: "in-flight",
            docType: "DocumentType",
            remotePath: "/Writing/in-flight",
            localPath: dir.appendingPathComponent("in-flight.md").path,
            lastSyncedMDHash: "abc",
            pendingOp: "pending_delete"
        ))

        try await Reconcile.localDeletions(
            state: state, queue: queue, skipDeletePropagation: true
        )

        // Pending_delete row STILL gets re-enqueued.
        let job = await queue.dequeue(timeout: 0.05)
        #expect(job?.kind == .deleteRemote)
        #expect(job?.docID == "in-flight")
        await queue.taskDone()
    }

    // MARK: - State.lastSeenDaemonVersion round-trip

    @Test("lastSeenDaemonVersion: nil for fresh DB; round-trips after set")
    func lastSeenVersionRoundTrip() async throws {
        let dir = try tempDir()
        let state = try State(path: dir.appendingPathComponent("state.db"))

        // Fresh DB: never set.
        let initial = try await state.getLastSeenDaemonVersion()
        #expect(initial == nil)

        // After daemon writes it.
        try await state.setLastSeenDaemonVersion("0.2.30")
        let stored = try await state.getLastSeenDaemonVersion()
        #expect(stored == "0.2.30")

        // Subsequent overwrite (typical case: daemon upgrades, sets new value).
        try await state.setLastSeenDaemonVersion("0.2.31")
        #expect(try await state.getLastSeenDaemonVersion() == "0.2.31")
    }

    // MARK: - helpers

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmsync-upgrade-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
