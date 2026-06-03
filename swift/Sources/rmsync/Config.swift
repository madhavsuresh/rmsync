import Foundation
import TOMLDecoder

/// User-editable configuration loaded from ``~/.config/rmsync/config.toml``.
///
/// The supported config shape is the current explicit-sync model only. Older
/// daemon/poller/worker keys are rejected at load time so a stale config cannot
/// silently run with different semantics after a reinstall-oriented upgrade.
struct Config: Decodable, Sendable {
    static let defaultSyncDirName = "rmsync-notes"
    static let defaultRemoteFolder = "sync/notes"

    var syncDir: URL
    var remoteFolder: String
    var echoFenceSeconds: Double
    var backupSnapshotsToKeep: Int
    var log: LogConfig
    var autoPush: AutoPushConfig
    var web: WebConfig?
    var deletion: DeletionConfig

    enum ConfigError: Error, CustomStringConvertible {
        case unsupportedLegacyKey(String)
        case unsupportedRemoteFolder(String)

        var description: String {
            switch self {
            case .unsupportedLegacyKey(let key):
                return """
                unsupported legacy config key '\(key)'. This rmsync version supports only the explicit sync config; move old state aside and rerun `rmsync init`.
                """
            case .unsupportedRemoteFolder(let folder):
                return """
                unsupported remote_folder '\(folder)'. This rmsync version only supports '\(Config.defaultRemoteFolder)'; reinstall with a fresh config.
                """
            }
        }
    }

    struct LogConfig: Decodable, Sendable {
        var level: Level
        enum Level: String, Decodable, Sendable {
            case debug = "DEBUG"
            case info = "INFO"
            case warning = "WARNING"
            case error = "ERROR"
        }
    }

    struct AutoPushConfig: Decodable, Sendable {
        var enabled: Bool
        var newFiles: Bool
        var debounceSeconds: Double
        var stableSampleCount: Int
        var scanIntervalSeconds: Int
        var maxPushesPerMinute: Int

        enum CodingKeys: String, CodingKey {
            case enabled
            case newFiles = "new_files"
            case debounceSeconds = "debounce_seconds"
            case stableSampleCount = "stable_sample_count"
            case scanIntervalSeconds = "scan_interval_seconds"
            case maxPushesPerMinute = "max_pushes_per_minute"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            self.newFiles = try c.decodeIfPresent(Bool.self, forKey: .newFiles) ?? true
            self.debounceSeconds = try c.decodeIfPresent(Double.self, forKey: .debounceSeconds) ?? 2.0
            self.stableSampleCount = max(1, try c.decodeIfPresent(Int.self, forKey: .stableSampleCount) ?? 2)
            self.scanIntervalSeconds = max(1, try c.decodeIfPresent(Int.self, forKey: .scanIntervalSeconds) ?? 30)
            self.maxPushesPerMinute = max(1, try c.decodeIfPresent(Int.self, forKey: .maxPushesPerMinute) ?? 30)
        }

        init(
            enabled: Bool = false,
            newFiles: Bool = true,
            debounceSeconds: Double = 2.0,
            stableSampleCount: Int = 2,
            scanIntervalSeconds: Int = 30,
            maxPushesPerMinute: Int = 30
        ) {
            self.enabled = enabled
            self.newFiles = newFiles
            self.debounceSeconds = debounceSeconds
            self.stableSampleCount = max(1, stableSampleCount)
            self.scanIntervalSeconds = max(1, scanIntervalSeconds)
            self.maxPushesPerMinute = max(1, maxPushesPerMinute)
        }
    }

    struct DeletionConfig: Decodable, Sendable {
        /// Retention for files explicitly parked in ``.rmsync-trash`` by
        /// user-facing recovery commands. Hidden background delete
        /// propagation no longer exists.
        var trashRetentionDays: Int

        enum CodingKeys: String, CodingKey {
            case trashRetentionDays = "trash_retention_days"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.trashRetentionDays = try c.decodeIfPresent(Int.self, forKey: .trashRetentionDays) ?? 30
        }

        init(trashRetentionDays: Int = 30) {
            self.trashRetentionDays = trashRetentionDays
        }
    }

    struct WebConfig: Decodable, Sendable {
        var enabled: Bool
        var bindAddr: String
        var port: Int
        var authToken: String?

        enum CodingKeys: String, CodingKey {
            case enabled
            case bindAddr = "bind_addr"
            case port
            case authToken = "auth_token"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            self.bindAddr = try c.decodeIfPresent(String.self, forKey: .bindAddr) ?? "127.0.0.1"
            self.port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 7878
            self.authToken = try c.decodeIfPresent(String.self, forKey: .authToken)
        }

