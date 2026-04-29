// macOS uses osascript to drive Notification Center. Linux daemon
// runs in Docker without a desktop session; we route notifications
// through the structured log instead so users can `docker logs` them.
#if os(macOS)
import Foundation

/// User-Visible banner helpers. Port of
/// ``src/rm_sync/native/macos.py:notify`` / ``notify_conflict``.
///
/// Uses ``osascript`` rather than ``UserNotifications.framework`` — the
/// latter requires a registered bundle ID and explicit permission prompts
/// that an agent binary can't reasonably drive. The osascript path has
/// neither and still lands in Notification Center.
enum Notifications {
    static func notify(
        title: String,
        body: String,
        subtitle: String? = nil
    ) {
        var script = "display notification \(appleScriptQuote(body))"
        script += " with title \(appleScriptQuote(title))"
        if let subtitle {
            script += " subtitle \(appleScriptQuote(subtitle))"
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do { try task.run() } catch {
            Logger.shared.debug("notify failed", meta: ["error": "\(error)"])
            return
        }
        // Fire-and-forget; osascript returns quickly.
        task.waitUntilExit()
    }

    static func notifyConflict(docTitle: String, localPath: URL) {
        notify(
            title: "rmsync: conflict",
            body: "\(docTitle) changed on both sides. A .conflict file was written.",
            subtitle: localPath.deletingLastPathComponent().path
        )
    }

    /// Quote a Swift string for inlining into an AppleScript string literal.
    private static func appleScriptQuote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

#elseif os(Linux)

import Foundation

/// Linux stub: route notifications through the structured log so they
/// surface via ``docker logs`` / ``rmsync logs --diagnose``. Same call
/// surface as the macOS path so the SyncWorker is unaffected.
enum Notifications {
    static func notify(title: String, body: String, subtitle: String? = nil) {
        var meta: [String: String] = [
            "notify": "true",
            "title": title,
            "body": body,
        ]
        if let subtitle { meta["subtitle"] = subtitle }
        Logger.shared.info("notification", meta: meta)
    }

    static func notifyConflict(docTitle: String, localPath: URL) {
        notify(
            title: "rmsync: conflict",
            body: "\(docTitle) changed on both sides. A .conflict file was written.",
            subtitle: localPath.deletingLastPathComponent().path
        )
    }
}

#endif
