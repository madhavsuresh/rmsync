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
        #if os(macOS)
        return home.appendingPathComponent(
            "Library/Application Support/rmsync", isDirectory: true
        )
        #else
        // Linux: follow XDG. ``XDG_STATE_HOME`` defaults to
        // ``~/.local/state``. Docker users typically set
        // ``RM_SYNC_STATE_DIR=/state`` directly to bypass this.
        let xdg = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
            ?? home.appendingPathComponent(".local/state").path
        return URL(fileURLWithPath: xdg, isDirectory: true)
            .appendingPathComponent("rmsync", isDirectory: true)
        #endif
    }

    static var logDir: URL {
        if let override = ProcessInfo.processInfo.environment["RM_SYNC_LOG_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #if os(macOS)
        return home.appendingPathComponent("Library/Logs/rmsync", isDirectory: true)
        #else
        // Linux: live alongside state. The Docker entrypoint sets
        // ``RM_SYNC_LOG_STDOUT=1`` and lets ``Logger`` skip the file
        // sink entirely; this default only matters for bare-metal
        // Linux daemon installs.
        return stateDir.appendingPathComponent("logs", isDirectory: true)
        #endif
    }

    static var stateDBPath: URL { stateDir.appendingPathComponent("state.db") }
    static var statusJSONPath: URL { stateDir.appendingPathComponent("status.json") }
    static var ipcSocketPath: URL { stateDir.appendingPathComponent("ipc.sock") }
    static var pauseSentinel: URL { stateDir.appendingPathComponent("paused") }
    static var resyncDir: URL { stateDir.appendingPathComponent("resync", isDirectory: true) }
    static var backupDir: URL { stateDir.appendingPathComponent("backups", isDirectory: true) }

    static var stagingDir: URL {
        if let override = ProcessInfo.processInfo.environment["RM_SYNC_STAGING_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return stateDir.appendingPathComponent("staging", isDirectory: true)
    }

    static var scratchDir: URL {
        if let override = ProcessInfo.processInfo.environment["RM_SYNC_TMP_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return stateDir.appendingPathComponent("tmp", isDirectory: true)
    }

    static var remoteCacheDir: URL {
        if let override = ProcessInfo.processInfo.environment["RM_SYNC_CACHE_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return stateDir.appendingPathComponent("remote-cache", isDirectory: true)
    }
}
