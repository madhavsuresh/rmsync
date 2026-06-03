import Foundation
import Testing
@testable import rmsync

@Suite("Safe auto-push")
struct AutoPushTests {
    @Test("explicit auto-push refuses remote baseline drift")
    func refusesRemoteDrift() async throws {
        let fixture = try await makeTrackedFixture(localText: "local edit\n", syncedText: "base\n")
        let cloud = FakeCloud(stats: [
            "/Writing/note": stat(id: "doc-note", modified: "newer"),
        ])

        let result = try await ExplicitSync.autoPush(
            cfg: fixture.cfg,
            state: fixture.state,
            cloud: cloud,
            path: fixture.file.path
        )

        #expect(result.pushed == 0)
        #expect(result.refused.contains { $0.contains("cloud changed") })
        #expect(await cloud.putCount == 0)
    }

    @Test("explicit auto-push refuses stat failures")
    func refusesStatFailure() async throws {
        let fixture = try await makeTrackedFixture(localText: "local edit\n", syncedText: "base\n")
        let cloud = FakeCloud(stats: [:], statFailures: ["/Writing/note"])

        let result = try await ExplicitSync.autoPush(
            cfg: fixture.cfg,
            state: fixture.state,
            cloud: cloud,
            path: fixture.file.path
        )

        #expect(result.pushed == 0)
        #expect(!result.refused.isEmpty)
        #expect(await cloud.putCount == 0)
    }

    @Test("explicit auto-push refuses new doc path collisions")
    func refusesNewDocCollision() async throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("new.md")
        try write("new file\n", to: file)
        let state = try State(path: dir.appendingPathComponent("state.db"))
        let cfg = Config(syncDir: dir)
        let cloud = FakeCloud(stats: [
            "/Writing/new": stat(id: "existing", modified: "already-there"),
        ])

        let result = try await ExplicitSync.autoPush(
            cfg: cfg,
            state: state,
            cloud: cloud,
            path: file.path
        )

