// Entry point. Lives outside AppDelegate so we can use `@main` there —
// except @main on an AppDelegate in an executable target fights with
// Swift's inferred @main rules on Package executables. Easier to just
// construct NSApplication + a plain AppDelegate here.
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menu-bar app, no Dock icon, no menu bar at top — we're a status item.
app.setActivationPolicy(.accessory)
app.run()
