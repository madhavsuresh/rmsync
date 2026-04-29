import Foundation
import GRDB

/// Keeps the ``schema_version`` row honest. Fresh databases open at v4.
/// Older DBs from the Python implementation migrate in place: each step
/// is idempotent and safe to re-run.
///
/// The migration sequence must match the Python version byte-for-byte —
/// see ``src/rm_sync/state.py:State._migrate`` in the legacy tree.
enum SchemaMigrator {
    static func migrate(_ writer: any DatabaseWriter) throws {
        var migrator = DatabaseMigrator()

        // v1 — original schema. Kept empty because legacy DBs already
        // created everything via the old executescript path; fresh DBs
        // get the full v4 schema up front in this v1 step.
        migrator.registerMigration("v1_base_schema") { db in
            // ``IF NOT EXISTS`` everywhere so the migrator plays nicely
            // with pre-existing Python-created DBs.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS schema_version (
                    version INTEGER PRIMARY KEY
                );
                CREATE TABLE IF NOT EXISTS documents (
                    doc_id              TEXT PRIMARY KEY,
                    parent_id           TEXT NOT NULL,
                    doc_type            TEXT NOT NULL,
                    title               TEXT NOT NULL,
                    remote_path         TEXT NOT NULL,
                    local_path          TEXT NOT NULL,
                    remote_version      INTEGER NOT NULL,
                    remote_modified     TEXT,
                    last_synced_md_hash TEXT,
                    last_pull_at        TEXT,
                    last_push_at        TEXT,
                    conflict_state      TEXT,
                    error_state         TEXT
                );
                CREATE INDEX IF NOT EXISTS idx_parent       ON documents(parent_id);
                CREATE INDEX IF NOT EXISTS idx_local_path   ON documents(local_path);
                CREATE INDEX IF NOT EXISTS idx_remote_path  ON documents(remote_path);
                CREATE TABLE IF NOT EXISTS sync_log (
                    id      INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts      TEXT NOT NULL,
                    level   TEXT NOT NULL,
                    doc_id  TEXT,
                    message TEXT NOT NULL
                );
                """)
        }

        // v2 — add page_ids (stable sync15 cPages entries).
        migrator.registerMigration("v2_page_ids") { db in
            if try !columnExists(db, table: "documents", column: "page_ids") {
                try db.execute(sql: "ALTER TABLE documents ADD COLUMN page_ids TEXT")
            }
        }

        // v3 — add settings table. The Python port also seeded
        // ``author_uuid`` on first access; we do the same lazily in
        // ``State.getOrCreateAuthorUUID()``.
        migrator.registerMigration("v3_settings") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS settings (
                    key   TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                """)
        }

        // v4 — migrate old file-based ``paused`` sentinel into
        // ``settings.paused`` so IPC can toggle it.
        migrator.registerMigration("v4_paused_setting") { db in
            let sentinel = Paths.pauseSentinel
            if FileManager.default.fileExists(atPath: sentinel.path) {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)",
                    arguments: ["paused", "1"]
                )
                try? FileManager.default.removeItem(at: sentinel)
            }
        }

        // v5 — add ``pending_op`` to track in-flight destructive
        // operations across daemon restarts. Set before a cloud
        // delete / rename begins, cleared on success. The startup
        // reconciler reads this column to resume any operation
        // that was interrupted (process killed mid-cloud-call,
        // network hiccup, etc.). See the rename / delete
        // propagation feature flag in ``Config.deletion``.
        migrator.registerMigration("v5_pending_op") { db in
            if try !columnExists(db, table: "documents", column: "pending_op") {
                try db.execute(
                    sql: "ALTER TABLE documents ADD COLUMN pending_op TEXT"
                )
            }
        }

        try migrator.migrate(writer)

        // Keep the legacy ``schema_version`` row in sync for the CLI
        // fallback and for anything still talking to the Python schema.
        try writer.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO schema_version(version) VALUES (?)",
                arguments: [currentSchemaVersion]
            )
        }
    }

    static let currentSchemaVersion = 5

    private static func columnExists(
        _ db: Database, table: String, column: String
    ) throws -> Bool {
        let rows = try Row.fetchAll(
            db, sql: "PRAGMA table_info(\(table))"
        )
        return rows.contains { (row: Row) in (row["name"] as String?) == column }
    }
}
