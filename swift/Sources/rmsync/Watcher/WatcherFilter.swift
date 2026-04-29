import Foundation

/// What kind of root the watcher is watching. Selects the filename
/// filter and the job kind emitted for matching events.
///
/// Both modes use the same underlying event source — FSEventStream
/// on macOS via ``LocalWatcher``, inotify on Linux via
/// ``INotifyWatcher``. Mode just changes which paths are eligible
/// and which ``Job`` gets enqueued downstream.
enum WatcherMode: Sendable, Equatable {
    /// The main sync_dir: matches ``.md`` files only, ignores
    /// dotfiles / temp / conflict / hidden subdirs. Emits
    /// ``Job(kind: .push)`` on change and ``Job(kind: .deleteLocal)``
    /// on delete.
    case markdown

    /// The optional inbox drop folder: matches ``.pdf`` and
    /// ``.epub`` only, ignores everything else. Emits
    /// ``Job(kind: .pushInbox)`` on change. Doesn't react to
    /// deletes (the worker deletes the file itself after a
    /// successful push, and we don't want to chase that with a
    /// remote delete). Skips the echo fence (no self-write
    /// feedback loop possible — inbox is one-way).
    case inbox
}

/// Filename / path-component filter shared by every watcher
/// implementation (FSEventStream-based ``LocalWatcher`` on macOS,
/// inotify-based ``INotifyWatcher`` on Linux).
///
/// Pure Foundation; safe to call from any thread; no platform-
/// specific imports.
enum WatcherFilter {
    static func shouldIgnore(_ path: String, root: URL, mode: WatcherMode = .markdown) -> Bool {
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

        // Mode-specific extension filter.
        switch mode {
        case .markdown:
            // We only care about .md.
            if url.pathExtension != "md" { return true }
        case .inbox:
            // Only PDF / EPUB are valid drops.
            let ext = url.pathExtension.lowercased()
            if ext != "pdf" && ext != "epub" { return true }
        }
        return false
    }
}
