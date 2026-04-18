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
    /// Idle gets a clean checkmark — "everything's synced". Every other
    /// state keeps the tablet-and-pencil with a small decorator glyph so
    /// the user knows something is up without having to open the menu.
    private func applyStatusIcon(for snapshot: StatusSnapshot?) {
        guard let button = statusItem.button else { return }
        let state = snapshot?.state ?? "unknown"
        let hasConflicts = (snapshot?.conflicts ?? 0) > 0

        let symbolName: String
        var decorator = ""

        if snapshot == nil || state == "stopped" {
            symbolName = "tablet.and.pencil"
            decorator = " ✗"
        } else if state == "error" {
            symbolName = "tablet.and.pencil"
            decorator = " ✗"
        } else if state == "paused" {
            symbolName = "tablet.and.pencil"
            decorator = " ⏸"
        } else if hasConflicts {
            symbolName = "tablet.and.pencil"
            decorator = " ⚠"
        } else if state == "syncing" {
            symbolName = "tablet.and.pencil"
            decorator = " ⟳"
        } else {
            // idle + everything green
            symbolName = "checkmark"
            decorator = ""
        }

        if let image = NSImage(systemSymbolName: symbolName,
                               accessibilityDescription: "rmsync: \(state)") {
            image.isTemplate = true
            button.image = image
        } else {
            button.image = nil
            button.title = symbolName
        }
        button.title = decorator
    }
}
