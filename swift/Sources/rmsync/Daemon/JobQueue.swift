import Foundation

/// Path-only FIFO used by safe auto-push.
///
/// The explicit-sync daemon no longer has a general background worker. The
/// only watcher-driven mutation surface left is opt-in auto-push of changed
/// Markdown files, so this queue carries canonical local paths rather than a
/// general operation enum.
actor AutoPushEventQueue {
    private var items: [String] = []
    private var waiters: [(id: UUID, cont: CheckedContinuation<String?, Never>)] = []
    private var outstanding: Int = 0

    func enqueue(_ path: String) {
        outstanding += 1
        if let first = waiters.first {
            waiters.removeFirst()
            first.cont.resume(returning: path)
        } else {
            items.append(path)
        }
    }

    func size() -> Int { outstanding }

    func isEmpty() -> Bool { outstanding == 0 }

    func dequeue(timeout: TimeInterval) async -> String? {
        if !items.isEmpty {
            return items.removeFirst()
        }
        let waiterID = UUID()
        let path = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            waiters.append((waiterID, cont))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await self?.timeOut(waiterID: waiterID)
            }
        }
        return path
    }

    func taskDone() {
        if outstanding > 0 { outstanding -= 1 }
    }

    func waitUntilEmpty() async {
        while outstanding > 0 {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func timeOut(waiterID: UUID) {
        guard let idx = waiters.firstIndex(where: { $0.id == waiterID }) else {
            return
        }
        let (_, cont) = waiters.remove(at: idx)
        cont.resume(returning: nil)
    }
}
