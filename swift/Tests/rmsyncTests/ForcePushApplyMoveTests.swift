import Foundation
import Testing
@testable import rmsync

@Suite("Explicit force-push move apply")
struct ForcePushApplyMoveTests {
    @Test("pure move calls mv without put or rm")
    func pureMoveUsesCloudMoveOnly() async throws {
        let dir = try Self.tempDir()
        let state = try State(path: dir.appendingPathComponent("state.db"))
        let text = "same\n"
        let local = dir.appendingPathComponent("new.md")
        try text.write(to: local, atomically: true, encoding: .utf8)
        try await state.upsert(Self.document(localPath: dir.appendingPathComponent("old.md").path))

        let hash = PathUtilities.sha256(text)
        let plan = ExplicitSync.ForcePushPlan(
            stage: ExplicitSync.StageResult(id: "stage", root: dir, entries: []),
            items: ExplicitSync.forcePushPlanItems(
                remoteEntries: [Self.entry("old.md", hash: hash)],
                localFiles: [Self.localFile("new.md", url: local, hash: hash)],
                remoteFolder: Config.defaultRemoteFolder,
                renames: [ExplicitSync.ForcePushRename(oldPath: "old.md", newPath: "new.md")]
            )
        )
        let cloud = RecordingForcePushCloud()

        let result = try await ExplicitSync.applyForcePush(
            plan,
            cfg: Config(syncDir: dir, remoteFolder: Config.defaultRemoteFolder),
            state: state,
            cloud: cloud
        )

        #expect(result.moved == 1)
        #expect(result.created == 0)
        #expect(result.overwritten == 0)
        #expect(result.deleted == 0)
        #expect(result.refused.isEmpty)
        let operations = await cloud.operations()
        #expect(operations.contains("mv:/sync/notes/old->/sync/notes/new"))
        #expect(!operations.contains { $0.hasPrefix("put:") })
        #expect(!operations.contains { $0.hasPrefix("rm:") })

        let moved = try await state.get(docID: "doc-old.md")
        #expect(moved?.remotePath == "/sync/notes/new")
        #expect(moved?.localPath == local.path)
    }

    @Test("move with edit calls mv then forced put")
    func moveWithEditMovesThenUpdates() async throws {
        let dir = try Self.tempDir()
        let state = try State(path: dir.appendingPathComponent("state.db"))
        let local = dir.appendingPathComponent("new.md")
        try "local\n".write(to: local, atomically: true, encoding: .utf8)
        try await state.upsert(Self.document(localPath: dir.appendingPathComponent("old.md").path))

        let plan = ExplicitSync.ForcePushPlan(
            stage: ExplicitSync.StageResult(id: "stage", root: dir, entries: []),
            items: ExplicitSync.forcePushPlanItems(
                remoteEntries: [Self.entry("old.md", hash: PathUtilities.sha256("remote\n"))],
                localFiles: [Self.localFile("new.md", url: local, hash: PathUtilities.sha256("local\n"))],
                remoteFolder: Config.defaultRemoteFolder,
                renames: [ExplicitSync.ForcePushRename(oldPath: "old.md", newPath: "new.md")]
            )
        )
        let cloud = RecordingForcePushCloud()

        let result = try await ExplicitSync.applyForcePush(
            plan,
            cfg: Config(syncDir: dir, remoteFolder: Config.defaultRemoteFolder),
            state: state,
            cloud: cloud
        )

        #expect(result.moved == 1)
        #expect(result.overwritten == 1)
        #expect(result.refused.isEmpty)
        let operations = await cloud.operations()
        #expect(operations.contains("put:/sync/notes:update=true"))
        if let moveIndex = operations.firstIndex(of: "mv:/sync/notes/old->/sync/notes/new"),
           let putIndex = operations.firstIndex(of: "put:/sync/notes:update=true") {
            #expect(moveIndex < putIndex)
        } else {
            Issue.record("missing expected move or put operation: \(operations)")
        }
        #expect(!operations.contains { $0.hasPrefix("rm:") })
    }

