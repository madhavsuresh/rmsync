import Foundation
import GRDB

/// Thread-safe wrapper over the rmsync state database.
///
/// Mirrors the API of the Python ``State`` class as closely as makes sense
/// in Swift. All methods are ``async`` even when the underlying GRDB call
/// is synchronous — so callers don't have to change when we later move
/// long-running operations off the main database queue.
actor State {
    private let writer: any DatabaseWriter

    init(path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        self.writer = try DatabasePool(path: path.path, configuration: config)
        try SchemaMigrator.migrate(self.writer)
    }

    // MARK: - documents

    func get(docID: String) throws -> Document? {
        try writer.read { db in
            try Document.fetchOne(db, sql: "SELECT * FROM documents WHERE doc_id = ?", arguments: [docID])
        }
    }

    func byLocalPath(_ path: String) throws -> Document? {
        try writer.read { db in
            try Document.fetchOne(
                db, sql: "SELECT * FROM documents WHERE local_path = ?", arguments: [path]
            )
        }
    }

    func allDocuments() throws -> [Document] {
        try writer.read { db in
            try Document.fetchAll(db, sql: "SELECT * FROM documents")
        }
    }

    func upsert(_ doc: Document) throws {
        try writer.write { db in
            try doc.save(db)
        }
    }

    func delete(docID: String) throws {
        _ = try writer.write { db in
            try Document.deleteOne(db, key: docID)
        }
    }

    func setConflict(docID: String, state: String?) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE documents SET conflict_state = ? WHERE doc_id = ?",
                arguments: [state, docID]
            )
        }
    }

    func setError(docID: String, state: String?) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE documents SET error_state = ? WHERE doc_id = ?",
                arguments: [state, docID]
            )
        }
    }

    func markPulled(
        docID: String, version: Int, mdHash: String, modified: String?
    ) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE documents
                SET remote_version = ?, remote_modified = ?, last_synced_md_hash = ?,
                    last_pull_at = ?, error_state = NULL
                WHERE doc_id = ?
                """,
                arguments: [version, modified, mdHash, ISO8601.now(), docID]
            )
        }
    }

    func markPushed(
        docID: String, version: Int, mdHash: String, modified: String?
    ) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE documents
                SET remote_version = ?, remote_modified = ?, last_synced_md_hash = ?,
                    last_push_at = ?, error_state = NULL
                WHERE doc_id = ?
                """,
                arguments: [version, modified, mdHash, ISO8601.now(), docID]
            )
        }
    }

    /// Stamp / clear the in-flight ``pending_op`` marker. Set
    /// before a destructive cloud call begins, cleared on success.
    /// Schema v5+. Pass ``nil`` to clear.
    func setPendingOp(docID: String, op: String?) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE documents SET pending_op = ? WHERE doc_id = ?",
                arguments: [op, docID]
            )
        }
    }

    /// Every row whose ``pending_op`` is non-NULL — used by the
    /// startup reconciler to resume rename / delete operations
    /// that didn't finish before the daemon last exited.
    func pendingOpDocs() throws -> [Document] {
        try writer.read { db in
            try Document.fetchAll(
                db, sql: "SELECT * FROM documents WHERE pending_op IS NOT NULL"
            )
        }
    }

    func setPageIDs(docID: String, pageIDs: [String]) throws {
        let blob = String(
            data: try JSONEncoder().encode(pageIDs), encoding: .utf8
        ) ?? "[]"
        try writer.write { db in
            try db.execute(
                sql: "UPDATE documents SET page_ids = ? WHERE doc_id = ?",
                arguments: [blob, docID]
            )
        }
    }

    // MARK: - settings

    func getSetting(_ key: String) throws -> String? {
        try writer.read { db in
            try String.fetchOne(
                db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key]
            )
        }
    }

    func setSetting(_ key: String, _ value: String) throws {
        try writer.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)",
                arguments: [key, value]
            )
        }
    }

    func isPaused() throws -> Bool {
        (try getSetting("paused")) == "1"
    }

    func setPaused(_ paused: Bool) throws {
        try setSetting("paused", paused ? "1" : "0")
    }

    func getOrCreateAuthorUUID() throws -> String {
        if let existing = try getSetting("author_uuid") {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        try setSetting("author_uuid", fresh)
        return fresh
    }

    /// The daemon-binary version stamped at the end of the most
    /// recent successful startup reconcile. Compared against
    /// ``Version.current`` on the next startup; a mismatch means
    /// "first run after an upgrade" and the destructive
    /// reconcile passes (delete-cascade especially) get a
    /// one-cycle grace period. v0.2.31+.
    ///
    /// Returns ``nil`` for state.db files that predate this
    /// setting (Python era, or any Swift version <0.2.31). Treat
    /// nil as "first run after upgrade" — same conservative
    /// behavior.
    func getLastSeenDaemonVersion() throws -> String? {
        try getSetting("last_seen_daemon_version")
    }

    func setLastSeenDaemonVersion(_ version: String) throws {
        try setSetting("last_seen_daemon_version", version)
    }

    // MARK: - log

    func log(level: String, message: String, docID: String? = nil) throws {
        try writer.write { db in
            try db.execute(
                sql: "INSERT INTO sync_log(ts, level, doc_id, message) VALUES (?, ?, ?, ?)",
                arguments: [ISO8601.now(), level, docID, message]
            )
        }
    }
}

enum ISO8601 {
    /// Per-call allocation avoids sharing a mutable ``ISO8601DateFormatter``
    /// across actors. Formatters are cheap to construct and this call site
    /// fires at most a few times per minute.
    static func now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}
