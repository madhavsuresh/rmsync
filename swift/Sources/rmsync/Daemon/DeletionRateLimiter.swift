import Foundation

/// Bulk-delete brake. Caps how many tracked-document deletions the
/// worker pool may apply within a rolling window before refusing.
///
/// The brake exists because every rename / delete propagation source
/// is fundamentally untrustworthy:
///
///   - **FSEvents / inotify storms** can deliver a flood of "deleted"
///     events for files that come back milliseconds later (editor
///     swap-file dance, finder copy-then-delete, partial mount
///     unmount).
///   - **Cloud-side polling** can briefly see an empty tree if rmapi
///     races a server-side reorg.
///   - **User accident** — a stray ``rm -rf`` inside the sync dir
///     would otherwise propagate to the cloud verbatim.
///
/// All three failure modes look identical at the worker: a burst of
/// confirmed-delete jobs in a short window. The brake refuses
/// further deletes once the burst exceeds
/// ``cfg.deletion.bulk_delete_threshold`` of currently-tracked docs
/// in ``cfg.deletion.bulk_delete_window_seconds``, surfacing the
/// state via ``error_state = "bulk_delete_refused"`` so the user
/// sees it in ``rmsync status`` and the dashboard.
///
/// A few load-bearing design notes:
///
///   - **Tracked-doc count is a proxy.** Threshold is ``deletes /
///     trackedDocs``, not absolute. A 200-doc tree and a 5-doc tree
///     hit the brake at proportionally appropriate sizes.
///   - **Per-doc serialised by docID.** The same docID can't double-
///     count even if two workers land jobs for it.
///   - **Wall-clock window.** The brake uses
///     ``Date().timeIntervalSince1970``. Daylight-savings transitions
///     could in theory inflate / deflate the window once a year by
///     an hour. The brake is conservative enough that a one-hour
///     drift is harmless.
///   - **Restart-resilient.** History lives only in memory. After a
///     daemon restart the limiter is empty — by design. A fresh
///     burst of pending deletes (because reconcile resumed them)
///     should *not* be refused: the work was already approved
///     before the crash. The marker that survives the restart is
///     ``pending_op``, not the rate-limiter state.
actor DeletionRateLimiter {
    private struct Entry {
        let docID: String
        let timestamp: TimeInterval
    }

    private var history: [Entry] = []
    private let threshold: Double
    private let windowSeconds: TimeInterval
    private let getTrackedDocCount: @Sendable () async -> Int

    /// ``getTrackedDocCount`` is injected so tests can run the brake
    /// against a synthetic universe without spinning up a State.
    init(
        threshold: Double,
        windowSeconds: TimeInterval,
        getTrackedDocCount: @escaping @Sendable () async -> Int
    ) {
        self.threshold = threshold
        self.windowSeconds = windowSeconds
        self.getTrackedDocCount = getTrackedDocCount
    }

    /// Convenience init for production: counts every row in
    /// ``state.allDocuments()``. The closure captures ``state`` by
    /// reference; the limiter's lifetime never outlives the daemon
    /// scaffold's, so the cycle is benign.
    init(cfg: Config, state: State) {
        self.threshold = cfg.deletion.bulkDeleteThreshold
        self.windowSeconds = TimeInterval(cfg.deletion.bulkDeleteWindowSeconds)
        self.getTrackedDocCount = { @Sendable in
            (try? await state.allDocuments().count) ?? 0
        }
    }

    /// Should the worker proceed with deleting ``docID``? Returns
    /// ``true`` iff applying this delete would *not* exceed the
    /// threshold; the call is idempotent — re-checking the same
    /// docID without recording it has no side effect.
    func mayDelete(docID: String, now: Date = Date()) async -> Bool {
        prune(before: now)
        let tracked = await getTrackedDocCount()
        // No tracked docs → nothing to compare against. Allow; the
        // very first delete after a restart can't be a "burst".
        guard tracked > 0 else { return true }

        // Same docID inside the window doesn't double-count. The
        // worker may legitimately retry the same delete on a
        // network blip — that mustn't bump the brake.
        let uniqueDocsInWindow = Set(history.map(\.docID) + [docID]).count
        let ratio = Double(uniqueDocsInWindow) / Double(tracked)
        return ratio <= threshold
    }

    /// Record that the worker did successfully delete ``docID`` at
    /// ``now``. Bumps the rolling-window history.
    func record(docID: String, now: Date = Date()) {
        prune(before: now)
        history.append(Entry(
            docID: docID, timestamp: now.timeIntervalSince1970
        ))
    }

    /// For tests + diagnostics: how many distinct doc deletions are
    /// currently recorded in the rolling window.
    func windowSize(now: Date = Date()) -> Int {
        prune(before: now)
        return Set(history.map(\.docID)).count
    }

    private func prune(before now: Date) {
        let cutoff = now.timeIntervalSince1970 - windowSeconds
        history.removeAll { $0.timestamp < cutoff }
    }
}