    @Test("delete create fallback does not call mv")
    func fallbackDeleteCreateDoesNotMove() async throws {
        let dir = try Self.tempDir()
        let state = try State(path: dir.appendingPathComponent("state.db"))
        let local = dir.appendingPathComponent("new.md")
        try "new\n".write(to: local, atomically: true, encoding: .utf8)
        try await state.upsert(Self.document(localPath: dir.appendingPathComponent("old.md").path))

        let plan = ExplicitSync.ForcePushPlan(
            stage: ExplicitSync.StageResult(id: "stage", root: dir, entries: []),
            items: ExplicitSync.forcePushPlanItems(
                remoteEntries: [Self.entry("old.md", hash: PathUtilities.sha256("old\n"))],
                localFiles: [Self.localFile("new.md", url: local, hash: PathUtilities.sha256("new\n"))],
                remoteFolder: Config.defaultRemoteFolder
            )
        )
        let cloud = RecordingForcePushCloud()

        _ = try await ExplicitSync.applyForcePush(
            plan,
            cfg: Config(syncDir: dir, remoteFolder: Config.defaultRemoteFolder),
            state: state,
            cloud: cloud
        )

        let operations = await cloud.operations()
        #expect(!operations.contains { $0.hasPrefix("mv:") })
        #expect(operations.contains("rm:/sync/notes/old"))
        #expect(operations.contains("put:/sync/notes:update=false"))
    }

    private static func document(localPath: String) -> Document {
        Document(
            docID: "doc-old.md",
            docType: "DocumentType",
            remotePath: "/sync/notes/old",
            localPath: localPath,
            remoteVersion: 7,
            remoteModified: "2026-06-03T00:00:00Z",
            lastSyncedMDHash: PathUtilities.sha256("remote\n"),
            lastSyncedTabletHash: PathUtilities.sha256("remote\n"),
            pageIDs: ["page-1"]
        )
    }

    private static func localFile(_ rel: String, url: URL, hash: String) -> ExplicitSync.LocalFile {
        ExplicitSync.LocalFile(url: url, relativePath: rel, hash: hash)
    }

    private static func entry(_ rel: String, hash: String) -> ExplicitSync.Entry {
        let stem = rel.hasSuffix(".md") ? String(rel.dropLast(3)) : rel
        return ExplicitSync.Entry(
            kind: .modified,
            docID: "doc-\(rel)",
            remotePath: "/sync/notes/\(stem)",
            localPath: "/sync/\(rel)",
            relativePath: rel,
            stagedPath: "files/\(rel)",
            remoteModified: "2026-06-03T00:00:00Z",
            remoteVersion: 7,
            remoteHash: hash,
            remoteTabletHash: hash,
            localHashAtPull: nil,
            baselineHash: nil,
            pageIDs: ["page-1"],
            error: nil
        )
    }

    private static func tempDir() throws -> URL {
        let base: URL
        if let override = ProcessInfo.processInfo.environment["RM_SYNC_TMP_DIR"] {
            base = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            base = FileManager.default.temporaryDirectory
        }
        let url = base.appendingPathComponent("rmsync-force-push-move-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor RecordingForcePushCloud: CloudWriteClient {
    private var log: [String] = []

    func operations() -> [String] { log }

    func tree(_ root: String) async throws -> [Node] { [] }

    func get(_ remotePath: String, dest: URL) async throws -> URL {
        throw RecordingCloudError.unsupported
    }

    func stat(_ remotePath: String) async throws -> StatResult? {
        StatResult(
            id: "doc-old.md",
            name: URL(fileURLWithPath: remotePath).lastPathComponent,
            version: 8,
            modifiedClient: "2026-06-03T00:00:01Z",
            type: "DocumentType",
            currentPage: 0,
            parent: ""
        )
    }

    func put(local: URL, remoteParent: String, update: Bool) async throws {
        log.append("put:\(remoteParent):update=\(update)")
    }

    func mkdir(_ remotePath: String) async throws {
        log.append("mkdir:\(remotePath)")
    }

    func mv(from src: String, to dst: String) async throws {
        log.append("mv:\(src)->\(dst)")
    }

    func rm(_ remotePath: String) async throws {
        log.append("rm:\(remotePath)")
    }
}

private enum RecordingCloudError: Error {
    case unsupported
}
