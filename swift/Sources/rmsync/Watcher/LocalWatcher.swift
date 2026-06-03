#if os(macOS)
import CoreServices
import Foundation

/// FSEventStream-backed watcher for opt-in safe auto-push.
///
/// It only emits changed Markdown paths. Deletes, renames, directory events,
/// and raw file drops are intentionally ignored because background sync
/// mutation is no longer part of the daemon architecture.
final class LocalWatcher: @unchecked Sendable {
    private let syncDir: URL
    private let queue: AutoPushEventQueue
    private let fence: EchoFence
    private let debounceSeconds: TimeInterval

    private var stream: FSEventStreamRef?
    private let eventQueue = DispatchQueue(label: "com.user.rmsync.watcher.events.md")
    private let timerQueue = DispatchQueue(label: "com.user.rmsync.watcher.debounce.md")
    private var debounceTimers: [String: DispatchSourceTimer] = [:]

    init(
        syncDir: URL,
        queue: AutoPushEventQueue,
        fence: EchoFence,
        debounceSeconds: TimeInterval
    ) {
        self.syncDir = syncDir
        self.queue = queue
        self.fence = fence
        self.debounceSeconds = debounceSeconds
    }

    func start() {
        let pathsToWatch = [syncDir.path] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
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
            0.1,
            flags
        ) else {
            Logger.shared.error("FSEventStreamCreate failed", meta: ["path": syncDir.path])
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, eventQueue)
        FSEventStreamStart(stream)
        Logger.shared.info("auto-push watcher started", meta: ["sync_dir": syncDir.path])
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
        Logger.shared.info("auto-push watcher stopped")
    }

    private func receive(paths: [String], flags: [FSEventStreamEventFlags]) {
        for (path, raw) in zip(paths, flags) {
            let flag = Flag(rawValue: raw)
            guard flag.contains(.itemCreated) || flag.contains(.itemModified) || flag.contains(.itemRenamed) else {
                continue
            }
            handleChange(path: path)
        }
    }

    private func handleChange(path: String) {
        if WatcherFilter.shouldIgnore(path, root: syncDir) { return }
        Task {
            if await fence.isRecent(path) {
                Logger.shared.debug("echo-suppressed", meta: ["path": path])
                return
            }
            scheduleDebounced(path: path)
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
        Task {
            await queue.enqueue(path)
        }
    }

    static func shouldIgnore(_ path: String, syncDir: URL) -> Bool {
        WatcherFilter.shouldIgnore(path, root: syncDir)
    }

    private struct Flag: OptionSet {
        let rawValue: FSEventStreamEventFlags
        static let itemCreated  = Flag(rawValue: UInt32(kFSEventStreamEventFlagItemCreated))
        static let itemRenamed  = Flag(rawValue: UInt32(kFSEventStreamEventFlagItemRenamed))
        static let itemModified = Flag(rawValue: UInt32(kFSEventStreamEventFlagItemModified))
    }
}

#endif
