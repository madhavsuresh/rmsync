import Foundation

/// Wire-level shapes for the daemon ↔ client IPC. Stable across the
/// Python and Swift daemons — the menu bar built for the Python version
/// works against the Swift daemon unchanged.
enum IPC {
    /// Mirrors the Python ``StateBus.Status`` payload.
    struct Status: Codable, Sendable {
        var state: String                      // idle|syncing|paused|error|stopped
        var syncDir: String
        var remoteFolder: String
        var trackedDocs: Int
        var conflicts: Int
        var errors: Int
        var queueDepth: Int
        var lastPullAt: String?
        var lastPushAt: String?
        var lastError: String?
        var paused: Bool
        var updatedAt: String
        var pid: Int

        enum CodingKeys: String, CodingKey {
            case state
            case syncDir = "sync_dir"
            case remoteFolder = "remote_folder"
            case trackedDocs = "tracked_docs"
            case conflicts
            case errors
            case queueDepth = "queue_depth"
            case lastPullAt = "last_pull_at"
            case lastPushAt = "last_push_at"
            case lastError = "last_error"
            case paused
            case updatedAt = "updated_at"
            case pid
        }

        static let empty = Status(
            state: "idle", syncDir: "", remoteFolder: "", trackedDocs: 0,
            conflicts: 0, errors: 0, queueDepth: 0, lastPullAt: nil,
            lastPushAt: nil, lastError: nil, paused: false,
            updatedAt: "", pid: 0
        )
    }
}
