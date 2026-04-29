import Foundation
import Testing
@testable import rmsync

/// Live cloud round-trip for the rename / delete propagation
/// pipeline. Opts in via ``RMSYNC_LIVE=1``; uses the same isolated
/// ``/rmsync-test`` cloud folder ``PushSmokeTests`` uses; cleans
/// up after itself.
///
/// Two scenarios:
///
///   1. **deleteRoundTrip** — push a probe doc, run a
///      ``.deleteLocal`` job through the worker, verify the cloud
///      doc is gone (cloud-trash, not hard-delete; rmapi find no
///      longer surfaces it) and the state.db row is cleared.
///
///   2. **renameRoundTrip** — push a probe doc, run a
///      ``.renameRemote`` job, verify the doc now lives at the new
///      cloud path with the same docID and the state.db's
///      ``remote_path`` matches.
@Suite("Delete + rename smoke (live cloud)")
struct DeleteSmokeTests {
    private func live() -> Bool {
        ProcessInfo.processInfo.environment["RMSYNC_LIVE"] == "1"
    }

    @Test("local delete → cloud rm")
    func deleteRoundTrip() async throws {
        guard live() else { return }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmsync-delete-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let syncDir = tmp.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncDir, withIntermediateDirectories: true)

        let state = try State(path: tmp.appendingPathComponent("state.db"))
        let cfg = makeCfg(syncDir: syncDir)
        let cloud = Cloud()
        try? await cloud.mkdir("/rmsync-test")

        // Push a probe doc.
        let probeName = "swift-delete-\(UUID().uuidString.prefix(8))"
        let mdPath = syncDir.appendingPathComponent("\(probeName).md")
        try "delete-me-please\n".write(to: mdPath, atomically: true, encoding: .utf8)

        let queue = JobQueue()
        let limiter = DeletionRateLimiter(cfg: cfg, state: state)
        let worker = SyncWorker(
            id: 0, queue: queue, cloud: cloud, state: state,
            cfg: cfg, locks: LockRegistry(), fence: EchoFence(),
            limiter: limiter
        )
        let workerTask = Task { await worker.run() }
        defer {
            Task { await worker.stop() }
            workerTask.cancel()
        }

        await queue.enqueue(Job(kind: .push, docID: nil, hint: mdPath.path))
        await queue.waitUntilEmpty()

        // Verify doc is on the cloud.
        let stored = try await state.byLocalPath(mdPath.path)
        let docID = try #require(stored?.docID)
        let remotePath = stored!.remotePath
        #expect(try await cloud.stat(remotePath) != nil)

        // Now delete locally and enqueue .deleteLocal — same kind
        // the watcher would emit on a real ``rm``.
        try FileManager.default.removeItem(at: mdPath)
        await queue.enqueue(Job(kind: .deleteLocal, docID: docID, hint: mdPath.path))
        await queue.waitUntilEmpty()

        // Cloud doc gone (rmapi.stat returns nil for not-found).
        // rmapi.rm moves to cloud trash, not hard-delete; from
        // rmapi find's perspective the doc is no longer in the
        // tree. ``Cloud.stat`` propagates a non-zero exit which
        // throws — accept either a throw or a nil return.
        var seenAfter = false
        do {
            seenAfter = try await cloud.stat(remotePath) != nil
        } catch {
            // stat against a moved-to-trash doc throws — treat as gone.
            seenAfter = false
        }
        #expect(!seenAfter, "cloud doc should be gone after delete")

        // state.db row gone.
        #expect(try await state.get(docID: docID) == nil)
    }

    @Test("local rename → cloud mv")
    func renameRoundTrip() async throws {
        guard live() else { return }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmsync-rename-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let syncDir = tmp.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncDir, withIntermediateDirectories: true)

        let state = try State(path: tmp.appendingPathComponent("state.db"))
        let cfg = makeCfg(syncDir: syncDir)
        let cloud = Cloud()
        try? await cloud.mkdir("/rmsync-test")

        let probeName = "swift-rename-\(UUID().uuidString.prefix(8))"
        let oldMD = syncDir.appendingPathComponent("\(probeName).md")
        let newName = "renamed-\(probeName)"
        let newMD = syncDir.appendingPathComponent("\(newName).md")
        try "rename-me-please\n".write(to: oldMD, atomically: true, encoding: .utf8)

        let queue = JobQueue()
        let limiter = DeletionRateLimiter(cfg: cfg, state: state)
        let worker = SyncWorker(
            id: 0, queue: queue, cloud: cloud, state: state,
            cfg: cfg, locks: LockRegistry(), fence: EchoFence(),
            limiter: limiter
        )
        let workerTask = Task { await worker.run() }
        defer {
            Task { await worker.stop() }
            workerTask.cancel()
        }

        await queue.enqueue(Job(kind: .push, docID: nil, hint: oldMD.path))
        await queue.waitUntilEmpty()

        let stored = try await state.byLocalPath(oldMD.path)
        let docID = try #require(stored?.docID)
        let oldRemote = stored!.remotePath

        // Mirror what the watcher would do: move the local file
        // and enqueue a .renameRemote.
        try FileManager.default.moveItem(at: oldMD, to: newMD)
        await queue.enqueue(Job(
            kind: .renameRemote,
            docID: nil,
            hint: RenameHint.encode(from: oldMD.path, to: newMD.path)
        ))
        await queue.waitUntilEmpty()

        // state.db updated.
        let after = try await state.get(docID: docID)
        #expect(after?.localPath == newMD.path)
        #expect(after?.remotePath != oldRemote)
        #expect(after?.pendingOp == nil)
        #expect(after!.remotePath.hasSuffix(newName))

        // Cloud doc lives at the new path.
        let newStat = try? await cloud.stat(after!.remotePath)
        #expect(newStat != nil)

        try? await cloud.rm(after!.remotePath)
    }

    private func makeCfg(syncDir: URL) -> Config {
        Config(
            syncDir: syncDir,
            remoteFolder: "rmsync-test",
            workerPoolSize: 1,
            pollIntervalSeconds: 60,
            pollActiveIntervalSeconds: 60,
            pollIdleIntervalSeconds: 120,
            debounceSeconds: 2,
            renameDetectWindowS: 5,
            echoFenceSeconds: 5,
            retryMaxAttempts: 3,
            pushStrategy: .nativePlain,
            backupSnapshotsToKeep: 5,
            dryRun: false,
            log: .init(level: .info),
            // Critical: this is the live-cloud test for the
            // propagation pipeline. Without enable_propagation = true
            // the worker handlers no-op and we'd never observe the
            // cloud round-trip.
            deletion: Config.DeletionConfig(enablePropagation: true)
        )
    }
}
