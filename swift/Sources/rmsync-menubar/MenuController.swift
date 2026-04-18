import AppKit

/// Owns the NSMenu and keeps its items in sync with the latest snapshot.
/// Everything dynamic (status line, conflict count, pause-vs-resume) is
/// held as separate NSMenuItems so we can mutate them in-place without
/// rebuilding the whole menu on each status change.
@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu()

    private let titleItem = NSMenuItem()
    private let statusItem = NSMenuItem()
    private let pullItem = NSMenuItem()
    private let pushItem = NSMenuItem()
    private let openFolderItem = NSMenuItem()
    private let conflictsItem = NSMenuItem()
    private let pauseItem = NSMenuItem()
    private let syncNowItem = NSMenuItem()
    private let restartItem = NSMenuItem()
    private let logsItem = NSMenuItem()
    private let prefsItem = NSMenuItem()
    private let quitItem = NSMenuItem()

    private var snapshot: StatusSnapshot?
    private let ipc: IPCClient

    init(ipc: IPCClient) {
        self.ipc = ipc
        super.init()
        menu.delegate = self
        buildMenu()
    }

    // MARK: - construction

    private func buildMenu() {
        titleItem.title = "rmsync"
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        statusItem.title = "Loading…"
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        pullItem.isEnabled = false
        pushItem.isEnabled = false
        menu.addItem(pullItem)
        menu.addItem(pushItem)

        menu.addItem(.separator())

        openFolderItem.title = "Open Sync Folder"
        openFolderItem.target = self
        openFolderItem.action = #selector(openSyncFolder(_:))
        menu.addItem(openFolderItem)

        conflictsItem.title = "Show Conflicts"
        conflictsItem.target = self
        conflictsItem.action = #selector(openConflicts(_:))
        menu.addItem(conflictsItem)

        menu.addItem(.separator())

        pauseItem.title = "Pause"
        pauseItem.target = self
        pauseItem.action = #selector(togglePause(_:))
        menu.addItem(pauseItem)

        syncNowItem.title = "Sync Now"
        syncNowItem.target = self
        syncNowItem.action = #selector(syncNow(_:))
        menu.addItem(syncNowItem)

        restartItem.title = "Restart Daemon"
        restartItem.target = self
        restartItem.action = #selector(restartDaemon(_:))
        menu.addItem(restartItem)

        menu.addItem(.separator())

        logsItem.title = "Open Logs"
        logsItem.target = self
        logsItem.action = #selector(openLogs(_:))
        menu.addItem(logsItem)

        prefsItem.title = "Edit Config…"
        prefsItem.target = self
        prefsItem.action = #selector(openConfig(_:))
        menu.addItem(prefsItem)

        menu.addItem(.separator())

        quitItem.title = "Quit Menu Bar"
        quitItem.keyEquivalent = "q"
        quitItem.target = self
        quitItem.action = #selector(quit(_:))
        menu.addItem(quitItem)
    }

    // MARK: - snapshot → UI

    func apply(snapshot: StatusSnapshot?) {
        self.snapshot = snapshot

        if let s = snapshot {
            statusItem.title = humanState(s)
            pullItem.title = "Last pull: \(shortTime(s.lastPullAt))"
            pushItem.title = "Last push: \(shortTime(s.lastPushAt))"
            pauseItem.title = s.state == "paused" ? "Resume" : "Pause"

            if s.conflicts > 0 {
                conflictsItem.title = "Show Conflicts (\(s.conflicts))"
                conflictsItem.isHidden = false
            } else {
                conflictsItem.title = "Show Conflicts"
                conflictsItem.isHidden = true
            }

            openFolderItem.title = "Open \(URL(fileURLWithPath: s.syncDir).lastPathComponent)"
        } else {
            statusItem.title = "Daemon not running"
            pullItem.title = "Last pull: —"
            pushItem.title = "Last push: —"
            pauseItem.title = "Pause"
            conflictsItem.isHidden = true
            openFolderItem.title = "Open Sync Folder"
        }
    }

    private func humanState(_ s: StatusSnapshot) -> String {
        switch s.state {
        case "idle":
            return "Synced (\(s.trackedDocs) docs)"
        case "syncing":
            return "Syncing… (\(s.queueDepth) in queue)"
        case "paused":
            return "Paused"
        case "error":
            return "Error" + (s.lastError.map { ": \($0)" } ?? "")
        case "stopped":
            return "Daemon stopped"
        default:
            return "State: \(s.state)"
        }
    }

    private func shortTime(_ iso: String?) -> String {
        guard let iso else { return "—" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        guard let date else { return iso }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .short
        return rel.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - actions

    @objc private func openSyncFolder(_ sender: Any) {
        guard let path = snapshot?.syncDir, !path.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func openConflicts(_ sender: Any) {
        guard let path = snapshot?.syncDir, !path.isEmpty else { return }
        // Open the sync dir; user can filter by the ".conflict" extension.
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func togglePause(_ sender: Any) {
        let isPaused = snapshot?.state == "paused"
        ipc.setPaused(!isPaused)
    }

    @objc private func syncNow(_ sender: Any) {
        ipc.syncNow()
    }

    @objc private func restartDaemon(_ sender: Any) {
        ipc.restartDaemon()
    }

    @objc private func openLogs(_ sender: Any) {
        let log = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/rmsync/stdout.log")
        if FileManager.default.fileExists(atPath: log.path) {
            NSWorkspace.shared.open(log)
        }
    }

    @objc private func openConfig(_ sender: Any) {
        let cfg = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/rmsync/config.toml")
        if FileManager.default.fileExists(atPath: cfg.path) {
            NSWorkspace.shared.open(cfg)
        }
    }

    @objc private func quit(_ sender: Any) {
        NSApplication.shared.terminate(sender)
    }
}
