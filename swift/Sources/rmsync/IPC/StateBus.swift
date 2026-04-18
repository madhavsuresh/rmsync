import Foundation

/// Broadcast channel for status transitions.
///
/// Ports the Python ``StateBus`` class. Keeps the current ``Status``, lets
/// readers subscribe, and fans out every mutation to connected clients.
/// Subscribers receive ``SendableJSON`` frames ready to be written to the
/// wire.
actor StateBus {
    private var status: IPC.Status = .empty
    private var subscribers: [UUID: AsyncStream<SendableJSON>.Continuation] = [:]

    func snapshot() -> IPC.Status { status }

    /// Bulk-update fields on the current status and broadcast the new
    /// snapshot as a ``status`` frame.
    func update(_ block: @Sendable (inout IPC.Status) -> Void) {
        block(&status)
        status.updatedAt = ISO8601.now()
        let frame = Self.statusFrame(for: status)
        for cont in subscribers.values {
            cont.yield(frame)
        }
    }

    func subscribe() -> (AsyncStream<SendableJSON>, UUID) {
        let id = UUID()
        let stream = AsyncStream<SendableJSON> { cont in
            subscribers[id] = cont
            cont.onTermination = { @Sendable _ in
                Task { [weak self] in await self?.unsubscribe(id: id) }
            }
        }
        return (stream, id)
    }

    func unsubscribe(id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    // MARK: - framing

    static func statusFrame(for s: IPC.Status) -> SendableJSON {
        let payload: [String: SendableValue] = [
            "type": "status",
            "state": .string(s.state),
            "sync_dir": .string(s.syncDir),
            "remote_folder": .string(s.remoteFolder),
            "tracked_docs": .int(s.trackedDocs),
            "conflicts": .int(s.conflicts),
            "errors": .int(s.errors),
            "queue_depth": .int(s.queueDepth),
            "paused": .bool(s.paused),
            "updated_at": .string(s.updatedAt),
            "pid": .int(s.pid),
            "last_pull_at": s.lastPullAt.map { .string($0) } ?? .null,
            "last_push_at": s.lastPushAt.map { .string($0) } ?? .null,
            "last_error": s.lastError.map { .string($0) } ?? .null,
        ]
        return SendableJSON.dict(payload)
    }

    static func helloFrame(for s: IPC.Status) -> SendableJSON {
        let status: [String: SendableValue] = [
            "state": .string(s.state),
            "sync_dir": .string(s.syncDir),
            "remote_folder": .string(s.remoteFolder),
            "tracked_docs": .int(s.trackedDocs),
            "conflicts": .int(s.conflicts),
            "errors": .int(s.errors),
            "queue_depth": .int(s.queueDepth),
            "paused": .bool(s.paused),
            "updated_at": .string(s.updatedAt),
            "pid": .int(s.pid),
            "last_pull_at": s.lastPullAt.map { .string($0) } ?? .null,
            "last_push_at": s.lastPushAt.map { .string($0) } ?? .null,
            "last_error": s.lastError.map { .string($0) } ?? .null,
        ]
        return SendableJSON.dict(["type": "hello", "status": .object(status)])
    }
}