        init(enabled: Bool = false, bindAddr: String = "127.0.0.1", port: Int = 7878, authToken: String? = nil) {
            self.enabled = enabled
            self.bindAddr = bindAddr
            self.port = port
            self.authToken = authToken
        }
    }

    enum CodingKeys: String, CodingKey {
        case syncDir = "sync_dir"
        case remoteFolder = "remote_folder"
        case echoFenceSeconds = "echo_fence_seconds"
        case backupSnapshotsToKeep = "backup_snapshots_to_keep"
        case log
        case autoPush = "auto_push"
        case web
        case deletion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawSync = try c.decode(String.self, forKey: .syncDir)
        self.syncDir = URL(fileURLWithPath: NSString(string: rawSync).expandingTildeInPath)
        self.remoteFolder = try c.decodeIfPresent(String.self, forKey: .remoteFolder)
            ?? Self.defaultRemoteFolder
        let normalized = PathUtilities.normalizedRemoteFolder(self.remoteFolder)
        guard normalized == Self.defaultRemoteFolder else {
            throw ConfigError.unsupportedRemoteFolder(self.remoteFolder)
        }
        self.remoteFolder = normalized
        self.echoFenceSeconds = try c.decodeIfPresent(Double.self, forKey: .echoFenceSeconds) ?? 5.0
        self.backupSnapshotsToKeep = try c.decodeIfPresent(Int.self, forKey: .backupSnapshotsToKeep) ?? 30
        self.log = try c.decodeIfPresent(LogConfig.self, forKey: .log)
            ?? LogConfig(level: .info)
        self.autoPush = try c.decodeIfPresent(AutoPushConfig.self, forKey: .autoPush)
            ?? AutoPushConfig()
        self.web = try c.decodeIfPresent(WebConfig.self, forKey: .web)
        self.deletion = try c.decodeIfPresent(DeletionConfig.self, forKey: .deletion)
            ?? DeletionConfig()
    }

    static func load(from path: URL = Paths.configPath) throws -> Config {
        let data = try Data(contentsOf: path)
        let text = String(data: data, encoding: .utf8) ?? ""
        try rejectUnsupportedLegacyKeys(in: text)
        return try TOMLDecoder().decode(Config.self, from: text)
    }

    /// Memberwise constructor for tests and internal materialized sync contexts.
    /// Production config files still go through ``load`` and its stricter
    /// remote namespace validation.
    init(
        syncDir: URL,
        remoteFolder: String = Config.defaultRemoteFolder,
        echoFenceSeconds: Double = 5.0,
        backupSnapshotsToKeep: Int = 30,
        log: LogConfig = LogConfig(level: .info),
        autoPush: AutoPushConfig = AutoPushConfig(),
        web: WebConfig? = nil,
        deletion: DeletionConfig = DeletionConfig()
    ) {
        self.syncDir = syncDir
        self.remoteFolder = PathUtilities.normalizedRemoteFolder(remoteFolder)
        self.echoFenceSeconds = echoFenceSeconds
        self.backupSnapshotsToKeep = backupSnapshotsToKeep
        self.log = log
        self.autoPush = autoPush
        self.web = web
        self.deletion = deletion
    }

    private static func rejectUnsupportedLegacyKeys(in text: String) throws {
        let unsupportedTopLevel: Set<String> = [
            "worker_pool_size",
            "poll_interval_seconds",
            "poll_active_interval_seconds",
            "poll_idle_interval_seconds",
            "debounce_seconds",
            "rename_detect_window_s",
            "retry_max_attempts",
            "push_strategy",
            "dry_run",
        ]
        let unsupportedTables: Set<String> = ["inbox"]
        let unsupportedDeletionKeys: Set<String> = [
            "enable_propagation",
            "bulk_delete_threshold",
            "bulk_delete_window_seconds",
        ]

        var table = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                table = String(trimmed.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if unsupportedTables.contains(table) {
                    throw ConfigError.unsupportedLegacyKey("[\(table)]")
                }
                continue
            }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<equals])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if table.isEmpty, unsupportedTopLevel.contains(key) {
                throw ConfigError.unsupportedLegacyKey(key)
            }
            if table == "deletion", unsupportedDeletionKeys.contains(key) {
                throw ConfigError.unsupportedLegacyKey("deletion.\(key)")
            }
        }
    }
}
