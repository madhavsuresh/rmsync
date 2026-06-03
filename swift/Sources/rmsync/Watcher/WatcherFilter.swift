import Foundation

/// Filename / path-component filter shared by every watcher
/// implementation (FSEventStream-based ``LocalWatcher`` on macOS,
/// inotify-based ``INotifyWatcher`` on Linux).
///
/// Pure Foundation; safe to call from any thread; no platform-
/// specific imports.
enum WatcherFilter {
    static func shouldIgnore(_ path: String, root: URL) -> Bool {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        if name == ".DS_Store" { return true }
        if name.hasPrefix(".") { return true }
        if url.pathExtension == "tmp" { return true }
        if url.pathExtension == "conflict" { return true }
        guard let rel = PathUtilities.resolvedRelativePath(from: root, to: url)
        else { return true }

        // Dropbox / iCloud / OneDrive conflict copies.
        let conflictCopy = /(?i)\bconflicted copy\b/
        if name.contains(conflictCopy) { return true }

        // Anything under .rmsync-trash / .git / .obsidian / hidden dirs.
        for part in rel {
            if ["\\.rmsync-trash", ".rmsync-trash", ".git", ".obsidian"].contains(part) {
                return true
            }
            if part.hasPrefix(".") { return true }
        }

        if url.pathExtension != "md" { return true }
        return false
    }
}
