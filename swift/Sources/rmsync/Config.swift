import Foundation
import TOMLDecoder

/// User-editable configuration loaded from ``~/.config/rm-sync/config.toml``.
///
/// Field names mirror the Python Pydantic model in ``src/rm_sync/config.py``
/// so the same TOML file works with both the old and new daemon.
struct Config: Decodable, Sendable {
    var syncDir: URL
    var remoteFolder: String
    var workerPoolSize: Int
    var pollIntervalSeconds: Int
    var pollActiveIntervalSeconds: Int
    var pollIdleIntervalSeconds: Int
    var debounceSeconds: Double
    var renameDetectWindowS: Double
    var echoFenceSeconds: Double
    var retryMaxAttempts: Int
    var pushStrategy: PushStrategy
    var backupSnapshotsToKeep: Int
    var dryRun: Bool
    var log: LogConfig

    enum PushStrategy: String, Decodable, Sendable {
        case nativePlain = "native_plain"
        case nativeFormatted = "native_formatted"
        case pdf
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

    // TOML → Swift: TOMLDecoder handles snake_case natively if we map
    // keys explicitly. Keeping the TOML shape verbatim from the Python
    // config means no migration for existing users.
    enum CodingKeys: String, CodingKey {
        case syncDir = "sync_dir"
        case remoteFolder = "remote_folder"
        case workerPoolSize = "worker_pool_size"
        case pollIntervalSeconds = "poll_interval_seconds"
        case pollActiveIntervalSeconds = "poll_active_interval_seconds"
        case pollIdleIntervalSeconds = "poll_idle_interval_seconds"
        case debounceSeconds = "debounce_seconds"
        case renameDetectWindowS = "rename_detect_window_s"
        case echoFenceSeconds = "echo_fence_seconds"
        case retryMaxAttempts = "retry_max_attempts"
        case pushStrategy = "push_strategy"
        case backupSnapshotsToKeep = "backup_snapshots_to_keep"
        case dryRun = "dry_run"
        case log
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawSync = try c.decode(String.self, forKey: .syncDir)
        self.syncDir = URL(fileURLWithPath: NSString(string: rawSync).expandingTildeInPath)
        self.remoteFolder = try c.decodeIfPresent(String.self, forKey: .remoteFolder) ?? "Writing"
        self.workerPoolSize = try c.decodeIfPresent(Int.self, forKey: .workerPoolSize) ?? 3
        self.pollIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? 30
        self.pollActiveIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .pollActiveIntervalSeconds) ?? 15
        self.pollIdleIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .pollIdleIntervalSeconds) ?? 120
        self.debounceSeconds = try c.decodeIfPresent(Double.self, forKey: .debounceSeconds) ?? 2.0
        self.renameDetectWindowS = try c.decodeIfPresent(Double.self, forKey: .renameDetectWindowS) ?? 5.0
        self.echoFenceSeconds = try c.decodeIfPresent(Double.self, forKey: .echoFenceSeconds) ?? 5.0
        self.retryMaxAttempts = try c.decodeIfPresent(Int.self, forKey: .retryMaxAttempts) ?? 3
        self.pushStrategy = try c.decodeIfPresent(PushStrategy.self, forKey: .pushStrategy) ?? .nativePlain
        self.backupSnapshotsToKeep = try c.decodeIfPresent(Int.self, forKey: .backupSnapshotsToKeep) ?? 30
        self.dryRun = try c.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false
        self.log = try c.decodeIfPresent(LogConfig.self, forKey: .log)
            ?? LogConfig(level: .info)
    }

    // MARK: - loading

    static func load(from path: URL = Paths.configPath) throws -> Config {
        let data = try Data(contentsOf: path)
        let text = String(data: data, encoding: .utf8) ?? ""
        return try TOMLDecoder().decode(Config.self, from: text)
    }

    /// Memberwise constructor for tests and other direct callers. Production
    /// code always goes through :py:meth:`load` for real config files.
    init(
        syncDir: URL,
        remoteFolder: String = "Writing",
        workerPoolSize: Int = 3,
        pollIntervalSeconds: Int = 30,
        pollActiveIntervalSeconds: Int = 15,
        pollIdleIntervalSeconds: Int = 120,
        debounceSeconds: Double = 2.0,
        renameDetectWindowS: Double = 5.0,
        echoFenceSeconds: Double = 5.0,
        retryMaxAttempts: Int = 3,
        pushStrategy: PushStrategy = .nativePlain,
        backupSnapshotsToKeep: Int = 30,
        dryRun: Bool = false,
        log: LogConfig = LogConfig(level: .info)
    ) {
        self.syncDir = syncDir
        self.remoteFolder = remoteFolder
        self.workerPoolSize = workerPoolSize
        self.pollIntervalSeconds = pollIntervalSeconds
        self.pollActiveIntervalSeconds = pollActiveIntervalSeconds
        self.pollIdleIntervalSeconds = pollIdleIntervalSeconds
        self.debounceSeconds = debounceSeconds
        self.renameDetectWindowS = renameDetectWindowS
        self.echoFenceSeconds = echoFenceSeconds
        self.retryMaxAttempts = retryMaxAttempts
        self.pushStrategy = pushStrategy
        self.backupSnapshotsToKeep = backupSnapshotsToKeep
        self.dryRun = dryRun
        self.log = log
    }
}

