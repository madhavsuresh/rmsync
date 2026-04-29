import Foundation

/// Pairs the two halves of a rename event into a single
/// "(from, to)" tuple. Used by both watchers:
///
///   - **Linux / inotify**: ``IN_MOVED_FROM`` and ``IN_MOVED_TO``
///     events share a cookie. The cookie matching lives in the
///     watcher itself; this pairer plays the same role for the
///     macOS path which has no cookie.
///   - **macOS / FSEvents**: ``kFSEventStreamEventFlagItemRenamed``
///     fires twice — once on the source path (which no longer
///     exists by the time we observe it) and once on the
///     destination (which does). The pairer correlates the two
///     within a short grace window.
///
/// Why a separate type rather than inline state on the watcher?
/// Two reasons:
///
///   1. **Testability.** The watchers themselves are bound to
///      platform-specific event sources (FSEventStream / inotify
///      fds). Pulling the pair-up logic into a pure actor lets us
///      unit-test the matching without spinning up a real event
///      stream.
///
///   2. **Reaping unmatched halves.** If a "from" event arrives
///      and no matching "to" lands within ``windowSeconds``, we
///      need to fall back to a plain delete (the file *was*
///      removed, just without an obvious counterpart). The actor
///      owns this reaper; callers ask for ``flushExpired`` on a
///      timer.
actor RenamePairer {
    /// Per-path pending state. ``isFrom`` records whether we saw
    /// the source-side or destination-side first; the next call
    /// of the opposite kind matches it.
    private struct Pending {
        let path: String
        let observedAt: Date
        let isFrom: Bool
    }

    private var pendingFrom: [String: Date] = [:]
    private var pendingTo: [String: Date] = [:]
    private let windowSeconds: TimeInterval

    init(windowSeconds: TimeInterval = 0.2) {
        self.windowSeconds = windowSeconds
    }

    /// Observe the source side of a potential rename. If a
    /// matching destination has been seen within the window,
    /// returns the pair ``(from, to)``; the destination entry is
    /// consumed.
    ///
    /// Concretely: on FSEvents we know we're the "from" half
    /// because the file no longer exists at that path. The
    /// observer is responsible for that check before calling.
    func observeFrom(path: String, now: Date = Date()) -> (from: String, to: String)? {
        prune(now: now)
        // Did a "to" already arrive (e.g., FSEvents delivered the
        // destination event first)? Pair them up.
        if let toMatch = pendingTo.first(where: { _, ts in
            now.timeIntervalSince(ts) <= windowSeconds
        }) {
            pendingTo.removeValue(forKey: toMatch.key)
            return (from: path, to: toMatch.key)
        }
        pendingFrom[path] = now
        return nil
    }

    /// Symmetric to ``observeFrom`` for the destination side.
    /// Returns the pair if a matching source is pending.
    func observeTo(path: String, now: Date = Date()) -> (from: String, to: String)? {
        prune(now: now)
        if let fromMatch = pendingFrom.first(where: { _, ts in
            now.timeIntervalSince(ts) <= windowSeconds
        }) {
            pendingFrom.removeValue(forKey: fromMatch.key)
            return (from: fromMatch.key, to: path)
        }
        pendingTo[path] = now
        return nil
    }

    /// Reap any half-pair that timed out without a partner. The
    /// caller treats returned source-paths as a plain delete and
    /// destination-paths as a plain create.
    func flushExpired(now: Date = Date()) -> (orphanFroms: [String], orphanTos: [String]) {
        let cutoff = now.addingTimeInterval(-windowSeconds)
        let oldFroms = pendingFrom.filter { _, ts in ts < cutoff }.map(\.key)
        let oldTos = pendingTo.filter { _, ts in ts < cutoff }.map(\.key)
        for k in oldFroms { pendingFrom.removeValue(forKey: k) }
        for k in oldTos { pendingTo.removeValue(forKey: k) }
        return (orphanFroms: oldFroms, orphanTos: oldTos)
    }

    /// For tests / diagnostics.
    func pendingCount() -> (froms: Int, tos: Int) {
        (pendingFrom.count, pendingTo.count)
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-windowSeconds)
        pendingFrom = pendingFrom.filter { $0.value >= cutoff }
        pendingTo = pendingTo.filter { $0.value >= cutoff }
    }
}

/// Hint encoding for ``.renameRemote`` and ``.renameLocal`` jobs.
/// The Job struct only carries a single ``hint`` string, so we
/// pack ``(from, to)`` into one TAB-separated value. TAB is safe
/// because ``WatcherFilter.shouldIgnore`` rejects paths containing
/// control characters before they can reach a Job.
enum RenameHint {
    static let separator = "\t"

    static func encode(from: String, to: String) -> String {
        from + separator + to
    }

    static func decode(_ hint: String) -> (from: String, to: String)? {
        let parts = hint.split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return (from: String(parts[0]), to: String(parts[1]))
    }
}
