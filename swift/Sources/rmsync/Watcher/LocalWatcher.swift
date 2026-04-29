// FSEventStream is macOS-only. Linux uses INotifyWatcher (Phase 1)
// instead — DaemonScaffold picks the right one with #if. The file
// is wrapped wholesale; on Linux the entire LocalWatcher type is
// absent and INotifyWatcher takes its place.
#if os(macOS)
import CoreServices
import Foundation

/// FSEventStream-backed local watcher.
///
/// Port of ``src/rm_sync/watcher.py``. watchdog-on-macOS also uses
/// FSEventStream under the hood, so we get the same event model: fire on
/// create/modify/delete/rename, coalesce into flags, fs_flags tells us
/// what changed. The one practical difference is that FSEventStream
/// callbacks hit a CFRunLoop, so we bridge onto an actor-safe
/// ``AsyncStream`` for the daemon side.
///
/// Echo fence: every event is checked against the ``EchoFence``. Events
/// for our own writes (within ~5s of a fence mark) are dropped. Without
/// the fence the pull path would observe its own atomic_write and push
/// it straight back up, creating a loop.
///
/// Debouncing: editors like VS Code and Obsidian fire 3-5 modify events
/// per save. Per-path 2s timer collapses the burst into one push event.
final class LocalWatcher: @unchecked Sendable {
    private let syncDir: URL
    private let queue: JobQueue
    private let fence: EchoFence
    private let debounceSeconds: TimeInterval
    private let mode: WatcherMode

    private var stream: FSEventStreamRef?
    private let eventQueue: DispatchQueue
    private var debounceTimers: [String: DispatchSourceTimer] = [:]
    private let timerQueue: DispatchQueue

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
        // Per-mode dispatch queue labels make it easy to tell the
        // two watchers apart in Instruments / ``ps``. The previous
        // hardcoded label was fine when there was only one watcher;
        // with both .markdown and .inbox running concurrently the
        // labels collide.
        let suffix = mode == .markdown ? "md" : "inbox"
        self.eventQueue = DispatchQueue(label: "com.user.rmsync.watcher.events.\(suffix)")
        self.timerQueue = DispatchQueue(label: "com.user.rmsync.watcher.debounce.\(suffix)")
    }

    // MARK: - lifecycle

    func start() {
        let pathsToWatch = [syncDir.path] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        // FileEvents fires on individual file create/modify/delete. NoDefer
        // kicks the first event through immediately instead of coalescing
        // with whatever landed 100ms before we started. (Not using
        // ``UseCFTypes`` — the C-style pointer-to-c-strings path is the
        // idiomatic FSEventStream usage.)
        let flags: FSEventStreamCreateFlags = UInt32(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, paths, flags, _ in
                guard let info else { return }
                let me = Unmanaged<LocalWatcher>.fromOpaque(info).takeUnretainedValue()
                let cPaths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
                var stringPaths: [String] = []
                stringPaths.reserveCapacity(count)
                for i in 0..<count {
                    stringPaths.append(String(cString: cPaths[i]))
                }
                let buf = UnsafeBufferPointer(start: flags, count: count)
                me.receive(paths: stringPaths, flags: Array(buf))
            },
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            /* latency */ 0.1,
            flags
        ) else {
            Logger.shared.error(
                "FSEventStreamCreate failed",
                meta: ["path": syncDir.path]
            )
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, eventQueue)
        FSEventStreamStart(stream)
        Logger.shared.info("watcher started", meta: ["sync_dir": syncDir.path])
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        timerQueue.async { [weak self] in
            guard let self else { return }
            for (_, timer) in self.debounceTimers { timer.cancel() }
            self.debounceTimers.removeAll()
        }
        Logger.shared.info("watcher stopped")
    }

    // MARK: - event handling

    private func receive(paths: [String], flags: [FSEventStreamEventFlags]) {
        for (path, raw) in zip(paths, flags) {
            Logger.shared.debug(
                "fs event",
                meta: ["path": path, "flags": String(raw, radix: 16)]
            )
            let flag = LocalWatcher.Flag(rawValue: raw)
            if flag.contains(.itemRemoved) {
                handleDelete(path: path)
            } else if flag.contains(.itemCreated)
                || flag.contains(.itemModified)
                || flag.contains(.itemRenamed) {
                handleChange(path: path)
            }
        }
    }

    private func handleChange(path: String) {
        if WatcherFilter.shouldIgnore(path, root: syncDir, mode: mode) { return }
        Task {
            // Echo-fence applies only to .markdown mode. The inbox
            // is one-way (push-only), so there's no risk of the
            // watcher observing its own writes — and skipping the
            // fence avoids dropping legitimate inbox drops if a user
            // happens to re-drop a file we just removed.
            if mode == .markdown, await fence.isRecent(path) {
                Logger.shared.debug("echo-suppressed", meta: ["path": path])
                return
            }
            scheduleDebounced(path: path)
        }
    }

    private func handleDelete(path: String) {
        // Inbox mode never reacts to deletes — the worker deletes
        // files itself after a successful push, and we don't want
        // to chase those self-deletes with a remote-delete job.
        guard mode == .markdown else { return }
        if WatcherFilter.shouldIgnore(path, root: syncDir, mode: mode) { return }
        // Delete-local is intentionally a noisy signal; see
        // worker.py:_note_local_gone in the Python tree. We let the
        // worker decide what to do with it on v0.1 (currently just logs).
        Task {
            await queue.enqueue(Job(kind: .deleteLocal, docID: nil, hint: path))
        }
    }

    private func scheduleDebounced(path: String) {
        // Dispatch onto ``timerQueue`` asynchronously. We cannot call
        // ``timerQueue.sync`` from a block that might itself run on
        // ``timerQueue`` (the timer event handler runs there, and
        // re-entering sync would deadlock).
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
        // Already on ``timerQueue``; drop the timer without resyncing.
        debounceTimers.removeValue(forKey: path)
        // Mode picks the job kind: regular markdown push vs. inbox
        // PDF/EPUB push. The downstream SyncWorker dispatches each
        // kind to its own handler.
        let kind: Job.Kind = mode == .markdown ? .push : .pushInbox
        Task {
            await queue.enqueue(Job(kind: kind, docID: nil, hint: path))
        }
    }

    // MARK: - filtering

    /// Forwards to ``WatcherFilter.shouldIgnore``. Kept on
    /// ``LocalWatcher`` for backwards-compatible call sites
    /// (tests, Doctor, etc.) but the real logic lives in
    /// ``WatcherFilter`` so the Linux INotifyWatcher can share it
    /// without depending on this macOS-only type.
    static func shouldIgnore(_ path: String, syncDir: URL) -> Bool {
        WatcherFilter.shouldIgnore(path, root: syncDir, mode: .markdown)
    }

    private struct Flag: OptionSet {
        let rawValue: FSEventStreamEventFlags
        static let itemCreated  = Flag(rawValue: UInt32(kFSEventStreamEventFlagItemCreated))
        static let itemRemoved  = Flag(rawValue: UInt32(kFSEventStreamEventFlagItemRemoved))
        static let itemRenamed  = Flag(rawValue: UInt32(kFSEventStreamEventFlagItemRenamed))
        static let itemModified = Flag(rawValue: UInt32(kFSEventStreamEventFlagItemModified))
    }
}

#endif
