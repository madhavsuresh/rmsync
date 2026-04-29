import Foundation

/// Filename / path-component filter shared by every watcher
/// implementation (FSEventStream-based ``LocalWatcher`` on macOS,
/// inotify-based ``INotifyWatcher`` on Linux).
///
/// Pulled from ``LocalWatcher.shouldIgnore`` so both watchers can
/// reach the same rules. Pure Foundation; safe to call from any
/// thread; no platform-specific imports.
///
/// Rules match the Python port byte-for-byte:
///
/// - Dotfiles, .tmp, .conflict suffixes — never push
/// - Paths outside the sync_dir (after symlink resolution) — never push
/// - Conflict copies from Dropbox / iCloud / OneDrive — never push
/// - Anything under hidden subdirs (``.rmsync-trash``, ``.git``,
///   ``.obsidian``, any other ``.*`` directory) — never push
/// - Only ``.md`` files trigger pushes; other extensions ignored
enum WatcherFilter {
    static func shouldIgnore(_ path: String, syncDir: URL) -> Bool {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        if name == ".DS_Store" { return true }
        if name.hasPrefix(".") { return true }
        if url.pathExtension == "tmp" { return true }
        if url.pathExtension == "conflict" { return true }
        guard let rel = PathUtilities.resolvedRelativePath(from: syncDir, to: url)
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

        // We only care about .md.
        if url.pathExtension != "md" { return true }
        return false
    }
}
