#if os(Linux)
import Dispatch
import Foundation
import Glibc

/// Linux inotify watcher for opt-in safe auto-push.
///
/// It mirrors the macOS watcher: only changed Markdown file paths are enqueued.
/// Deletes, directory changes, renames-as-operations, and raw file drops are not
/// part of the current daemon model.
final class INotifyWatcher: @unchecked Sendable {
    private let syncDir: URL
    private let queue: AutoPushEventQueue
    private let fence: EchoFence
    private let debounceSeconds: TimeInterval

    private var inotify: INotify?
    private var wdToURL: [Int32: URL] = [:]
    private var debounceTimers: [String: DispatchSourceTimer] = [:]
    private let workerQueue = DispatchQueue(label: "com.user.rmsync.watcher.inotify.md")
    private let timerQueue = DispatchQueue(label: "com.user.rmsync.watcher.debounce.md")
    private var readSource: DispatchSourceRead?
    private var stopped = false

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
        do {
            let n = try INotify()
            self.inotify = n
            walkAndWatch(rootURL: syncDir, inotify: n)

            let src = DispatchSource.makeReadSource(fileDescriptor: n.fd, queue: workerQueue)
            src.setEventHandler { [weak self] in
                self?.drainEvents()
            }
            self.readSource = src
            src.resume()

            Logger.shared.info(
                "auto-push watcher started",
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
        readSource?.cancel()
        readSource = nil
        wdToURL.removeAll()
        inotify = nil
        timerQueue.async { [weak self] in
            guard let self else { return }
            for (_, timer) in self.debounceTimers { timer.cancel() }
            self.debounceTimers.removeAll()
        }
        Logger.shared.info("auto-push watcher stopped")
    }

    private func walkAndWatch(rootURL: URL, inotify: INotify) {
        addWatch(at: rootURL, inotify: inotify)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return }
        for case let url as URL in enumerator {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { addWatch(at: url, inotify: inotify) }
        }
    }

    private func addWatch(at url: URL, inotify: INotify) {
        do {
            let wd = try inotify.addWatch(path: url.path)
            wdToURL[wd] = url
        } catch {
            Logger.shared.warn("inotify_add_watch failed", meta: ["path": url.path, "error": "\(error)"])
        }
    }

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

    private func drainEvents() {
        guard let inotify, !stopped else { return }
        let events: [InotifyEvent]
        do {
            events = try inotify.readEvents()
        } catch {
            Logger.shared.error("inotify read failed", meta: ["error": "\(error)"])
            return
        }

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
        guard let dir = wdToURL[event.wd] else { return }

        if (event.mask & (InotifyMask.deleteSelf | InotifyMask.moveSelf)) != 0 {
            wdToURL.removeValue(forKey: event.wd)
            return
        }

        let url = event.name.isEmpty ? dir : dir.appendingPathComponent(event.name)
        let isDir = (event.mask & InotifyMask.isDir) != 0

        if isDir {
            if (event.mask & (InotifyMask.create | InotifyMask.movedTo)) != 0,
               let inotify {
                walkAndWatch(rootURL: url, inotify: inotify)
                rescanFiles(under: url)
            }
            return
        }

        if (event.mask & (InotifyMask.create | InotifyMask.modify | InotifyMask.movedTo)) != 0 {
            handleChange(path: url.path)
        }
    }

    private func rescan() {
        guard let inotify else { return }
        for (wd, _) in wdToURL {
            inotify.removeWatch(wd: wd)
        }
        wdToURL.removeAll()
        walkAndWatch(rootURL: syncDir, inotify: inotify)
        rescanFiles(under: syncDir)
    }

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
}

#endif
