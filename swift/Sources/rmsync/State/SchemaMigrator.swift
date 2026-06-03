import Foundation
import GRDB

/// Creates and verifies the current explicit-sync state schema.
///
/// This version intentionally does not migrate older rmsync layouts. Users
/// upgrading from pre-namespace or background-sync releases are expected to do
/// a full reinstall, so stale databases are rejected rather than reshaped.
enum SchemaMigrator {
    static let currentSchemaVersion = 10

    enum SchemaError: Error, CustomStringConvertible {
        case reinstallRequired(String)

        var description: String {
            switch self {
            case .reinstallRequired(let detail):
                return """
                unsupported old state database: \(detail). This rmsync version requires a fresh reinstall; move the old state.db aside and rerun `rmsync init`.
                """
            }
        }
    }

    static func migrate(_ writer: any DatabaseWriter) throws {
        try writer.write { db in
            if try hasAnyStateTables(db) {
                guard try isCurrentSchema(db) else {
                    throw SchemaError.reinstallRequired("schema does not match current v\(currentSchemaVersion)")
                }
                return
            }
            try createCurrentSchema(db)
        }
    }

    private static func createCurrentSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE schema_version (
                version INTEGER PRIMARY KEY
            );
            INSERT INTO schema_version(version) VALUES (\(currentSchemaVersion));

            CREATE TABLE documents (
                doc_id                  TEXT PRIMARY KEY,
                parent_id               TEXT NOT NULL,
                doc_type                TEXT NOT NULL,
                remote_path             TEXT NOT NULL,
                local_path              TEXT NOT NULL,
                remote_version          INTEGER NOT NULL,
                remote_modified         TEXT,
                last_synced_md_hash     TEXT,
                last_synced_tablet_hash TEXT,
                last_pull_at            TEXT,
                last_push_at            TEXT,
                conflict_state          TEXT,
                error_state             TEXT,
                page_ids                TEXT
            );
            CREATE INDEX idx_parent      ON documents(parent_id);
            CREATE INDEX idx_local_path  ON documents(local_path);
            CREATE INDEX idx_remote_path ON documents(remote_path);

            CREATE TABLE sync_log (
                id      INTEGER PRIMARY KEY AUTOINCREMENT,
                ts      TEXT NOT NULL,
                level   TEXT NOT NULL,
                doc_id  TEXT,
                message TEXT NOT NULL
            );

            CREATE TABLE settings (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            CREATE TABLE remote_snapshots (
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
            CREATE INDEX idx_remote_snapshots_fingerprint
                ON remote_snapshots(remote_fingerprint);
            CREATE INDEX idx_remote_snapshots_path
                ON remote_snapshots(remote_path);

            CREATE TABLE auto_push_ops (
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
            CREATE INDEX idx_auto_push_ops_state
                ON auto_push_ops(state);
            CREATE INDEX idx_auto_push_ops_path
                ON auto_push_ops(path);
            """)
    }

    private static func hasAnyStateTables(_ db: Database) throws -> Bool {
        let names = try String.fetchAll(
            db,
            sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        )
        return !names.isEmpty
    }

    private static func isCurrentSchema(_ db: Database) throws -> Bool {
        guard try tableExists(db, "schema_version"),
              try tableExists(db, "documents"),
              try tableExists(db, "settings"),
              try tableExists(db, "sync_log"),
              try tableExists(db, "remote_snapshots"),
              try tableExists(db, "auto_push_ops")
        else { return false }

        let version = try Int.fetchOne(db, sql: "SELECT version FROM schema_version")
        guard version == currentSchemaVersion else { return false }

        let requiredDocumentColumns: Set<String> = [
            "doc_id", "parent_id", "doc_type", "remote_path", "local_path",
            "remote_version", "remote_modified", "last_synced_md_hash",
            "last_synced_tablet_hash", "last_pull_at", "last_push_at",
            "conflict_state", "error_state", "page_ids",
        ]
        let documentColumns = try columns(db, table: "documents")
        guard documentColumns == requiredDocumentColumns else { return false }

        let remoteSnapshotColumns: Set<String> = [
            "doc_id", "remote_path", "remote_modified", "remote_version",
            "remote_fingerprint", "source_hash", "tablet_hash", "page_ids",
            "cached_source_path", "archive_hash", "fetched_at",
        ]
        guard try columns(db, table: "remote_snapshots") == remoteSnapshotColumns else {
            return false
        }

        let autoPushColumns: Set<String> = [
            "id", "created_at", "updated_at", "state", "path", "doc_id",
            "local_hash", "baseline_remote_modified", "attempt_count",
            "reason", "remote_modified",
        ]
        return try columns(db, table: "auto_push_ops") == autoPushColumns
    }

    private static func tableExists(_ db: Database, _ table: String) throws -> Bool {
        try String.fetchOne(
            db,
            sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
            arguments: [table]
        ) != nil
    }

    private static func columns(_ db: Database, table: String) throws -> Set<String> {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        return Set(rows.compactMap { (row: Row) in row["name"] as String? })
    }
}
