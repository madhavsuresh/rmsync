import Foundation

/// Well-known on-disk locations. Mirrors ``src/rm_sync/config.py`` constants.
///
/// Tests can override by setting the ``RM_SYNC_STATE_DIR`` /
/// ``RM_SYNC_CONFIG`` / ``RM_SYNC_LOG_DIR`` env vars, same as the Python
/// implementation.
enum Paths {
    static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    static var configPath: URL {
        if let override = ProcessInfo.processInfo.environment["RM_SYNC_CONFIG"] {
            return URL(fileURLWithPath: override)
        }
        return home.appendingPathComponent(".config/rmsync/config.toml")
    }

    static var stateDir: URL {
        if let override = ProcessInfo.processInfo.environment["RM_SYNC_STATE_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return home.appendingPathComponent(
            "Library/Application Support/rmsync", isDirectory: true
        )
    }

    static var logDir: URL {
        if let override = ProcessInfo.processInfo.environment["RM_SYNC_LOG_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return home.appendingPathComponent("Library/Logs/rmsync", isDirectory: true)
    }

    static var stateDBPath: URL { stateDir.appendingPathComponent("state.db") }
    static var statusJSONPath: URL { stateDir.appendingPathComponent("status.json") }
    static var ipcSocketPath: URL { stateDir.appendingPathComponent("ipc.sock") }
    static var pauseSentinel: URL { stateDir.appendingPathComponent("paused") }
    static var resyncDir: URL { stateDir.appendingPathComponent("resync", isDirectory: true) }
    static var backupDir: URL { stateDir.appendingPathComponent("backups", isDirectory: true) }
}
