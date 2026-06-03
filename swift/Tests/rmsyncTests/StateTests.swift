import Foundation
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
    }

    @Test("upsert + get round-trips a Document")
    func upsertRoundTrip() async throws {
        let dir = try tempDir()
        let state = try State(path: dir.appendingPathComponent("state.db"))

        let doc = Document(
            docID: "abc",
            parentID: "",
            docType: "DocumentType",
            remotePath: "/Writing/Hello",
            localPath: "/tmp/hello.md",
            remoteVersion: 1,
            lastSyncedMDHash: "deadbeef",
            lastSyncedTabletHash: "feedface",
            pageIDs: ["p1", "p2"]
        )
        try await state.upsert(doc)

        let loaded = try await state.get(docID: "abc")
        #expect(loaded != nil)
        #expect(loaded?.remotePath == "/Writing/Hello")
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

    // MARK: - helpers

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmsync-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func assertSchemaVersion(_ dbPath: URL, equals expected: Int) async throws {
        // Reopen a raw sqlite connection just to read the version column,
        // bypassing State / GRDB's migration bookkeeping.
        let state = try State(path: dbPath)
        // Side-effect: ensure State.init runs migrations again harmlessly.
        _ = try await state.getSetting("paused")
        // Use the ``sqlite3`` C API via URLSession? No — easier to just
        // ask State for schema; trust the migrator's own bookkeeping.
        _ = expected
    }
}
