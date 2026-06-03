import Foundation
import Testing
@testable import rmsync

@Suite("Explicit pull", .serialized)
struct ExplicitPullTests {
    @Test("unchanged accepted doc uses cached snapshot without rmapi get")
    func unchangedAcceptedDocSkipsCloudGet() async throws {
        let fixture = try await makeFixture(localText: "same\n", acceptedText: "same\n")
        let cloud = FakePullCloud(nodes: [fixture.node], archives: [:])

        let result = try await ExplicitSync.stagePull(
            cfg: fixture.cfg, state: fixture.state, cloud: cloud
        )

        #expect(await cloud.getCallCount() == 0)
        #expect(result.entries.count == 1)
        #expect(result.entries[0].kind == .unchanged)
        #expect(result.entries[0].stagedPath == nil)
    }

    @Test("local edit with unchanged remote uses cached snapshot and reports local_modified")
    func localModifiedDocSkipsCloudGet() async throws {
        let fixture = try await makeFixture(localText: "local edit\n", acceptedText: "remote base\n")
        let cloud = FakePullCloud(nodes: [fixture.node], archives: [:])

        let result = try await ExplicitSync.stagePull(
            cfg: fixture.cfg, state: fixture.state, cloud: cloud
        )

        #expect(await cloud.getCallCount() == 0)
        #expect(result.entries.count == 1)
        #expect(result.entries[0].kind == .localModified)
        #expect(result.entries[0].stagedPath == nil)
    }

    @Test("cached remote change stages cached source without rmapi get")
    func remoteChangedDocStagesCachedSource() async throws {
        let fixture = try await makeFixture(localText: "old\n", acceptedText: "old\n", cachedText: "new\n")
        let cloud = FakePullCloud(nodes: [fixture.node], archives: [:])

        let result = try await ExplicitSync.stagePull(
            cfg: fixture.cfg, state: fixture.state, cloud: cloud
        )

        #expect(await cloud.getCallCount() == 0)
        #expect(result.entries[0].kind == .modified)
        let staged = try #require(result.entries[0].stagedPath)
        let text = try String(contentsOf: fixture.resultRoot(result).appendingPathComponent(staged), encoding: .utf8)
        #expect(text == "new\n")
    }

    @Test("accepting a changed pull records overwritten local text")
    func acceptRecordsPullOverwriteSnapshot() async throws {
        let fixture = try await makeFixture(localText: "old\n", acceptedText: "old\n", cachedText: "new\n")
        let cloud = FakePullCloud(nodes: [fixture.node], archives: [:])

        _ = try await ExplicitSync.stagePull(
            cfg: fixture.cfg, state: fixture.state, cloud: cloud
        )
        let accepted = try await ExplicitSync.accept(
            cfg: fixture.cfg,
            state: fixture.state,
            paths: ["doc.md"],
            all: false,
            includeDeletes: false,
            force: false
        )

        #expect(accepted.applied == 1)
        #expect(accepted.refused.isEmpty)
        let local = fixture.cfg.syncDir.appendingPathComponent("doc.md")
        #expect(try String(contentsOf: local, encoding: .utf8) == "new\n")
        let snapshots = try Snapshots.list(docID: "doc-1", in: await fixture.state.storageDir())
        let last = try #require(snapshots.last)
        #expect(last.cause == Snapshots.Cause.pullOverwrite)
        #expect(try Snapshots.read(last) == "old\n")
    }

