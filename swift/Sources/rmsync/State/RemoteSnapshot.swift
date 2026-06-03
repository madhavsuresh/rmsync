import Foundation
import GRDB

/// Durable rendered snapshot of a remote reMarkable document.
///
/// This is deliberately separate from ``documents``: snapshots record what
/// the cloud looked like when it was fetched, while ``documents`` records
/// what the user has accepted into the local tree.
struct RemoteSnapshot: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "remote_snapshots"

    var docID: String
    var remotePath: String
    var remoteModified: String?
    var remoteVersion: Int
    var remoteFingerprint: String
    var sourceHash: String
    var tabletHash: String?
    var pageIDs: [String]
    var cachedSourcePath: String
    var archiveHash: String?
    var fetchedAt: String

    enum CodingKeys: String, CodingKey {
        case docID = "doc_id"
        case remotePath = "remote_path"
        case remoteModified = "remote_modified"
        case remoteVersion = "remote_version"
        case remoteFingerprint = "remote_fingerprint"
        case sourceHash = "source_hash"
        case tabletHash = "tablet_hash"
        case pageIDs = "page_ids"
        case cachedSourcePath = "cached_source_path"
        case archiveHash = "archive_hash"
        case fetchedAt = "fetched_at"
    }

    init(row: Row) throws {
        docID = row["doc_id"]
        remotePath = row["remote_path"]
        remoteModified = row["remote_modified"]
        remoteVersion = row["remote_version"]
        remoteFingerprint = row["remote_fingerprint"]
        sourceHash = row["source_hash"]
        tabletHash = row["tablet_hash"]
        let raw: String? = row["page_ids"]
        pageIDs = Self.decodePageIDs(raw)
        cachedSourcePath = row["cached_source_path"]
        archiveHash = row["archive_hash"]
        fetchedAt = row["fetched_at"]
    }

    func encode(to container: inout PersistenceContainer) {
        container["doc_id"] = docID
        container["remote_path"] = remotePath
        container["remote_modified"] = remoteModified
        container["remote_version"] = remoteVersion
        container["remote_fingerprint"] = remoteFingerprint
        container["source_hash"] = sourceHash
        container["tablet_hash"] = tabletHash
        container["page_ids"] = try? String(
            data: JSONEncoder().encode(pageIDs), encoding: .utf8
        )
        container["cached_source_path"] = cachedSourcePath
        container["archive_hash"] = archiveHash
        container["fetched_at"] = fetchedAt
    }

    init(
        docID: String,
        remotePath: String,
        remoteModified: String? = nil,
        remoteVersion: Int = 0,
        remoteFingerprint: String,
        sourceHash: String,
        tabletHash: String? = nil,
        pageIDs: [String] = [],
        cachedSourcePath: String,
        archiveHash: String? = nil,
        fetchedAt: String = ISO8601.now()
    ) {
        self.docID = docID
        self.remotePath = remotePath
        self.remoteModified = remoteModified
        self.remoteVersion = remoteVersion
        self.remoteFingerprint = remoteFingerprint
        self.sourceHash = sourceHash
        self.tabletHash = tabletHash
        self.pageIDs = pageIDs
        self.cachedSourcePath = cachedSourcePath
        self.archiveHash = archiveHash
        self.fetchedAt = fetchedAt
    }

    private static func decodePageIDs(_ raw: String?) -> [String] {
        guard let raw, let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}
