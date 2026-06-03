import Foundation
import RMApiMockCore
import Testing
@testable import rmsync

#if os(Linux)
import Glibc
#else
import Darwin
#endif

@Suite("rmapi mock integration", .serialized)
struct RMApiMockIntegrationTests {
    @Test("Cloud parses mock version, account, shell listings, stat, put, and get")
    func cloudCommandSurface() async throws {
        guard let harness = try Harness.make("cloud-surface") else { return }
        let cloud = harness.cloud

        let version = try await cloud.version()
        #expect(version.0 == 0)
        #expect(version.1 == 0)
        #expect(version.2 == 32)
        #expect(try await cloud.account() == "mock@example.com")

        try await cloud.mkdir("/Writing")
        try await cloud.mkdir("/Writing/Nested Folder")
        let archive = try await harness.archive(name: "Hello World", text: "hello from mock\n")
        try await cloud.put(local: archive, remoteParent: "/Writing/Nested Folder", update: false)

        let found = try await cloud.find("/Writing")
        #expect(found.contains("[d] Writing/Nested Folder"))
        #expect(found.contains("[f] Writing/Nested Folder/Hello World"))

        let listed = try await cloud.ls("/Writing/Nested Folder")
        #expect(listed.contains { $0.kind == "f" && $0.name == "Hello World" })

        let stat = try #require(try await cloud.stat("/Writing/Nested Folder/Hello World"))
        #expect(stat.name == "Hello World")
        #expect(stat.type == "DocumentType")
        #expect(!stat.id.isEmpty)

        let nodes = try await cloud.tree("/Writing")
        let node = try #require(nodes.first { $0.remotePath == "/Writing/Nested Folder/Hello World" })
        #expect(node.id == stat.id)
        #expect(node.type == .document)

        let pulled = try await cloud.get(
            "/Writing/Nested Folder/Hello World",
            dest: harness.root.appendingPathComponent("pulled", isDirectory: true)
        )
        let unpacked = try await Archive.unpack(pulled)
        #expect(unpacked.visibleName == "Hello World")
        #expect(try PageCodec.parsePage(unpacked.pages[0].rmBytes).contains("hello from mock"))
    }

    @Test("mock faults feed existing Cloud error classifiers")
    func faultInjection() async throws {
        guard let harness = try Harness.make("faults") else { return }
        let cloud = harness.cloud
        try await cloud.mkdir("/Writing")
        let archive = try await harness.archive(name: "Fault Target", text: "before\n")
        try await cloud.put(local: archive, remoteParent: "/Writing", update: false)

        try RMApiMockTestSupport.addCommandFault(
            command: "find",
            kind: .throttle,
            once: true,
            stateDir: harness.stateDir
        )
        do {
            _ = try await cloud.find("/Writing")
            Issue.record("expected throttled find")
        } catch let error as RmapiError {
            #expect(error.isThrottle)
        }
        #expect(try await cloud.find("/Writing").contains("[f] Writing/Fault Target"))

        try RMApiMockTestSupport.addNoArchivePath("/Writing/Fault Target", stateDir: harness.stateDir)
        do {
            _ = try await cloud.get(
                "/Writing/Fault Target",
                dest: harness.root.appendingPathComponent("no-archive", isDirectory: true)
            )
            Issue.record("expected missing archive error")
        } catch let error as RmapiError {
            #expect(error.description.contains("produced no .rmdoc"))
        }

        try RMApiMockTestSupport.clearFaults(stateDir: harness.stateDir)
        try RMApiMockTestSupport.setAuthBroken(true, stateDir: harness.stateDir)
        do {
            _ = try await cloud.account()
            Issue.record("expected auth failure")
        } catch {
            let classified = CloudHealthProbe.classify(error)
            #expect(classified.classification == .authBroken)
        }
    }

