import Foundation

/// Per-doc-id serialization. Two pull jobs can fire for the same doc
/// back-to-back (poller + force-sync, for example) and we need to
/// guarantee they run sequentially.
///
/// Port of ``src/rm_sync/locks.py``. The Python version used
/// ``defaultdict(asyncio.Lock)``; the Swift equivalent is an actor with
/// an async semaphore map.
actor LockRegistry {
    private var locks: [String: AsyncLock] = [:]

    func acquire(_ key: String) async -> AsyncLock.Token {
        if locks[key] == nil {
            locks[key] = AsyncLock()
        }
        return await locks[key]!.lock()
    }
}

/// Cheap async mutual-exclusion primitive. Holds one outstanding
/// continuation and a waiters queue. Callers hold the returned token
/// until done; release is via ``Token.release()``.
actor AsyncLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async -> Token {
        if !locked {
            locked = true
            return Token(lock: self)
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
        return Token(lock: self)
    }

    fileprivate func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            locked = false
        }
    }

    /// RAII token. Callers must explicitly release by calling
    /// ``await token.release()``. Forgetting to release deadlocks the
    /// registry, so keep the window small (one pull/push per token).
    struct Token: Sendable {
        private let lock: AsyncLock
        init(lock: AsyncLock) { self.lock = lock }
        func release() async { await lock.release() }
    }
}