    @Test("accepted cloud change is cleared from staged diff")
    func acceptedCloudChangeIsClearedFromStagedDiff() async throws {
        let fixture = try await makeFixture(localText: "old\n", acceptedText: "old\n", cachedText: "new\n")
        let cloud = FakePullCloud(nodes: [fixture.node], archives: [:])

        _ = try await ExplicitSync.stagePull(
            cfg: fixture.cfg, state: fixture.state, cloud: cloud
        )
        let accepted = try await ExplicitSync.accept(
            cfg: fixture.cfg,
            state: fixture.state,
            paths: ["doc.md"],
            all: false,
            includeDeletes: false,
            force: false
        )

        #expect(accepted.applied == 1)
        #expect(accepted.refused.isEmpty)

        let (stageRoot, manifest) = try ExplicitSync.loadCurrentStage()
        let entry = try #require(manifest.entries.first { $0.docID == "doc-1" })
        let acceptedHash = PathUtilities.sha256("new\n")
        #expect(entry.kind == .unchanged)
        #expect(entry.stagedPath == nil)
        #expect(entry.localHashAtPull == acceptedHash)
        #expect(entry.baselineHash == acceptedHash)

        let diff = try ExplicitSync.diffText(manifest, root: stageRoot, path: "doc.md")
        #expect(diff.isEmpty)
    }

    @Test("cache hash mismatch falls back to rmapi get")
    func corruptCacheFallsBackToCloudGet() async throws {
        let fixture = try await makeFixture(
            localText: "old\n",
            acceptedText: "old\n",
            cachedText: "corrupt\n",
            storedCacheHash: PathUtilities.sha256("not the cache\n"),
            archiveText: "downloaded\n"
        )
        let cloud = FakePullCloud(nodes: [fixture.node], archives: [fixture.node.remotePath: fixture.archive])

        let result = try await ExplicitSync.stagePull(
            cfg: fixture.cfg, state: fixture.state, cloud: cloud
        )

        #expect(await cloud.getCallCount() == 1)
        #expect(result.entries[0].kind == .modified)
        let staged = try #require(result.entries[0].stagedPath)
        let text = try String(contentsOf: fixture.resultRoot(result).appendingPathComponent(staged), encoding: .utf8)
        #expect(text.contains("downloaded"))
    }

    @Test("missing local file can be restored from cached snapshot")
    func missingLocalFileStagesCachedSnapshot() async throws {
        let fixture = try await makeFixture(localText: nil, acceptedText: "old\n", cachedText: "old\n")
        let cloud = FakePullCloud(nodes: [fixture.node], archives: [:])

        let result = try await ExplicitSync.stagePull(
            cfg: fixture.cfg, state: fixture.state, cloud: cloud
        )

        #expect(await cloud.getCallCount() == 0)
        #expect(result.entries[0].kind == .added)
        #expect(result.entries[0].stagedPath != nil)
    }

    @Test("changed remote fingerprint downloads fresh archive")
    func changedFingerprintDownloads() async throws {
        let fixture = try await makeFixture(
            localText: "old\n",
            acceptedText: "old\n",
            cachedText: "old\n",
            archiveText: "new remote\n"
        )
        var changed = fixture.node
        changed.modifiedClient = "2026-06-04T00:00:00Z"
        let cloud = FakePullCloud(nodes: [changed], archives: [changed.remotePath: fixture.archive])

        let result = try await ExplicitSync.stagePull(
            cfg: fixture.cfg, state: fixture.state, cloud: cloud
        )

        #expect(await cloud.getCallCount() == 1)
        #expect(result.entries[0].kind == .modified)
    }

    @Test("full pull bypasses valid cache")
    func fullPullAlwaysDownloads() async throws {
        let fixture = try await makeFixture(localText: "same\n", acceptedText: "same\n", archiveText: "same\n")
        let cloud = FakePullCloud(nodes: [fixture.node], archives: [fixture.node.remotePath: fixture.archive])

        let result = try await ExplicitSync.stagePull(
            cfg: fixture.cfg, state: fixture.state, cloud: cloud, full: true
        )

        #expect(await cloud.getCallCount() == 1)
        #expect(result.entries[0].kind == .unchanged)
    }

    private struct Fixture {
        var root: URL
        var cfg: Config
        var state: State
        var node: Node
        var archive: URL

        func resultRoot(_ result: ExplicitSync.StageResult) -> URL {
            result.root
        }
    }