        #expect(result.pushed == 0)
        #expect(result.refused.contains { $0.contains("already has a document") })
        #expect(await cloud.putCount == 0)
    }

    @Test("engine waits for stable samples before pushing")
    func coalescesRapidEdits() async throws {
        let fixture = try await makeTrackedFixture(localText: "first edit\n", syncedText: "base\n")
        let cloud = FakeCloud(stats: [
            "/Writing/note": stat(id: "doc-note", modified: "baseline"),
        ])
        let cfg = Config(
            syncDir: fixture.dir,
            autoPush: Config.AutoPushConfig(
                enabled: true,
                debounceSeconds: 0.25,
                stableSampleCount: 2,
                scanIntervalSeconds: 1,
                maxPushesPerMinute: 30
            )
        )
        let engine = AutoPushEngine(cfg: cfg, state: fixture.state, cloud: cloud)

        await engine.enqueue(path: fixture.file.path)
        await engine.processCandidates()
        #expect(await cloud.putCount == 0)

        try write("second edit\n", to: fixture.file)
        await engine.processCandidates()
        #expect(await cloud.putCount == 0)

        await engine.processCandidates()
        #expect(await cloud.putCount == 1)

        try write("third edit\n", to: fixture.file)
        await engine.enqueue(path: fixture.file.path)
        await engine.processCandidates()
        await engine.processCandidates()
        #expect(await cloud.putCount == 2)

        let summary = try await fixture.state.autoPushSummary()
        #expect(summary.succeeded == 2)
    }

    @Test("tracked auto-push refuses missing accepted snapshot baseline")
    func refusesMissingSnapshotBaseline() async throws {
        let fixture = try await makeTrackedFixture(
            localText: "local edit\n",
            syncedText: "base\n",
            seedSnapshot: false
        )
        let cloud = FakeCloud(stats: [
            "/Writing/note": stat(id: "doc-note", modified: "baseline"),
        ])

        let result = try await ExplicitSync.autoPush(
            cfg: fixture.cfg,
            state: fixture.state,
            cloud: cloud,
            path: fixture.file.path
        )

        #expect(result.pushed == 0)
        #expect(result.refused.contains { $0.contains("missing remote baseline") })
        #expect(await cloud.putCount == 0)
    }

    @Test("interrupted operations fail closed when upload cannot be verified")
    func interruptedOperationsFailClosed() async throws {
        let dir = try tempDir()
        let state = try State(path: dir.appendingPathComponent("state.db"))
        let id = try await state.createAutoPushOperation(
            path: dir.appendingPathComponent("note.md").path,
            docID: "doc-note",
            localHash: "hash",
            baselineRemoteModified: "baseline",
            state: "uploading"
        )
        let engine = AutoPushEngine(cfg: Config(syncDir: dir), state: state, cloud: FakeCloud(stats: [:]))

        await engine.reconcileInterruptedOperations()

        let op = try await state.recentAutoPushOperations(limit: 1).first
        #expect(op?.id == id)
        #expect(op?.state == "failed")
        #expect(op?.reason == "interrupted_new_doc_verify_manually")
    }

    @Test("interrupted tracked upload is repaired only after remote readback matches")
    func interruptedUploadReadbackRepairsState() async throws {
        let fixture = try await makeTrackedFixture(localText: "local edit\n", syncedText: "base\n")
        let remoteArchive = try await archive(text: "local edit\n", docID: "doc-note")
        let id = try await fixture.state.createAutoPushOperation(
            path: fixture.file.path,
            docID: "doc-note",
            localHash: PathUtilities.sha256("local edit\n"),
            baselineRemoteModified: "baseline",
            state: "uploading"
        )
        let cloud = FakeCloud(
            stats: ["/Writing/note": stat(id: "doc-note", modified: "after-put")],
            archives: ["/Writing/note": remoteArchive]
        )
        let engine = AutoPushEngine(cfg: fixture.cfg, state: fixture.state, cloud: cloud)

        await engine.reconcileInterruptedOperations()

        let op = try await fixture.state.recentAutoPushOperations(limit: 1).first
        let doc = try await fixture.state.get(docID: "doc-note")
        #expect(op?.id == id)
        #expect(op?.state == "succeeded")
        #expect(op?.remoteModified == "after-put")
        #expect(doc?.lastSyncedMDHash == PathUtilities.sha256("local edit\n"))
        #expect(doc?.remoteModified == "after-put")
    }

    @Test("auto-push pauses inside initialized rmsync-git repositories")
    func refusesGitSyncManagedRepository() async throws {
        let repo = try tempDir().appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await runGit(["init", "-q"], cwd: repo)
        let git = try await Git.open(at: repo)
        let common = try await git.commonDir()
        let config = GitSync.configURL(common: common)
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{}".write(to: config, atomically: true, encoding: .utf8)

        let state = try State(path: repo.appendingPathComponent("state.db"))
        let file = repo.appendingPathComponent("note.md")
        try write("local edit\n", to: file)
        let cfg = Config(
            syncDir: repo,
            autoPush: Config.AutoPushConfig(enabled: true, stableSampleCount: 1)
        )
        let cloud = FakeCloud(stats: [:])
        let engine = AutoPushEngine(cfg: cfg, state: state, cloud: cloud)

        await engine.startup()
        await engine.enqueue(path: file.path)
        await engine.processCandidates()

        let op = try await state.recentAutoPushOperations(limit: 1).first
        #expect(op?.state == "refused")
        #expect(op?.reason == "git_sync_managed")
        #expect(await cloud.putCount == 0)
    }

    @Test("auto-push never propagates missing local files as deletes")
    func missingLocalDoesNotDeleteRemote() async throws {
        let fixture = try await makeTrackedFixture(localText: "base\n", syncedText: "base\n")
        try FileManager.default.removeItem(at: fixture.file)
        let cloud = FakeCloud(stats: [
            "/Writing/note": stat(id: "doc-note", modified: "baseline"),
        ])

        let result = try await ExplicitSync.autoPush(
            cfg: fixture.cfg,
            state: fixture.state,
            cloud: cloud,
            path: fixture.file.path
        )

        #expect(result.pushed == 0)
        #expect(result.skipped == 1)
        #expect(await cloud.rmCount == 0)
    }

    private struct Fixture {
        let dir: URL
        let file: URL
        let cfg: Config
        let state: State
    }

    private func makeTrackedFixture(
        localText: String,
        syncedText: String,
        seedSnapshot: Bool = true
    ) async throws -> Fixture {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("note.md")
        try write(localText, to: file)
        let state = try State(path: dir.appendingPathComponent("state.db"))
        try await state.upsert(Document(
            docID: "doc-note",
            docType: "DocumentType",
            remotePath: "/Writing/note",
            localPath: file.path,
            remoteModified: "baseline",
            lastSyncedMDHash: PathUtilities.sha256(syncedText),
            pageIDs: ["page-1"]
        ))
        if seedSnapshot {
            await ExplicitSync.storeVerifiedRemoteSnapshot(
                docID: "doc-note",
                remotePath: "/Writing/note",
                stat: stat(id: "doc-note", modified: "baseline"),
                source: syncedText,
                sourceHash: PathUtilities.sha256(syncedText),
                tabletHash: PathUtilities.sha256(TabletText.normalizeForTablet(syncedText)),
                pageIDs: ["page-1"],
                archive: nil,
                state: state
            )
        }
        return Fixture(dir: dir, file: file, cfg: Config(syncDir: dir), state: state)
    }

    private func tempDir() throws -> URL {
        let base = ProcessInfo.processInfo.environment["RM_SYNC_TMP_DIR"]
            ?? ProcessInfo.processInfo.environment["RMSYNC_TEST_TMPDIR"]
            ?? ProcessInfo.processInfo.environment["RMSYNC_TEST_TMP"]
            ?? FileManager.default.temporaryDirectory.path
        let url = URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent("rmsync-auto-push-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func archive(text: String, docID: String) async throws -> URL {
        let dir = try tempDir()
        let author = UUID().uuidString.lowercased()
        let tabletText = TabletText.normalizeForTablet(text)
        let pageID = "page-1"
        let page = try PageCodec.renderPage(text: tabletText, authorUUID: author)
        let out = dir.appendingPathComponent("\(docID).rmdoc")
        _ = try await Archive.pack(
            Archive.RmDoc(
                docID: docID,
                visibleName: "note",
                parent: "",
                pages: [Archive.RmDocPage(pageID: pageID, rmBytes: page)],
                version: 1
            ),
            to: out
        )
        return out
    }

    private func runGit(_ args: [String], cwd: URL) async throws {
        let result = try await Subprocess.run(executablePath: "git", args: args, cwd: cwd)
        #expect(result.exitCode == 0, "git \(args.joined(separator: " ")) failed: \(result.stderr)")
        if result.exitCode != 0 {
            throw FakeCloudError.unsupported("git")
        }
    }

    private func stat(id: String, modified: String) -> StatResult {
        StatResult(
            id: id,
            name: id,
            version: 0,
            modifiedClient: modified,
            type: "DocumentType",
            currentPage: 0,
            parent: ""
        )
    }
}

