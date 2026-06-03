import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menuController: MenuController!
    private var ipc: IPCClient!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        ipc = IPCClient { [weak self] snapshot in
            DispatchQueue.main.async {
                self?.menuController.apply(snapshot: snapshot)
                self?.applyStatusIcon(for: snapshot)
            }
        }

        menuController = MenuController(ipc: ipc)
        statusItem.menu = menuController.menu

        // Paint a placeholder icon immediately so the bar isn't blank until
        // the first IPC frame arrives.
        applyStatusIcon(for: nil)

        ipc.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ipc.stop()
    }

    // MARK: - icon painting

    /// Pick the SF Symbol + text decorator for each state.
    ///
    /// Manual mode is not an error, so it gets a calm hand icon. Auto-push
    /// gets upload/activity symbols, and incoming cloud work gets a download
    /// symbol that points the user toward an explicit pull.
    private func applyStatusIcon(for snapshot: StatusSnapshot?) {
        guard let button = statusItem.button else { return }
        let state = snapshot?.state ?? "unknown"
        let hasConflicts = (snapshot?.conflicts ?? 0) > 0
        // v0.2.23: parked errors (push_failed, parse_failed,
        // bulk_delete_refused) need to be loud in the menubar.
        // Previously the icon stayed green-checkmark even when
        // every push of a particular doc was failing — silent
        // breakage. Treat ≥1 parked error like a conflict for
        // icon purposes (⚠), distinct from a daemon-down ✗.
        let hasErrors = (snapshot?.errors ?? 0) > 0

        let symbolName: String
        var decorator = ""

        let autoPushEnabled = snapshot?.autoPushEnabled ?? false
        let autoPushActive = (snapshot?.autoPushQueued ?? 0)
            + (snapshot?.autoPushUploading ?? 0)
            + (snapshot?.queueDepth ?? 0) > 0
        let autoPushAttention = (snapshot?.autoPushFailed ?? 0) > 0
            || (snapshot?.autoPushRefused ?? 0) > 0
        let pullAvailable = (snapshot?.pullState == "available")
            && (snapshot?.pullChanges ?? 0) > 0

        if snapshot == nil || state == "stopped" {
            symbolName = "tablet.and.pencil"
            decorator = " ✗"
        } else if state == "error" {
            symbolName = "tablet.and.pencil"
            decorator = " ✗"
        } else if state == "paused" {
            symbolName = "tablet.and.pencil"
            decorator = " ⏸"
        } else if hasConflicts || hasErrors || autoPushAttention {
            symbolName = "tablet.and.pencil"
            decorator = " ⚠"
        } else if pullAvailable {
            symbolName = "tray.and.arrow.down"
            decorator = ""
        } else if autoPushEnabled && autoPushActive {
            symbolName = "arrow.up.circle"
            decorator = ""
        } else if autoPushEnabled {
            symbolName = "arrow.up.circle"
            decorator = ""
        } else {
            symbolName = "hand.raised"
            decorator = ""
        }

        if let image = NSImage(systemSymbolName: symbolName,
                               accessibilityDescription: accessibilityDescription(
                                snapshot: snapshot,
                                fallbackState: state
                               )) {
            image.isTemplate = true
            button.image = image
        } else {
            button.image = nil
            button.title = symbolName
        }
        button.title = decorator
    }

    private func accessibilityDescription(
        snapshot: StatusSnapshot?,
        fallbackState: String
    ) -> String {
        guard let snapshot else { return "rmsync: daemon not running" }
        if snapshot.pullState == "available", snapshot.pullChanges > 0 {
            return "rmsync: pull available"
        }
        if snapshot.autoPushEnabled {
            return "rmsync: auto-push \(fallbackState)"
        }
        return "rmsync: manual sync mode"
    }
}