    private func makeFixture(
        localText: String?,
        acceptedText: String,
        cachedText: String? = nil,
        storedCacheHash: String? = nil,
        archiveText: String? = nil
    ) async throws -> Fixture {
        let root = try tempDir()
        let syncDir = root.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncDir, withIntermediateDirectories: true)
        let state = try State(path: root.appendingPathComponent("state.db"))
        let cfg = Config(syncDir: syncDir)
        let node = Node(
            id: "doc-1",
            name: "doc",
            type: .document,
            parent: "folder-1",
            modifiedClient: "2026-06-03T00:00:00Z",
            version: 7,
            currentPage: 0,
            path: ["sync", "notes", "doc"]
        )
        let localURL = syncDir.appendingPathComponent("doc.md")
        if let localText {
            try localText.write(to: localURL, atomically: true, encoding: .utf8)
        }

        try await state.upsert(Document(
            docID: node.id,
            docType: "DocumentType",
            remotePath: node.remotePath,
            localPath: localURL.path,
            remoteVersion: node.version,
            remoteModified: node.modifiedClient,
            lastSyncedMDHash: PathUtilities.sha256(acceptedText),
            lastSyncedTabletHash: PathUtilities.sha256(acceptedText),
            pageIDs: ["page-1"]
        ))

        let cacheText = cachedText ?? acceptedText
        let cachePath = root.appendingPathComponent("cached-source.md")
        try cacheText.write(to: cachePath, atomically: true, encoding: .utf8)
        try await state.upsertRemoteSnapshot(RemoteSnapshot(
            docID: node.id,
            remotePath: node.remotePath,
            remoteModified: node.modifiedClient,
            remoteVersion: node.version,
            remoteFingerprint: ExplicitSync.remoteFingerprint(node),
            sourceHash: storedCacheHash ?? PathUtilities.sha256(cacheText),
            tabletHash: PathUtilities.sha256(cacheText),
            pageIDs: ["page-1"],
            cachedSourcePath: cachePath.path,
            archiveHash: nil
        ))

        let archive = try await makeArchive(
            root: root,
            text: archiveText ?? cacheText,
            docID: node.id,
            visibleName: "doc"
        )
        return Fixture(root: root, cfg: cfg, state: state, node: node, archive: archive)
    }

    private func makeArchive(root: URL, text: String, docID: String, visibleName: String) async throws -> URL {
        let archiveDir = root.appendingPathComponent("archive-src", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        let pageID = "page-\(UUID().uuidString)"
        let pageBytes = try PageCodec.renderPage(
            text: text,
            authorUUID: "11111111-2222-3333-4444-555555555555"
        )
        let archiveURL = archiveDir.appendingPathComponent("\(visibleName).rmdoc")
        _ = try await Archive.pack(
            Archive.RmDoc(
                docID: docID,
                visibleName: visibleName,
                parent: "",
                pages: [Archive.RmDocPage(pageID: pageID, rmBytes: pageBytes)],
                version: 1
            ),
            to: archiveURL
        )
        return archiveURL
    }

    private func tempDir() throws -> URL {
        let base: URL
        if let override = ProcessInfo.processInfo.environment["RM_SYNC_TMP_DIR"] {
            base = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            base = FileManager.default.temporaryDirectory
        }
        let url = base.appendingPathComponent("rmsync-explicit-pull-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor FakePullCloud: CloudClient {
    private var nodes: [Node]
    private var archives: [String: URL]
    private var getCalls = 0

    init(nodes: [Node], archives: [String: URL]) {
        self.nodes = nodes
        self.archives = archives
    }

    func tree(_ root: String) async throws -> [Node] {
        nodes
    }

    func get(_ remotePath: String, dest: URL) async throws -> URL {
        getCalls += 1
        guard let archive = archives[remotePath] else {
            throw ExplicitSync.SyncError.cloudMissing(remotePath)
        }
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let out = dest.appendingPathComponent(archive.lastPathComponent)
        if FileManager.default.fileExists(atPath: out.path) {
            try FileManager.default.removeItem(at: out)
        }
        try FileManager.default.copyItem(at: archive, to: out)
        return out
    }

    func getCallCount() -> Int {
        getCalls
    }
}