private enum FakeCloudError: Error {
    case statFailed(String)
    case unsupported(String)
}

private actor FakeCloud: CloudWriteClient {
    private var stats: [String: StatResult]
    private var archives: [String: URL]
    private let statFailures: Set<String>
    private(set) var putCount = 0
    private(set) var rmCount = 0

    init(
        stats: [String: StatResult],
        archives: [String: URL] = [:],
        statFailures: Set<String> = []
    ) {
        self.stats = stats
        self.archives = archives
        self.statFailures = statFailures
    }

    func stat(_ remotePath: String) async throws -> StatResult? {
        if statFailures.contains(remotePath) {
            throw FakeCloudError.statFailed(remotePath)
        }
        return stats[remotePath]
    }

    func tree(_ root: String) async throws -> [Node] {
        _ = root
        throw FakeCloudError.unsupported("tree")
    }

    func get(_ remotePath: String, dest: URL) async throws -> URL {
        guard let archive = archives[remotePath] else {
            throw FakeCloudError.unsupported("get")
        }
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let out = dest.appendingPathComponent(archive.lastPathComponent)
        if FileManager.default.fileExists(atPath: out.path) {
            try FileManager.default.removeItem(at: out)
        }
        try FileManager.default.copyItem(at: archive, to: out)
        return out
    }

    func put(local: URL, remoteParent: String, update: Bool) async throws {
        putCount += 1
        let name = local.deletingPathExtension().lastPathComponent
        let remotePath = "\(remoteParent)/\(name)"
        let existing = stats[remotePath]
        stats[remotePath] = StatResult(
            id: existing?.id ?? UUID().uuidString.lowercased(),
            name: name,
            version: 0,
            modifiedClient: "after-put-\(putCount)",
            type: "DocumentType",
            currentPage: 0,
            parent: ""
        )
        _ = update
    }

    func mkdir(_ remotePath: String) async throws {
        _ = remotePath
    }

    func mv(from src: String, to dst: String) async throws {
        guard let stat = stats.removeValue(forKey: src) else { return }
        stats[dst] = StatResult(
            id: stat.id,
            name: URL(fileURLWithPath: dst).lastPathComponent,
            version: stat.version,
            modifiedClient: stat.modifiedClient,
            type: stat.type,
            currentPage: stat.currentPage,
            parent: stat.parent
        )
        if let archive = archives.removeValue(forKey: src) {
            archives[dst] = archive
        }
    }

    func rm(_ remotePath: String) async throws {
        _ = remotePath
        rmCount += 1
    }
}
