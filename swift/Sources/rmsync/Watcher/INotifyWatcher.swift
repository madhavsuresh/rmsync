// Linux inotify-backed watcher. Linux-only counterpart to
// ``LocalWatcher`` (FSEventStream-based on macOS). Mirrors the same
// public surface: ``init(syncDir:queue:fence:debounceSeconds:)``,
// ``start()``, ``stop()`` — DaemonScaffold picks one with ``#if``.
//
// inotify subtlety vs FSEventStream: FSEventStream watches a tree
// recursively from a single subscription. inotify only watches one
// directory per subscription — recursion is the watcher's job. We
// add a watch on every existing subdirectory at start-up; on every
// ``IN_CREATE`` for a directory, we add a new watch and walk its
// (possibly already-populated) subtree to pick up files created
// during the brief gap between mkdir and our add_watch call.
//
// Rename detection: ``IN_MOVED_FROM`` and ``IN_MOVED_TO`` events
// share a ``cookie`` field. We hold ``MOVED_FROM`` events for a
// short grace window; if a matching ``MOVED_TO`` arrives we emit a
// rename, otherwise we treat the unmatched half as a delete or
// create after the window expires.

#if os(Linux)
import Foundation
import Dispatch
import Glibc

final class INotifyWatcher: @unchecked Sendable {
    private let syncDir: URL
    private let queue: JobQueue
    private let fence: EchoFence
    private let debounceSeconds: TimeInterval
    private let mode: WatcherMode

    private var inotify: INotify?

    /// watch descriptor → directory URL it represents. Maintained
    /// in lockstep with ``inotify_add_watch`` / ``inotify_rm_watch``;
    /// every event's ``wd`` indexes into this map to recover the
    /// full path (event.name is just the basename).
    private var wdToURL: [Int32: URL] = [:]

    /// Pending ``MOVED_FROM`` events keyed by cookie. Within
    /// ``renameGraceSeconds`` we expect a paired ``MOVED_TO``.
    private struct PendingMove: Sendable {
        let path: String
        let timestamp: Date
    }
    private var pendingMoves: [UInt32: PendingMove] = [:]
    private let renameGraceSeconds: TimeInterval = 0.5

    private var debounceTimers: [String: DispatchSourceTimer] = [:]

    private let workerQueue: DispatchQueue
    private let timerQueue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var stopped = false

    init(
        syncDir: URL,
        queue: JobQueue,
        fence: EchoFence,
        debounceSeconds: TimeInterval,
        mode: WatcherMode = .markdown
    ) {
        self.syncDir = syncDir
        self.queue = queue
        self.fence = fence
        self.debounceSeconds = debounceSeconds
        self.mode = mode
        // Per-mode dispatch queue labels — see LocalWatcher for the
        // same rationale. Avoids label collision when both .markdown
        // and .inbox watchers run concurrently.
        let suffix = mode == .markdown ? "md" : "inbox"
        self.workerQueue = DispatchQueue(label: "com.user.rmsync.watcher.inotify.\(suffix)")
        self.timerQueue = DispatchQueue(label: "com.user.rmsync.watcher.debounce.\(suffix)")
    }

    // MARK: - lifecycle

    func start() {
        do {
            let n = try INotify()
            self.inotify = n

            // Walk syncDir, add a watch on every directory.
            walkAndWatch(rootURL: syncDir, inotify: n)

            // Drain inotify-fd reads via DispatchSourceRead — same
            // pattern IPCServer uses for its accept-fd. The handler
            // runs on workerQueue (serial), so wd map mutations don't
            // need locking.
            let src = DispatchSource.makeReadSource(fileDescriptor: n.fd, queue: workerQueue)
            src.setEventHandler { [weak self] in
                self?.drainEvents()
            }
            self.readSource = src
            src.resume()

            Logger.shared.info(
                "watcher started",
                meta: [
                    "sync_dir": syncDir.path,
                    "watches": "\(wdToURL.count)",
                    "backend": "inotify",
                ]
            )
            warnIfWatchesNearLimit()
        } catch {
            Logger.shared.error(
                "INotify start failed",
                meta: ["error": "\(error)", "sync_dir": syncDir.path]
            )
        }
    }

