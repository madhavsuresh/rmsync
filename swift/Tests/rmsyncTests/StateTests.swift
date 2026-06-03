import Foundation
import GRDB
import Testing
@testable import rmsync

@Suite("State DB")
struct StateTests {
    @Test("fresh DB opens at currentSchemaVersion")
    func freshDB() async throws {
        let dir = try tempDir()
        let dbPath = dir.appendingPathComponent("state.db")
        _ = try State(path: dbPath)

        // schema_version row exists at the expected version.
        try await assertSchemaVersion(dbPath, equals: SchemaMigrator.currentSchemaVersion)
        try await assertDocumentColumnsDoNotContainPendingOp(dbPath)
    }

    @Test("upsert + get round-trips a Document")
    func upsertRoundTrip() async throws {
        let dir = try tempDir()
        let state = try State(path: dir.appendingPathComponent("state.db"))

        let doc = Document(
            docID: "abc",
            parentID: "",
            docType: "DocumentType",
            remotePath: "/sync/notes/Hello",
            localPath: "/tmp/hello.md",
            remoteVersion: 1,
            lastSyncedMDHash: "deadbeef",
            lastSyncedTabletHash: "feedface",
            pageIDs: ["p1", "p2"]
        )
        try await state.upsert(doc)

        let loaded = try await state.get(docID: "abc")
        #expect(loaded != nil)
        #expect(loaded?.remotePath == "/sync/notes/Hello")
        #expect(loaded?.lastSyncedTabletHash == "feedface")
        #expect(loaded?.pageIDs == ["p1", "p2"])
    }

    @Test("pause/resume persists via settings")
    func pauseSetting() async throws {
        let dir = try tempDir()
        let state = try State(path: dir.appendingPathComponent("state.db"))

        #expect(try await state.isPaused() == false)
        try await state.setPaused(true)
        #expect(try await state.isPaused() == true)
        try await state.setPaused(false)
        #expect(try await state.isPaused() == false)
    }

    @Test("author_uuid is stable across calls")
    func authorUUIDStable() async throws {
        let dir = try tempDir()
        let state = try State(path: dir.appendingPathComponent("state.db"))

        let first = try await state.getOrCreateAuthorUUID()
        let second = try await state.getOrCreateAuthorUUID()
        #expect(first == second)
        // Sanity: it's a valid UUID string.
        #expect(UUID(uuidString: first) != nil)
    }

    @Test("mark_pulled updates columns and clears error")
    func markPulled() async throws {
        let dir = try tempDir()
        let state = try State(path: dir.appendingPathComponent("state.db"))

        try await state.upsert(Document(
            docID: "x",
            errorState: "parse_failed"
        ))
        try await state.markPulled(
            docID: "x",
            version: 2,
            mdHash: "abc",
            modified: "2026-04-18T00:00:00Z",
            tabletHash: "tablet"
        )
        let doc = try await state.get(docID: "x")
        #expect(doc?.errorState == nil)
        #expect(doc?.remoteVersion == 2)
        #expect(doc?.lastSyncedMDHash == "abc")
        #expect(doc?.lastSyncedTabletHash == "tablet")
        #expect(doc?.remoteModified == "2026-04-18T00:00:00Z")
    }

    @Test("remote snapshot round-trips through fresh v8 DB")
    func remoteSnapshotRoundTrip() async throws {
        let dir = try tempDir()
        let state = try State(path: dir.appendingPathComponent("state.db"))

        try await state.upsertRemoteSnapshot(RemoteSnapshot(
            docID: "doc",
            remotePath: "/sync/notes/doc",
            remoteModified: "2026-06-03T00:00:00Z",
            remoteVersion: 7,
            remoteFingerprint: "fingerprint",
            sourceHash: "source",
            tabletHash: "tablet",
            pageIDs: ["p1", "p2"],
            cachedSourcePath: "/cache/doc.md",
            archiveHash: "archive",
            fetchedAt: "2026-06-03T01:00:00Z"
        ))

        let loaded = try await state.remoteSnapshot(docID: "doc")
        #expect(loaded?.remotePath == "/sync/notes/doc")
        #expect(loaded?.remoteFingerprint == "fingerprint")
        #expect(loaded?.sourceHash == "source")
        #expect(loaded?.tabletHash == "tablet")
        #expect(loaded?.pageIDs == ["p1", "p2"])
        #expect(loaded?.cachedSourcePath == "/cache/doc.md")
        #expect(loaded?.archiveHash == "archive")
    }

    @Test("legacy v7 DB is rejected")
    func legacyV7Rejected() async throws {
        let dir = try tempDir()
        let dbPath = dir.appendingPathComponent("state.db")
        try createLegacyV7Database(at: dbPath)

        #expect(throws: SchemaMigrator.SchemaError.self) {
            _ = try State(path: dbPath)
        }
    }

    // MARK: - helpers

    private func tempDir() throws -> URL {
        let base: URL
        if let override = ProcessInfo.processInfo.environment["RM_SYNC_TMP_DIR"] {
            base = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            base = FileManager.default.temporaryDirectory
        }
        let url = base
            .appendingPathComponent("rmsync-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func assertSchemaVersion(_ dbPath: URL, equals expected: Int) async throws {
        let queue = try DatabaseQueue(path: dbPath.path)
        let actual = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT version FROM schema_version")
        }
        #expect(actual == expected)
    }

    private func assertDocumentColumnsDoNotContainPendingOp(_ dbPath: URL) async throws {
        let queue = try DatabaseQueue(path: dbPath.path)
        let columns = try await queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(documents)")
                .compactMap { (row: Row) in row["name"] as String? }
        }
        #expect(!columns.contains("pending_op"))
    }

    private func createLegacyV7Database(at dbPath: URL) throws {
        try FileManager.default.createDirectory(
            at: dbPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let queue = try DatabaseQueue(path: dbPath.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE schema_version (
                    version INTEGER PRIMARY KEY
                );
                INSERT INTO schema_version(version) VALUES (7);
                CREATE TABLE documents (
                    doc_id                  TEXT PRIMARY KEY,
                    parent_id               TEXT NOT NULL,
                    doc_type                TEXT NOT NULL,
                    remote_path             TEXT NOT NULL,
                    local_path              TEXT NOT NULL,
                    remote_version          INTEGER NOT NULL,
                    remote_modified         TEXT,
                    last_synced_md_hash     TEXT,
                    last_pull_at            TEXT,
                    last_push_at            TEXT,
                    conflict_state          TEXT,
                    error_state             TEXT,
                    page_ids                TEXT,
                    pending_op              TEXT,
                    last_synced_tablet_hash TEXT
                );
                CREATE INDEX idx_parent      ON documents(parent_id);
                CREATE INDEX idx_local_path  ON documents(local_path);
                CREATE INDEX idx_remote_path ON documents(remote_path);
                CREATE TABLE settings (
                    key   TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                CREATE TABLE sync_log (
                    id      INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts      TEXT NOT NULL,
                    level   TEXT NOT NULL,
                    doc_id  TEXT,
                    message TEXT NOT NULL
                );
                """)
        }
    }
}
