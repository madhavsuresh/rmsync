import Foundation
import Testing
@testable import rmsync

@Suite("Explicit push")
struct ExplicitPushTests {
    @Test("unchanged tracked file is skipped without touching rmapi")
    func unchangedTrackedFileSkipsCloudWork() async throws {
        let dir = try Self.tempDir()
        let state = try State(path: dir.appendingPathComponent("state.db"))

        let mdPath = dir.appendingPathComponent("same.md")
        let text = "already synced\n"
        try text.write(to: mdPath, atomically: true, encoding: .utf8)

        try await state.upsert(Document(
            docID: "same-doc",
            docType: "DocumentType",
            remotePath: "/sync/notes/same",
            localPath: mdPath.path,
            remoteModified: "2026-06-03T00:00:00Z",
            lastSyncedMDHash: PathUtilities.sha256(text),
            pageIDs: ["page-1"]
        ))

        let result = try await ExplicitSync.push(
            cfg: Config(syncDir: dir),
            state: state,
            cloud: Cloud(rmapiPath: "/usr/bin/false"),
            paths: [mdPath.path],
            includeDeletes: false,
            force: false
        )

        #expect(result.pushed == 0)
        #expect(result.skipped == 1)
        #expect(result.refused.isEmpty)
    }

    @Test("bare push counts multiple unchanged tracked files as skipped")
    func barePushCountsUnchangedFilesAsSkipped() async throws {
        let dir = try Self.tempDir()
        let state = try State(path: dir.appendingPathComponent("state.db"))

        for idx in 1...3 {
            let leaf = "same-\(idx).md"
            let mdPath = dir.appendingPathComponent(leaf)
            let text = "already synced \(idx)\n"
            try text.write(to: mdPath, atomically: true, encoding: .utf8)
            let canonicalPath = try Self.canonicalPath(in: dir, leaf: leaf)

            try await state.upsert(Document(
                docID: "same-doc-\(idx)",
                docType: "DocumentType",
                remotePath: "/sync/notes/same-\(idx)",
                localPath: canonicalPath,
                remoteModified: "2026-06-03T00:00:00Z",
                lastSyncedMDHash: PathUtilities.sha256(text),
                pageIDs: ["page-\(idx)"]
            ))
        }

        let result = try await ExplicitSync.push(
            cfg: Config(syncDir: dir),
            state: state,
            cloud: Cloud(rmapiPath: "/usr/bin/false"),
            paths: [],
            includeDeletes: false,
            force: false
        )

        #expect(result.pushed == 0)
        #expect(result.skipped == 3)
        #expect(result.refused.isEmpty)
    }

    @Test("successful push records a local history snapshot")
    func pushRecordsSnapshot() async throws {
        let dir = try Self.tempDir()
        let state = try State(path: dir.appendingPathComponent("state.db"))
        let mdPath = dir.appendingPathComponent("fresh.md")
        try "fresh\n".write(to: mdPath, atomically: true, encoding: .utf8)
        let cloud = SnapshotPushCloud()

        let result = try await ExplicitSync.push(
            cfg: Config(syncDir: dir),
            state: state,
            cloud: cloud,
            paths: [mdPath.path],
            includeDeletes: false,
            force: false
        )

        #expect(result.pushed == 1)
        #expect(result.refused.isEmpty)
        #expect(await cloud.putCount() == 1)

        let doc = try #require(try await state.byLocalPath(mdPath.path))
        let snapshots = try Snapshots.list(docID: doc.docID, in: await state.storageDir())
        let last = try #require(snapshots.last)
        #expect(last.cause == Snapshots.Cause.push)
        #expect(try Snapshots.read(last) == "fresh\n")
    }

    private static func tempDir() throws -> URL {
        let base: URL
        if let override = ProcessInfo.processInfo.environment["RM_SYNC_TMP_DIR"] {
            base = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            base = FileManager.default.temporaryDirectory
        }
        let url = base.appendingPathComponent("rmsync-explicit-push-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func canonicalPath(in dir: URL, leaf: String) throws -> String {
        let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil, options: []
        )
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == leaf { return url.path }
        }
        throw ExplicitSync.SyncError.invalidPath(leaf)
    }
}

private actor SnapshotPushCloud: CloudWriteClient {
    private var puts = 0

    func putCount() -> Int { puts }

    func tree(_ root: String) async throws -> [Node] { [] }

    func get(_ remotePath: String, dest: URL) async throws -> URL {
        throw SnapshotPushCloudError.unsupported
    }

    func stat(_ remotePath: String) async throws -> StatResult? { nil }

    func put(local: URL, remoteParent: String, update: Bool) async throws {
        puts += 1
    }

    func mkdir(_ remotePath: String) async throws {}

    func mv(from src: String, to dst: String) async throws {
        throw SnapshotPushCloudError.unsupported
    }

    func rm(_ remotePath: String) async throws {
        throw SnapshotPushCloudError.unsupported
    }
}

private enum SnapshotPushCloudError: Error {
    case unsupported
}
