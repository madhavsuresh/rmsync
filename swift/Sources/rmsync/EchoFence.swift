import Foundation

/// Drops watchdog events that we caused ourselves by writing to disk.
///
/// When the worker writes a local file in response to a pull, FSEvents
/// fires a modify notification. Without this fence the watcher would
/// queue a push for that write, round-trip back to the cloud, and
/// trigger another pull — classic echo loop. ``mark`` is called right
/// after an atomic write; ``isRecent`` is checked before enqueuing any
/// push job.
///
/// Port of ``src/rm_sync/echo_fence.py``. The belt-and-braces fallback
/// (hash equality check at push time) lives in the worker — the fence
/// is an optimization, not a correctness guarantee.
actor EchoFence {
    private var stamps: [String: Date] = [:]
    private let window: TimeInterval

    init(windowSeconds: TimeInterval = 5.0) {
        self.window = windowSeconds
    }

    func mark(_ path: String) {
        stamps[path] = Date()
        gc()
    }

    func isRecent(_ path: String) -> Bool {
        guard let stamp = stamps[path] else { return false }
        return Date().timeIntervalSince(stamp) <= window
    }

    private func gc() {
        let cutoff = Date().addingTimeInterval(-window)
        stamps = stamps.filter { $0.value >= cutoff }
    }
}
