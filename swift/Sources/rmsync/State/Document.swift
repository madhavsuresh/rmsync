import Foundation
import GRDB

/// One tracked reMarkable document. Mirrors the Python ``Document`` dataclass
/// and the ``documents`` table schema at v4.
///
/// Invariants carried over from the Python port (see ``CHANGES_FROM_SPEC.md``):
///   - ``pageIDs`` is persisted JSON; it MUST be reused across pushes of
///     the same doc to keep the cloud's sync15 cPages CRDT stable.
///   - ``localPath`` is an absolute POSIX path. The ``relocate`` subcommand
///     rewrites every row's prefix when the sync dir moves.
struct Document: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "documents"

    var docID: String
    var parentID: String
    var docType: String            // "DocumentType" | "CollectionType"
    var title: String
    var remotePath: String
    var localPath: String
    var remoteVersion: Int
    var remoteModified: String?
    var lastSyncedMDHash: String?
    var lastPullAt: String?
    var lastPushAt: String?
    var conflictState: String?     // nil | "unresolved"
    var errorState: String?        // nil | "parse_failed" | "push_validation_failed"
    var pageIDs: [String]          // serialized as JSON in the TEXT column

    enum CodingKeys: String, CodingKey {
        case docID = "doc_id"
        case parentID = "parent_id"
        case docType = "doc_type"
        case title
        case remotePath = "remote_path"
        case localPath = "local_path"
        case remoteVersion = "remote_version"
        case remoteModified = "remote_modified"
        case lastSyncedMDHash = "last_synced_md_hash"
        case lastPullAt = "last_pull_at"
        case lastPushAt = "last_push_at"
        case conflictState = "conflict_state"
        case errorState = "error_state"
        case pageIDs = "page_ids"
    }

    // GRDB record plumbing — the ``page_ids`` column is TEXT holding a JSON
    // array. GRDB doesn't auto-decode JSON-encoded arrays from TEXT, so we
    // override the row-level init.
    init(row: Row) throws {
        docID = row["doc_id"]
        parentID = row["parent_id"]
        docType = row["doc_type"]
        title = row["title"]
        remotePath = row["remote_path"]
        localPath = row["local_path"]
        remoteVersion = row["remote_version"]
        remoteModified = row["remote_modified"]
        lastSyncedMDHash = row["last_synced_md_hash"]
        lastPullAt = row["last_pull_at"]
        lastPushAt = row["last_push_at"]
        conflictState = row["conflict_state"]
        errorState = row["error_state"]
        let raw: String? = row["page_ids"]
        pageIDs = Self.decodePageIDs(raw)
    }

    func encode(to container: inout PersistenceContainer) {
        container["doc_id"] = docID
        container["parent_id"] = parentID
        container["doc_type"] = docType
        container["title"] = title
        container["remote_path"] = remotePath
        container["local_path"] = localPath
        container["remote_version"] = remoteVersion
        container["remote_modified"] = remoteModified
        container["last_synced_md_hash"] = lastSyncedMDHash
        container["last_pull_at"] = lastPullAt
        container["last_push_at"] = lastPushAt
        container["conflict_state"] = conflictState
        container["error_state"] = errorState
        container["page_ids"] = try? String(
            data: JSONEncoder().encode(pageIDs), encoding: .utf8
        )
    }

    // Memberwise init used by callers constructing new rows (Codable gives
    // us a synthesized init but overriding init(row:) above disables it).
    init(
        docID: String,
        parentID: String = "",
        docType: String = "DocumentType",
        title: String = "",
        remotePath: String = "",
        localPath: String = "",
        remoteVersion: Int = 0,
        remoteModified: String? = nil,
        lastSyncedMDHash: String? = nil,
        lastPullAt: String? = nil,
        lastPushAt: String? = nil,
        conflictState: String? = nil,
        errorState: String? = nil,
        pageIDs: [String] = []
    ) {
        self.docID = docID
        self.parentID = parentID
        self.docType = docType
        self.title = title
        self.remotePath = remotePath
        self.localPath = localPath
        self.remoteVersion = remoteVersion
        self.remoteModified = remoteModified
        self.lastSyncedMDHash = lastSyncedMDHash
        self.lastPullAt = lastPullAt
        self.lastPushAt = lastPushAt
        self.conflictState = conflictState
        self.errorState = errorState
        self.pageIDs = pageIDs
    }

    private static func decodePageIDs(_ raw: String?) -> [String] {
        guard let raw, let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}
