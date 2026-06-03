import Foundation
import GRDB

/// Keeps the ``schema_version`` row honest. Fresh databases open at v9.
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

        // v6 — drop ``title``. The column was a denormalized cache of
        // "what is this doc called" with two authoritative sources
        // (local stem, cloud rmdoc.visibleName) and a write-amplification
        // bug: ``renameRemote`` / ``renameOnLocal`` updated paths but
        // not ``title``, so retried pushes after a local rename packed
        // the rmdoc under the stale stem and the cloud rejected with
        // HTTP 400 (UUID/name mismatch). Killing the field eliminates
        // the bug class — push now reads the local stem directly. Pull
        // ignores ``rmdoc.visibleName`` because the local filename is
        // the WYSIWYG source of truth (v0.2.27+ filenames sync both
        // ways). SQLite ``DROP COLUMN`` lands in 3.35 (Mar 2021); we
        // require macOS 13+ which ships 3.39+.
        migrator.registerMigration("v6_drop_documents_title") { db in
            if try columnExists(db, table: "documents", column: "title") {
                try db.execute(sql: "ALTER TABLE documents DROP COLUMN title")
            }
        }

        // v7 — track the text actually written to the tablet separately
        // from the source Markdown hash. This lets pulls preserve the exact
        // local source bytes when the tablet-side spacing-normalized text has
        // not changed.
        migrator.registerMigration("v7_tablet_hash") { db in
            if try !columnExists(db, table: "documents", column: "last_synced_tablet_hash") {
                try db.execute(
                    sql: "ALTER TABLE documents ADD COLUMN last_synced_tablet_hash TEXT"
                )
            }
        }

        // v8 — durable pull-side remote snapshot cache. This lets an
        // explicit pull skip rmapi downloads for remote documents whose
        // stat-derived fingerprint is already rendered and verified in
        // the cache. It is separate from documents so a staged pull can
        // be cached without marking the remote content as accepted.
        migrator.registerMigration("v8_remote_snapshots") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS remote_snapshots (
                    doc_id              TEXT PRIMARY KEY,
                    remote_path         TEXT NOT NULL,
                    remote_modified     TEXT,
                    remote_version      INTEGER NOT NULL,
                    remote_fingerprint  TEXT NOT NULL,
                    source_hash         TEXT NOT NULL,
                    tablet_hash         TEXT,
                    page_ids            TEXT NOT NULL,
                    cached_source_path  TEXT NOT NULL,
                    archive_hash        TEXT,
                    fetched_at          TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_remote_snapshots_fingerprint
                    ON remote_snapshots(remote_fingerprint);
                CREATE INDEX IF NOT EXISTS idx_remote_snapshots_path
                    ON remote_snapshots(remote_path);
                """)
        }

        // v9 — durable auto-push operation ledger. Auto-push records an
        // operation before upload, then updates it after verification. On
        // restart, interrupted rows are surfaced for manual verification
        // instead of being blindly replayed.
        migrator.registerMigration("v9_auto_push_ops") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS auto_push_ops (
                    id                       INTEGER PRIMARY KEY AUTOINCREMENT,
                    created_at               TEXT NOT NULL,
                    updated_at               TEXT NOT NULL,
                    state                    TEXT NOT NULL,
                    path                     TEXT NOT NULL,
                    doc_id                   TEXT,
                    local_hash               TEXT,
                    baseline_remote_modified TEXT,
                    attempt_count            INTEGER NOT NULL DEFAULT 0,
                    reason                   TEXT,
                    remote_modified          TEXT
                );
                CREATE INDEX IF NOT EXISTS idx_auto_push_ops_state
                    ON auto_push_ops(state);
                CREATE INDEX IF NOT EXISTS idx_auto_push_ops_path
                    ON auto_push_ops(path);
                """)
        }

        try migrator.migrate(writer)

        // Keep the legacy ``schema_version`` row in sync for the CLI
        // fallback and for anything still talking to the Python schema.
        try writer.write { db in
            try db.execute(sql: "DELETE FROM schema_version")
            try db.execute(
                sql: "INSERT OR REPLACE INTO schema_version(version) VALUES (?)",
                arguments: [currentSchemaVersion]
            )
        }
    }

    static let currentSchemaVersion = 9

    private static func columnExists(
        _ db: Database, table: String, column: String
    ) throws -> Bool {
        let rows = try Row.fetchAll(
            db, sql: "PRAGMA table_info(\(table))"
        )
        return rows.contains { (row: Row) in (row["name"] as String?) == column }
    }
}