    @Test("partial find faults make Cloud.tree observe a shortened remote listing")
    func partialFindListing() async throws {
        guard let harness = try Harness.make("partial-find") else { return }
        let cloud = harness.cloud
        try await cloud.mkdir("/Writing")
        try await cloud.put(
            local: try await harness.archive(name: "A", text: "a\n"),
            remoteParent: "/Writing",
            update: false
        )
        try await cloud.put(
            local: try await harness.archive(name: "B", text: "b\n"),
            remoteParent: "/Writing",
            update: false
        )

        #expect(try await cloud.tree("/Writing").filter { $0.type == .document }.count == 2)
        try RMApiMockTestSupport.setPartialFindLimit(1, stateDir: harness.stateDir)
        #expect(try await cloud.tree("/Writing").filter { $0.type == .document }.isEmpty)
    }

    @Test("ExplicitSync push, remote update, pull, and accept round-trip through mock rmapi")
    func explicitPushPullAccept() async throws {
        guard let harness = try Harness.make("explicit") else { return }
        let cloud = harness.cloud
        let syncDir = harness.root.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncDir, withIntermediateDirectories: true)
        let state = try State(path: harness.root.appendingPathComponent("state.db"))
        let cfg = Config(syncDir: syncDir, remoteFolder: "Writing")
        try await cloud.mkdir("/Writing")

        let local = syncDir.appendingPathComponent("note.md")
        try "local v1\n".write(to: local, atomically: true, encoding: .utf8)
        let pushed = try await ExplicitSync.push(
            cfg: cfg,
            state: state,
            cloud: cloud,
            paths: [local.path],
            includeDeletes: false,
            force: false
        )
        #expect(pushed.pushed == 1)
        #expect(pushed.refused.isEmpty)

        let pulledArchive = try await cloud.get(
            "/Writing/note",
            dest: harness.root.appendingPathComponent("pull-after-push", isDirectory: true)
        )
        let pushedDoc = try await Archive.unpack(pulledArchive)
        let pushedText = try PageCodec.parsePage(pushedDoc.pages[0].rmBytes)
        #expect(pushedText.contains("local v1"))

        try await cloud.put(
            local: try await harness.archive(name: "note", text: "remote v2\n"),
            remoteParent: "/Writing",
            update: true
        )
        let stage = try await ExplicitSync.stagePull(
            cfg: cfg,
            state: state,
            cloud: cloud,
            full: true
        )
        let entry = try #require(stage.entries.first { $0.relativePath == "note.md" })
        #expect(entry.kind == .modified)

