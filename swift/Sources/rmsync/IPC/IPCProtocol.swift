import Foundation

/// Wire-level shapes for the daemon ↔ client IPC. Stable across the
/// Python and Swift daemons — the menu bar built for the Python version
/// works against the Swift daemon unchanged.
enum IPC {
    /// Mirrors the Python ``StateBus.Status`` payload, plus a daemon
    /// ``version`` field added in the Swift rewrite so clients can tell
    /// which binary the running daemon was loaded from (separate
    /// question from ``rmsync --version``, which reports the CLI's own
    /// compile-time version).
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
        var version: String
        /// Diagnostic for *why* pushes are failing, populated by
        /// ``CloudHealthProbe`` when the daemon hits its first
        /// ``rmapi put failed`` since startup. Values:
        ///   ``ok`` / ``rmapi_missing`` / ``auth_broken``
        ///   / ``rmapi_compat_break`` / ``unknown``
        /// Empty string means "no probe has run yet" (e.g.,
        /// daemon just started and no push has failed). v0.2.25+.
        var cloudHealth: String
        /// Human-readable detail about the most recent probe.
        /// Surfaced in `rmsync status` and the menubar tooltip.
        var cloudHealthDetail: String?

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
            case version
            case cloudHealth = "cloud_health"
            case cloudHealthDetail = "cloud_health_detail"
        }

        static let empty = Status(
            state: "idle", syncDir: "", remoteFolder: "", trackedDocs: 0,
            conflicts: 0, errors: 0, queueDepth: 0, lastPullAt: nil,
            lastPushAt: nil, lastError: nil, paused: false,
            updatedAt: "", pid: 0, version: "",
            cloudHealth: "", cloudHealthDetail: nil
        )
    }
}
