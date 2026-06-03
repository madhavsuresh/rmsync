import Foundation
import Testing
@testable import rmsync

@Suite("Pull availability probe")
struct PullAvailabilityProbeTests {
    @Test("matching remote snapshot reports no pull work")
    func cleanSnapshotReportsNoChanges() async throws {
        let fixture = try await makeFixture()
        let cloud = ProbeCloud(nodes: [fixture.node])

        let result = try await PullAvailabilityProbe.measure(
            cfg: fixture.cfg,
            state: fixture.state,
            cloud: cloud
        )

        #expect(result.changes == 0)
        #expect(await cloud.getCalls() == 0)
    }

    @Test("remote additions edits and deletions count as pull work")
    func remoteChangesCountAsPullWork() async throws {
        let fixture = try await makeFixture()
        var changed = fixture.node
        changed.modifiedClient = "2026-06-03T01:00:00Z"
        changed.version = 2
        let added = node(id: "doc-added", name: "added", modified: "2026-06-03T00:00:00Z", version: 1)

        try await fixture.state.upsert(Document(
            docID: "doc-deleted",
            docType: "DocumentType",
            remotePath: "/sync/notes/deleted",
            localPath: fixture.syncDir.appendingPathComponent("deleted.md").path,
            remoteVersion: 1,
            remoteModified: "2026-06-02T00:00:00Z",
            lastSyncedMDHash: PathUtilities.sha256("deleted\n")
        ))

        let result = try await PullAvailabilityProbe.measure(
            cfg: fixture.cfg,
            state: fixture.state,
            cloud: ProbeCloud(nodes: [changed, added])
        )

        #expect(result.changes == 3)
    }

    private struct Fixture {
        var root: URL
        var syncDir: URL
        var cfg: Config
        var state: State
        var node: Node
    }

    private func makeFixture() async throws -> Fixture {
        let root = try tempDir()
        let syncDir = root.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncDir, withIntermediateDirectories: true)
        let state = try State(path: root.appendingPathComponent("state.db"))
        let cfg = Config(syncDir: syncDir)
        let remote = node(id: "doc-1", name: "note", modified: "2026-06-03T00:00:00Z", version: 1)
        let local = syncDir.appendingPathComponent("note.md")
        try "note\n".write(to: local, atomically: true, encoding: .utf8)

        try await state.upsert(Document(
            docID: remote.id,
            docType: "DocumentType",
            remotePath: remote.remotePath,
            localPath: local.path,
            remoteVersion: remote.version,
            remoteModified: remote.modifiedClient,
            lastSyncedMDHash: PathUtilities.sha256("note\n")
        ))
        try await state.upsertRemoteSnapshot(RemoteSnapshot(
            docID: remote.id,
            remotePath: remote.remotePath,
            remoteModified: remote.modifiedClient,
            remoteVersion: remote.version,
            remoteFingerprint: ExplicitSync.remoteFingerprint(remote),
            sourceHash: PathUtilities.sha256("note\n"),
            tabletHash: PathUtilities.sha256("note\n"),
            pageIDs: ["page-1"],
            cachedSourcePath: root.appendingPathComponent("note-cache.md").path,
            archiveHash: nil
        ))

        return Fixture(root: root, syncDir: syncDir, cfg: cfg, state: state, node: remote)
    }

    private func node(id: String, name: String, modified: String, version: Int) -> Node {
        Node(
            id: id,
            name: name,
            type: .document,
            parent: "folder-sync-notes",
            modifiedClient: modified,
            version: version,
            currentPage: 0,
            path: ["sync", "notes", name]
        )
    }

    private func tempDir() throws -> URL {
        let raw = ProcessInfo.processInfo.environment["RMSYNC_TEST_TMP"]
            ?? ProcessInfo.processInfo.environment["RM_SYNC_TMP_DIR"]
            ?? FileManager.default.temporaryDirectory.path
        let url = URL(fileURLWithPath: raw, isDirectory: true)
            .appendingPathComponent("rmsync-pull-probe-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor ProbeCloud: CloudClient {
    private var nodes: [Node]
    private var gets = 0

    init(nodes: [Node]) {
        self.nodes = nodes
    }

    func tree(_ root: String) async throws -> [Node] {
        nodes
    }

    func get(_ remotePath: String, dest: URL) async throws -> URL {
        gets += 1
        throw ProbeCloudError.unexpectedGet
    }

    func getCalls() -> Int {
        gets
    }
}

private enum ProbeCloudError: Error {
    case unexpectedGet
}
