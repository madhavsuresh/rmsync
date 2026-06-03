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
            remotePath: "/Writing/same",
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
                remotePath: "/Writing/same-\(idx)",
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
