import Foundation
import Testing
@testable import rmsync

/// Live push/pull smoke test. Opts in via ``RMSYNC_LIVE=1``. Uses the
/// isolated ``/rmsync-test`` folder on the real cloud — same pattern as
/// the Python project's ``scripts/cloud_probe*.py``. Cleans up after
/// itself.
@Suite("Push smoke (live cloud)")
struct PushSmokeTests {
    private func live() -> Bool {
        ProcessInfo.processInfo.environment["RMSYNC_LIVE"] == "1"
    }

    @Test("push → pull round-trip in rmsync-test folder")
    func pushPullRoundTrip() async throws {
        guard live() else { return }

        // Fresh tempdir per run so parallel tests don't collide.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmsync-push-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let syncDir = tmp.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncDir, withIntermediateDirectories: true)

        let stateDBPath = tmp.appendingPathComponent("state.db")
        let state = try State(path: stateDBPath)

        let cfg = Config(
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
            log: .init(level: .info)
        )

        // Ensure the folder exists on the cloud.
        let cloud = Cloud()
        try? await cloud.mkdir("/rmsync-test")

        // Upload-side: drop a .md under sync dir, enqueue a PUSH job,
        // let the worker run it.
        let probeName = "swift-probe-\(UUID().uuidString.prefix(8))"
        let mdPath = syncDir.appendingPathComponent("\(probeName).md")
        let body = "hello from Swift Week 5\nline 2\nthird line\n"
        try body.write(to: mdPath, atomically: true, encoding: .utf8)

        let queue = JobQueue()
        let fence = EchoFence()
        let locks = LockRegistry()
        let worker = SyncWorker(
            id: 0, queue: queue, cloud: cloud, state: state,
            cfg: cfg, locks: locks, fence: fence
        )
        let workerTask = Task { await worker.run() }
        defer {
            Task { await worker.stop() }
            workerTask.cancel()
        }

        await queue.enqueue(Job(kind: .push, docID: nil, hint: mdPath.path))
        await queue.waitUntilEmpty()

        // Download the doc back from the cloud and verify content.
        let pullDir = tmp.appendingPathComponent("pull", isDirectory: true)
        try FileManager.default.createDirectory(at: pullDir, withIntermediateDirectories: true)
        let archivePath = try await cloud.get("/rmsync-test/\(probeName)", dest: pullDir)

        let unpacked = try await Archive.unpack(archivePath)
        #expect(unpacked.pages.count == 1)
        #expect(unpacked.visibleName == probeName)

        let parsed = try PageCodec.parsePage(unpacked.pages[0].rmBytes)
        // Plain-strategy push → parse round-trip yields the same text.
        #expect(parsed.contains("hello from Swift Week 5"))
        #expect(parsed.contains("line 2"))
        #expect(parsed.contains("third line"))

        // Cloud side has exactly ONE page — no cover, no ghost pages.
        // (Archive.unpack already de-dupes, so cross-check the raw JSON.)
        let inspectDir = tmp.appendingPathComponent("inspect")
        try FileManager.default.createDirectory(at: inspectDir, withIntermediateDirectories: true)
        let unzip = try await Subprocess.run(
            executablePath: "/usr/bin/unzip",
            args: ["-qq", "-o", archivePath.path, "-d", inspectDir.path]
        )
        #expect(unzip.exitCode == 0)
        let contents = try FileManager.default.contentsOfDirectory(atPath: inspectDir.path)
        let contentFile = contents.first(where: { $0.hasSuffix(".content") })!
        let contentJSON = try JSONSerialization.jsonObject(
            with: Data(contentsOf: inspectDir.appendingPathComponent(contentFile))
        ) as! [String: Any]

        #expect(contentJSON["pageCount"] as? Int == 1)
        #expect(contentJSON["coverPageNumber"] as? Int == -1)

        // Cleanup: remove the cloud doc.
        try? await cloud.rm("/rmsync-test/\(probeName)")
    }

    @Test("put --force update keeps cPages at count 1")
    func updateDoesNotGrowCPages() async throws {
        guard live() else { return }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmsync-push-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let syncDir = tmp.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncDir, withIntermediateDirectories: true)

        let state = try State(path: tmp.appendingPathComponent("state.db"))
        let cfg = Config(
            syncDir: syncDir, remoteFolder: "rmsync-test",
            workerPoolSize: 1, pollIntervalSeconds: 60,
            pollActiveIntervalSeconds: 60, pollIdleIntervalSeconds: 120,
            debounceSeconds: 2, renameDetectWindowS: 5,
            echoFenceSeconds: 5, retryMaxAttempts: 3,
            pushStrategy: .nativePlain, backupSnapshotsToKeep: 5,
            dryRun: false, log: .init(level: .info)
        )

        let cloud = Cloud()
        try? await cloud.mkdir("/rmsync-test")

        let probeName = "swift-update-\(UUID().uuidString.prefix(8))"
        let mdPath = syncDir.appendingPathComponent("\(probeName).md")

        let queue = JobQueue()
        let worker = SyncWorker(
            id: 0, queue: queue, cloud: cloud, state: state,
            cfg: cfg, locks: LockRegistry(), fence: EchoFence()
        )
        let workerTask = Task { await worker.run() }
        defer {
            Task { await worker.stop() }
            workerTask.cancel()
        }

        // v1
        try "version one\n".write(to: mdPath, atomically: true, encoding: .utf8)
        await queue.enqueue(Job(kind: .push, docID: nil, hint: mdPath.path))
        await queue.waitUntilEmpty()

        // v2 (update)
        try "version two updated\n".write(to: mdPath, atomically: true, encoding: .utf8)
        let stored = try await state.byLocalPath(mdPath.path)
        let docID = try #require(stored?.docID)
        await queue.enqueue(Job(kind: .push, docID: docID, hint: mdPath.path))
        await queue.waitUntilEmpty()

        // v3 (update again)
        try "version three final\n".write(to: mdPath, atomically: true, encoding: .utf8)
        await queue.enqueue(Job(kind: .push, docID: docID, hint: mdPath.path))
        await queue.waitUntilEmpty()

        // Pull back. cPages must still have exactly one entry.
        let pullDir = tmp.appendingPathComponent("pull")
        try FileManager.default.createDirectory(at: pullDir, withIntermediateDirectories: true)
        let archive = try await cloud.get("/rmsync-test/\(probeName)", dest: pullDir)

        let inspectDir = tmp.appendingPathComponent("inspect")
        try FileManager.default.createDirectory(at: inspectDir, withIntermediateDirectories: true)
        _ = try await Subprocess.run(
            executablePath: "/usr/bin/unzip",
            args: ["-qq", "-o", archive.path, "-d", inspectDir.path]
        )
        let contents = try FileManager.default.contentsOfDirectory(atPath: inspectDir.path)
        let contentFile = contents.first(where: { $0.hasSuffix(".content") })!
        let contentJSON = try JSONSerialization.jsonObject(
            with: Data(contentsOf: inspectDir.appendingPathComponent(contentFile))
        ) as! [String: Any]

        // Either legacy or sync15 shape is fine here; what we care about
        // is that the page count stays at 1 — the cPages CRDT didn't
        // accumulate ghost entries.
        #expect(contentJSON["pageCount"] as? Int == 1)

        let unpacked = try await Archive.unpack(archive)
        #expect(unpacked.pages.count == 1)
        let parsed = try PageCodec.parsePage(unpacked.pages[0].rmBytes)
        #expect(parsed.contains("version three final"))

        try? await cloud.rm("/rmsync-test/\(probeName)")
    }
}
