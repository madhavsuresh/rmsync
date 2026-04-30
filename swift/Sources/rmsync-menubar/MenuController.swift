import AppKit

/// Owns the NSMenu and keeps its items in sync with the latest snapshot.
/// Everything dynamic (status line, conflict count, pause-vs-resume) is
/// held as separate NSMenuItems so we can mutate them in-place without
/// rebuilding the whole menu on each status change.
@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu()

    private let titleItem = NSMenuItem()
    private let versionItem = NSMenuItem()
    private let statusItem = NSMenuItem()
    private let pullItem = NSMenuItem()
    private let pushItem = NSMenuItem()
    private let openFolderItem = NSMenuItem()
    private let conflictsItem = NSMenuItem()
    /// "Why is sync broken?" — only shown when the daemon's
    /// cloud-health probe (v0.2.25) classifies a non-OK state.
    /// Keeps the menu uncluttered for healthy installs.
    private let whyBrokenItem = NSMenuItem()
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

        // Version line — shows this menubar binary's version always,
        // and appends the daemon's reported version if it differs. A
        // mismatch usually means ``brew upgrade`` ran but the daemon
        // hasn't been kicked yet. The post_install hook in the Formula
        // covers the normal path; this line is the visual canary when
        // the hook didn't fire (e.g. manual ``./install.sh`` dev
        // install, or a launchd race during upgrade).
        versionItem.title = "v\(Version.current)"
        versionItem.isEnabled = false
        menu.addItem(versionItem)

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

        // "Why is sync broken?" — hidden by default, shown when
        // the cloud-health probe surfaces a non-ok classification.
        // Click action varies by classification:
        //   rmapi_compat_break → opens ddvk/rmapi#58
        //   auth_broken        → shows a help dialog
        //   rmapi_missing      → opens rmapi releases page
        whyBrokenItem.title = "Why is sync broken?"
        whyBrokenItem.target = self
        whyBrokenItem.action = #selector(openWhyBroken(_:))
        whyBrokenItem.isHidden = true
        menu.addItem(whyBrokenItem)

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
            versionItem.title = versionLine(menubar: Version.current, daemon: s.daemonVersion)

            if s.conflicts > 0 {
                conflictsItem.title = "Show Conflicts (\(s.conflicts))"
                conflictsItem.isHidden = false
            } else {
                conflictsItem.title = "Show Conflicts"
                conflictsItem.isHidden = true
            }

            // "Why is sync broken?" — visible when the daemon's
            // cloud-health probe (v0.2.25+) flagged something
            // systemic. Title encodes the classification so the
            // user gets the gist without clicking.
            switch s.cloudHealth {
            case "rmapi_compat_break":
                whyBrokenItem.title = "Why is sync broken? (rmapi vs cloud)"
                whyBrokenItem.isHidden = false
            case "auth_broken":
                whyBrokenItem.title = "Why is sync broken? (rmapi auth)"
                whyBrokenItem.isHidden = false
            case "rmapi_missing":
                whyBrokenItem.title = "Why is sync broken? (rmapi missing)"
                whyBrokenItem.isHidden = false
            default:
                whyBrokenItem.isHidden = true
            }

            openFolderItem.title = "Open \(URL(fileURLWithPath: s.syncDir).lastPathComponent)"
        } else {
            statusItem.title = "Daemon not running"
            pullItem.title = "Last pull: —"
            pushItem.title = "Last push: —"
            pauseItem.title = "Pause"
            versionItem.title = "v\(Version.current)"
            conflictsItem.isHidden = true
            whyBrokenItem.isHidden = true
            openFolderItem.title = "Open Sync Folder"
        }
    }

    /// Render the version menu-item text. Keeps the common case
    /// (matching versions) terse, and makes the actionable mismatch
    /// case visible without extra menu items.
    private func versionLine(menubar: String, daemon: String) -> String {
        if daemon.isEmpty || daemon == menubar {
            return "v\(menubar)"
        }
        return "v\(menubar) · daemon v\(daemon) ⚠"
    }

    private func humanState(_ s: StatusSnapshot) -> String {
        // v0.2.25 — when the daemon's cloud-health probe diagnosed
        // a systemic issue (rmapi missing, auth broken, or the
        // schema-v4 cloud incompatibility), surface that ABOVE the
        // generic "parked errors" count. The user sees "rmapi can't
        // reach cloud" instead of "out of sync — 6 parked errors"
        // and knows to wait for an upstream fix rather than poke
        // at rmsync's code.
        switch s.cloudHealth {
        case "rmapi_compat_break":
            let plural = s.errors == 1 ? "" : "s"
            return "rmapi can't reach cloud — \(s.errors) file\(plural) parked safely"
        case "auth_broken":
            return "rmapi auth broken — run `rmapi` to re-authenticate"
        case "rmapi_missing":
            return "rmapi binary missing or won't run"
        default:
            break
        }
        // Parked errors / unresolved conflicts override the
        // top-level "synced" reading: a clean idle state with
        // even one push_failed parked is NOT actually clean.
        // Surface the count so the user can click into Status.
        if s.errors > 0 {
            let plural = s.errors == 1 ? "" : "s"
            return "Out of sync — \(s.errors) parked error\(plural)"
        }
        if s.conflicts > 0 {
            let plural = s.conflicts == 1 ? "" : "s"
            return "Conflicts — \(s.conflicts) doc\(plural) need attention"
        }
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
        // The Swift daemon writes structured logs to stderr (see
        // Logger.emit → FileHandle.standardError.write); launchd
        // routes that to ``stderr.log``. ``stdout.log`` is the
        // empty leftover from the Python predecessor — opening
        // it (the prior behavior) showed users a blank file.
        // v0.2.23 fixed the same bug in the CLI's `rmsync logs`;
        // v0.2.25 catches the menubar's matching call site.
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/rmsync")
        let stderrLog = logDir.appendingPathComponent("stderr.log")
        let stdoutLog = logDir.appendingPathComponent("stdout.log")
        let fm = FileManager.default
        let target: URL = {
            // Prefer stderr.log when it exists and is non-empty.
            if fm.fileExists(atPath: stderrLog.path),
               (try? Data(contentsOf: stderrLog))?.isEmpty == false {
                return stderrLog
            }
            // Fall back to stdout.log only if it has anything to
            // show (e.g., a hypothetical future stdout-writing
            // logger).
            if fm.fileExists(atPath: stdoutLog.path) { return stdoutLog }
            return stderrLog
        }()
        if FileManager.default.fileExists(atPath: target.path) {
            NSWorkspace.shared.open(target)
        }
    }

    /// Open the diagnostic page or show a help alert based on
    /// the current cloud-health classification. v0.2.25+.
    @objc private func openWhyBroken(_ sender: Any) {
        guard let s = snapshot else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        switch s.cloudHealth {
        case "rmapi_compat_break":
            alert.messageText = "rmapi can't reach the reMarkable cloud"
            alert.informativeText = (s.cloudHealthDetail ?? "")
                + "\n\nYour files are parked safely in state.db; "
                + "no data is lost. The daemon will resume pushing "
                + "automatically once rmapi or the cloud ships a "
                + "compatible build.\n\n"
                + "Track upstream: https://github.com/ddvk/rmapi/issues/58"
            alert.addButton(withTitle: "Open Issue")
            alert.addButton(withTitle: "Close")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string:
                    "https://github.com/ddvk/rmapi/issues/58")!)
            }
        case "auth_broken":
            alert.messageText = "rmapi authentication broken"
            alert.informativeText = (s.cloudHealthDetail ?? "")
                + "\n\nRun `rmapi` in a terminal and paste the "
                + "8-char code from "
                + "https://my.remarkable.com/device/desktop/connect"
            alert.addButton(withTitle: "Close")
            alert.runModal()
        case "rmapi_missing":
            alert.messageText = "rmapi binary missing"
            alert.informativeText = (s.cloudHealthDetail ?? "")
                + "\n\nInstall via: brew install madhavsuresh/rmsync/rmapi"
            alert.addButton(withTitle: "Close")
            alert.runModal()
        default:
            alert.messageText = "No diagnostic available"
            alert.informativeText = "Check `rmsync logs` for details."
            alert.addButton(withTitle: "Close")
            alert.runModal()
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
