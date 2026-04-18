import Foundation

/// Actor-backed FIFO queue for ``Job`` values. One producer/many
/// consumer semantics — any worker can dequeue, jobs go to whichever
/// worker is waiting first.
///
/// Uses a simple array + waiter list. The previous attempt used a
/// private ``AsyncStream.AsyncIterator`` but iterators aren't
/// ``Sendable`` under Swift 6 strict concurrency, and juggling them
/// through an actor triggered "risks causing data races" errors.
///
/// Semantics mirror ``asyncio.Queue``:
///   - ``enqueue`` bumps the outstanding counter.
///   - ``dequeue`` blocks until a job is available or the timeout fires.
///   - ``taskDone`` decrements the outstanding counter; call once per
///     non-nil dequeue.
///   - ``waitUntilEmpty`` returns when ``outstanding == 0``.
actor JobQueue {
    private var items: [Job] = []
    /// Suspended ``dequeue`` callers waiting for work.
    private var waiters: [(id: UUID, cont: CheckedContinuation<Job?, Never>)] = []
    /// outstanding = enqueued − taskDone. Drives ``waitUntilEmpty``.
    private var outstanding: Int = 0

    func enqueue(_ job: Job) {
        outstanding += 1
        if let first = waiters.first {
            waiters.removeFirst()
            first.cont.resume(returning: job)
        } else {
            items.append(job)
        }
    }

    func size() -> Int { outstanding }

    func isEmpty() -> Bool { outstanding == 0 }

    /// Block up to ``timeout`` for a job. Returns ``nil`` on timeout.
    /// Call ``taskDone()`` after processing each non-nil result.
    func dequeue(timeout: TimeInterval) async -> Job? {
        if !items.isEmpty {
            return items.removeFirst()
        }
        let waiterID = UUID()
        let job = await withCheckedContinuation { (cont: CheckedContinuation<Job?, Never>) in
            waiters.append((waiterID, cont))
            // Timer task: if the waiter is still present after the
            // timeout, resume it with nil.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await self?.timeOut(waiterID: waiterID)
            }
        }
        return job
    }

    func taskDone() {
        if outstanding > 0 { outstanding -= 1 }
    }

    func waitUntilEmpty() async {
        while outstanding > 0 {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - internals

    private func timeOut(waiterID: UUID) {
        guard let idx = waiters.firstIndex(where: { $0.id == waiterID }) else {
            return  // already resumed with a job
        }
        let (_, cont) = waiters.remove(at: idx)
        cont.resume(returning: nil)
    }
}