        let accepted = try await ExplicitSync.accept(
            cfg: cfg,
            state: state,
            paths: ["note.md"],
            all: false,
            includeDeletes: false,
            force: false
        )
        #expect(accepted.applied == 1)
        #expect(try String(contentsOf: local, encoding: .utf8).contains("remote v2"))
    }

    @Test("ExplicitSync include-deletes removes remote document through mock rmapi")
    func explicitIncludeDeletes() async throws {
        guard let harness = try Harness.make("include-deletes") else { return }
        let cloud = harness.cloud
        let syncDir = harness.root.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncDir, withIntermediateDirectories: true)
        let state = try State(path: harness.root.appendingPathComponent("state.db"))
        let cfg = Config(syncDir: syncDir, remoteFolder: "Writing")
        try await cloud.mkdir("/Writing")

        let local = syncDir.appendingPathComponent("delete-me.md")
        try "delete me\n".write(to: local, atomically: true, encoding: .utf8)
        _ = try await ExplicitSync.push(
            cfg: cfg,
            state: state,
            cloud: cloud,
            paths: [local.path],
            includeDeletes: false,
            force: false
        )
        #expect(try await cloud.stat("/Writing/delete-me") != nil)
        try FileManager.default.removeItem(at: local)

        let deleted = try await ExplicitSync.push(
            cfg: cfg,
            state: state,
            cloud: cloud,
            paths: [local.path],
            includeDeletes: true,
            force: false
        )
        #expect(deleted.pushed == 1)
        #expect(try await cloud.stat("/Writing/delete-me") == nil)
    }

    @Test("force-push creates local-only docs and deletes remote-only docs through mock rmapi")
    func forcePushApply() async throws {
        guard let harness = try Harness.make("force-push") else { return }
        let cloud = harness.cloud
        let syncDir = harness.root.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncDir, withIntermediateDirectories: true)
        let state = try State(path: harness.root.appendingPathComponent("state.db"))
        let cfg = Config(syncDir: syncDir, remoteFolder: "Writing")
        try await cloud.mkdir("/Writing")
        try await cloud.put(
            local: try await harness.archive(name: "remote-only", text: "remote\n"),
            remoteParent: "/Writing",
            update: false
        )
        try "local\n".write(to: syncDir.appendingPathComponent("local-only.md"), atomically: true, encoding: .utf8)

        let plan = try await ExplicitSync.planForcePush(
            cfg: cfg,
            state: state,
            cloud: cloud,
            stagingDir: harness.root.appendingPathComponent("force-stage", isDirectory: true)
        )
        #expect(plan.items.contains { $0.action == .createRemote && $0.relativePath == "local-only.md" })
        #expect(plan.items.contains { $0.action == .deleteRemote && $0.relativePath == "remote-only.md" })

        let applied = try await ExplicitSync.applyForcePush(plan, cfg: cfg, state: state, cloud: cloud)
        #expect(applied.created == 1)
        #expect(applied.deleted == 1)
        #expect(try await cloud.stat("/Writing/local-only") != nil)
        #expect(try await cloud.stat("/Writing/remote-only") == nil)
    }

    @Test("GitSync initialize and push upload a committed tree through mock rmapi")
    func gitSyncInitAndPush() async throws {
        guard let harness = try Harness.make("git-sync") else { return }
        let repo = harness.root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await Self.runGit(["init", "-b", "main"], cwd: repo)
        try await Self.runGit(["config", "user.email", "mock@example.com"], cwd: repo)
        try await Self.runGit(["config", "user.name", "Mock User"], cwd: repo)
        try "git note\n".write(to: repo.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        try await Self.runGit(["add", "note.md"], cwd: repo)
        try await Self.runGit(["commit", "-m", "base"], cwd: repo)

        let initResult = try await GitSync.initialize(
            cwd: repo,
            name: "mock-repo",
            syncRoot: ".",
            remoteRoot: "sync",
            cloud: harness.cloud
        )
        #expect(initResult.remotePath == "/sync/mock-repo")

        let push = try await GitSync.push(
            cwd: repo,
            dryRun: false,
            allowDirty: false,
            cloud: harness.cloud
        )
        #expect(push.created == 1)
        #expect(try await harness.cloud.stat("/sync/mock-repo/note") != nil)
    }

    @Test("legacy SyncWorker push, rename, delete, and inbox paths use mock rmapi")
    func syncWorkerLegacyPaths() async throws {
        guard let harness = try Harness.make("worker") else { return }
        let cloud = harness.cloud
        let syncDir = harness.root.appendingPathComponent("sync", isDirectory: true)
        let inboxDir = harness.root.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: syncDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        let state = try State(path: harness.root.appendingPathComponent("state.db"))
        let cfg = Config(
            syncDir: syncDir,
            remoteFolder: "Writing",
            workerPoolSize: 1,
            pushStrategy: .nativePlain,
            inbox: Config.InboxConfig(localDir: inboxDir),
            deletion: Config.DeletionConfig(enablePropagation: true, bulkDeleteThreshold: 2.0)
        )
        try await cloud.mkdir("/Writing")
        let queue = JobQueue()
        let worker = SyncWorker(
            id: 0,
            queue: queue,
            cloud: cloud,
            state: state,
            cfg: cfg,
            locks: LockRegistry(),
            fence: EchoFence(),
            limiter: DeletionRateLimiter(cfg: cfg, state: state)
        )
        let workerTask = Task { await worker.run() }
        defer {
            Task { await worker.stop() }
            workerTask.cancel()
        }

        let oldPath = syncDir.appendingPathComponent("worker-note.md")
        try "worker v1\n".write(to: oldPath, atomically: true, encoding: .utf8)
        await queue.enqueue(Job(kind: .push, docID: nil, hint: oldPath.path))
        await queue.waitUntilEmpty()
        let doc = try #require(try await state.byLocalPath(oldPath.path))
        #expect(try await cloud.stat("/Writing/worker-note") != nil)

        let newPath = syncDir.appendingPathComponent("worker-renamed.md")
        try FileManager.default.moveItem(at: oldPath, to: newPath)
        await queue.enqueue(Job(
            kind: .renameRemote,
            docID: doc.docID,
            hint: RenameHint.encode(from: oldPath.path, to: newPath.path)
        ))
        await queue.waitUntilEmpty()
        #expect(try await cloud.stat("/Writing/worker-renamed") != nil)

        try FileManager.default.removeItem(at: newPath)
        await queue.enqueue(Job(kind: .deleteLocal, docID: doc.docID, hint: newPath.path))
        await queue.waitUntilEmpty()
        #expect(try await cloud.stat("/Writing/worker-renamed") == nil)

        let raw = inboxDir.appendingPathComponent("paper.pdf")
        try Data("pdf bytes".utf8).write(to: raw)
        await queue.enqueue(Job(kind: .pushInbox, docID: nil, hint: raw.path))
        await queue.waitUntilEmpty()
        #expect(try await cloud.stat("/Inbox/paper") != nil)
        #expect(!FileManager.default.fileExists(atPath: raw.path))
    }

    private static func runGit(_ args: [String], cwd: URL) async throws {
        let result = try await Subprocess.run(executablePath: "git", args: args, cwd: cwd)
        #expect(result.exitCode == 0, "git \(args.joined(separator: " ")) failed: \(result.stderr)")
        if result.exitCode != 0 {
            throw TestError.git(args, result.stderr)
        }
    }

    private enum TestError: Error {
        case git([String], String)
    }

    private struct Harness {
        let root: URL
        let stateDir: URL
        let cloud: Cloud

        static func make(_ name: String) throws -> Harness? {
            guard let bin = ProcessInfo.processInfo.environment["RMAPI_MOCK_BIN"], !bin.isEmpty else {
                return nil
            }
            let root = try tempRoot()
                .appendingPathComponent("rmsync-rmapi-mock-\(name)-\(UUID().uuidString)", isDirectory: true)
            let stateDir = root.appendingPathComponent("mock-state", isDirectory: true)
            let scratch = root.appendingPathComponent("scratch", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            try RMApiMockTestSupport.reset(stateDir: stateDir)
            setenv("RMAPI_MOCK_STATE_DIR", stateDir.path, 1)
            setenv("RM_SYNC_TMP_DIR", scratch.path, 1)
            setenv("RM_SYNC_STAGING_DIR", root.appendingPathComponent("staging-default", isDirectory: true).path, 1)
            setenv("RM_SYNC_CACHE_DIR", root.appendingPathComponent("cache", isDirectory: true).path, 1)
            return Harness(root: root, stateDir: stateDir, cloud: Cloud(rmapiPath: bin))
        }

        func archive(name: String, text: String) async throws -> URL {
            let dir = root.appendingPathComponent("archives", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let author = "11111111-2222-3333-4444-555555555555"
            let pageID = Archive.newPageID()
            let bytes = try PageCodec.renderPage(text: text, authorUUID: author)
            let archive = dir.appendingPathComponent("\(name).rmdoc")
            return try await Archive.pack(
                Archive.RmDoc(
                    docID: UUID().uuidString.lowercased(),
                    visibleName: name,
                    pages: [Archive.RmDocPage(pageID: pageID, rmBytes: bytes)],
                    version: 1
                ),
                to: archive
            )
        }

        private static func tempRoot() throws -> URL {
            let raw = ProcessInfo.processInfo.environment["RMSYNC_TEST_TMP"]
                ?? ProcessInfo.processInfo.environment["RM_SYNC_TMP_DIR"]
                ?? FileManager.default.temporaryDirectory.path
            let url = URL(fileURLWithPath: raw, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    }
}