    func stop() {
        stopped = true
        if let src = readSource {
            src.cancel()
            readSource = nil
        }
        // The INotify deinit closes the fd, which the kernel uses
        // to drop all watches; explicit removeWatch calls aren't
        // required. Drop the dictionary so a re-start doesn't see
        // stale entries.
        wdToURL.removeAll()
        inotify = nil
        timerQueue.async { [weak self] in
            guard let self else { return }
            for (_, timer) in self.debounceTimers { timer.cancel() }
            self.debounceTimers.removeAll()
        }
        Logger.shared.info("watcher stopped")
    }

    // MARK: - recursive watch setup

    private func walkAndWatch(rootURL: URL, inotify: INotify) {
        // The root itself plus every subdirectory.
        addWatch(at: rootURL, inotify: inotify)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return }
        for case let url as URL in enumerator {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                addWatch(at: url, inotify: inotify)
            }
        }
    }

    private func addWatch(at url: URL, inotify: INotify) {
        do {
            let wd = try inotify.addWatch(path: url.path)
            wdToURL[wd] = url
        } catch {
            Logger.shared.warn(
                "inotify_add_watch failed",
                meta: ["path": url.path, "error": "\(error)"]
            )
        }
    }

    /// Best-effort warning if the watcher is using a sizable fraction
    /// of the kernel's per-user limit. Doesn't fail the start; the
    /// user might have already raised the sysctl.
    private func warnIfWatchesNearLimit() {
        if wdToURL.count >= INotify.recommendedMaxWatches / 2 {
            Logger.shared.warn(
                "inotify watch count near kernel default",
                meta: [
                    "watches": "\(wdToURL.count)",
                    "default_limit": "\(INotify.recommendedMaxWatches)",
                    "fix": "raise fs.inotify.max_user_watches on the host",
                ]
            )
        }
    }

    // MARK: - event draining

    private func drainEvents() {
        guard let inotify, !stopped else { return }
        let events: [InotifyEvent]
        do {
            events = try inotify.readEvents()
        } catch {
            Logger.shared.error("inotify read failed", meta: ["error": "\(error)"])
            return
        }
        if events.isEmpty { return }

        // Drop any pending moves that timed out before we processed
        // a paired MOVED_TO. Their MOVED_FROM half becomes a delete.
        flushExpiredMoves()

        for event in events {
            handle(event)
        }
    }

    private func handle(_ event: InotifyEvent) {
        if (event.mask & InotifyMask.qOverflow) != 0 {
            Logger.shared.warn("inotify queue overflow; rescanning")
            rescan()
            return
        }
        guard let dir = wdToURL[event.wd] else {
            // Watch was removed (e.g. parent dir deleted); ignore.
            return
        }

        // Self-events: the watched directory was deleted or moved.
        // Drop the wd so future events don't reach this branch again.
        if (event.mask & (InotifyMask.deleteSelf | InotifyMask.moveSelf)) != 0 {
            wdToURL.removeValue(forKey: event.wd)
            return
        }

        // Build the full path for this event.
        let url = event.name.isEmpty ? dir : dir.appendingPathComponent(event.name)
        let isDir = (event.mask & InotifyMask.isDir) != 0

        // Rename pair handling.
        if (event.mask & InotifyMask.movedFrom) != 0 {
            pendingMoves[event.cookie] = PendingMove(
                path: url.path, timestamp: Date()
            )
            return
        }
        if (event.mask & InotifyMask.movedTo) != 0 {
            if let from = pendingMoves.removeValue(forKey: event.cookie) {
                // In .markdown mode, rename pairs whose endpoints
                // BOTH pass the watcher filter become a single
                // ``.renameRemote`` job. The worker handles
                // delete-vs-rename gating; the watcher just
                // surfaces the structural fact "these two paths
                // are the same file before/after". Endpoints that
                // fail the filter (one side outside the tree, etc.)
                // fall back to the historical delete+create
                // decomposition.
                if mode == .markdown,
                   !isDir,
                   !WatcherFilter.shouldIgnore(from.path, root: syncDir, mode: mode),
                   !WatcherFilter.shouldIgnore(url.path, root: syncDir, mode: mode) {
                    Task {
                        await queue.enqueue(Job(
                            kind: .renameRemote,
                            docID: nil,
                            hint: RenameHint.encode(from: from.path, to: url.path)
                        ))
                    }
                    return
                }

                // Fallback: treat as delete @ from-path,
                // create/modify @ to-path. Same as before for
                // dir renames or filtered-out endpoints.
                handleDelete(path: from.path)
                if isDir, let inotify {
                    walkAndWatch(rootURL: url, inotify: inotify)
                }
                handleChange(path: url.path)
            } else {
                // Move into the tree from outside our scope; treat as create.
                if isDir, let inotify {
                    walkAndWatch(rootURL: url, inotify: inotify)
                }
                handleChange(path: url.path)
            }
            return
        }

        if (event.mask & InotifyMask.create) != 0 {
            // New directory: pick up everything inside it. inotify
            // doesn't deliver events for files that existed before
            // the add_watch call, so a file written into the new
            // directory before our walk completes would be missed
            // without the rescan.
            if isDir, let inotify {
                walkAndWatch(rootURL: url, inotify: inotify)
                rescanFiles(under: url)
            } else {
                handleChange(path: url.path)
            }
            return
        }
        if (event.mask & InotifyMask.modify) != 0 {
            handleChange(path: url.path)
            return
        }
        if (event.mask & InotifyMask.delete) != 0 {
            handleDelete(path: url.path)
            return
        }
    }

    private func flushExpiredMoves() {
        let cutoff = Date().addingTimeInterval(-renameGraceSeconds)
        let expired = pendingMoves.filter { $0.value.timestamp < cutoff }
        for (cookie, move) in expired {
            pendingMoves.removeValue(forKey: cookie)
            // Unmatched MOVED_FROM = the file moved out of the tree
            // (or into a subtree we don't watch). Treat as delete.
            handleDelete(path: move.path)
        }
    }

    private func rescan() {
        // Full rescan after IN_Q_OVERFLOW. Drop every watch and
        // rebuild from the syncDir root; emit synthetic change events
        // for every file the watcher should care about so the worker
        // can re-hash and decide what's actually changed.
        guard let inotify else { return }
        for (wd, _) in wdToURL {
            inotify.removeWatch(wd: wd)
        }
        wdToURL.removeAll()
        walkAndWatch(rootURL: syncDir, inotify: inotify)
        rescanFiles(under: syncDir)
    }

    /// Synthesize change events for every file under ``url``. Used
    /// after directory creation (to cover files written before our
    /// add_watch landed) and after queue overflow (to recover state).
    private func rescanFiles(under url: URL) {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return }
        for case let fileURL as URL in enumerator {
            let isReg = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            if isReg { handleChange(path: fileURL.path) }
        }
    }

    // MARK: - dispatch (mirrors LocalWatcher's debounce/echo path)

    private func handleChange(path: String) {
        if WatcherFilter.shouldIgnore(path, root: syncDir, mode: mode) { return }
        Task {
            // Echo-fence applies only to .markdown mode. Inbox is
            // one-way (push-only); no risk of observing self-writes.
            if mode == .markdown, await fence.isRecent(path) {
                Logger.shared.debug("echo-suppressed", meta: ["path": path])
                return
            }
            scheduleDebounced(path: path)
        }
    }

    private func handleDelete(path: String) {
        // Inbox mode never reacts to deletes — the worker deletes
        // files itself after a successful push.
        guard mode == .markdown else { return }
        if WatcherFilter.shouldIgnore(path, root: syncDir, mode: mode) { return }
        Task {
            await queue.enqueue(Job(kind: .deleteLocal, docID: nil, hint: path))
        }
    }

    private func scheduleDebounced(path: String) {
        timerQueue.async { [weak self] in
            guard let self else { return }
            if let existing = self.debounceTimers.removeValue(forKey: path) {
                existing.cancel()
            }
            let timer = DispatchSource.makeTimerSource(queue: self.timerQueue)
            timer.schedule(deadline: .now() + self.debounceSeconds)
            timer.setEventHandler { [weak self] in
                self?.fire(path: path)
            }
            self.debounceTimers[path] = timer
            timer.resume()
        }
    }

    private func fire(path: String) {
        debounceTimers.removeValue(forKey: path)
        let kind: Job.Kind = mode == .markdown ? .push : .pushInbox
        Task {
            await queue.enqueue(Job(kind: kind, docID: nil, hint: path))
        }
    }
}

#endif
