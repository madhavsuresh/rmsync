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

    func subscribe() -> (AsyncStream<SendableJSON>, UUID, IPC.Status) {
        let id = UUID()
        let stream = AsyncStream<SendableJSON> { cont in
            subscribers[id] = cont
            cont.onTermination = { @Sendable _ in
                Task { [weak self] in await self?.unsubscribe(id: id) }
            }
        }
        return (stream, id, status)
    }

    func unsubscribe(id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    // MARK: - framing

    static func statusFrame(for s: IPC.Status) -> SendableJSON {
        SendableJSON.dict(statusPayload(s, includeType: true))
    }

    static func helloFrame(for s: IPC.Status) -> SendableJSON {
        SendableJSON.dict([
            "type": "hello",
            "status": .object(statusPayload(s, includeType: false)),
        ])
    }

    /// Shared field-list builder for both ``statusFrame`` (where
    /// the dict is the top-level message and needs ``type`` next
    /// to the data) and ``helloFrame`` (where the dict is nested
    /// under ``status`` and ``type`` lives at the outer layer).
    /// Refactored from two near-identical literals in v0.2.25 so
    /// the cloud-health fields can be added in one place.
    private static func statusPayload(
        _ s: IPC.Status, includeType: Bool
    ) -> [String: SendableValue] {
        var payload: [String: SendableValue] = [
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
            "version": .string(s.version),
            "last_pull_at": s.lastPullAt.map { .string($0) } ?? .null,
            "last_push_at": s.lastPushAt.map { .string($0) } ?? .null,
            "last_error": s.lastError.map { .string($0) } ?? .null,
            "cloud_health": .string(s.cloudHealth),
            "cloud_health_detail": s.cloudHealthDetail.map { .string($0) } ?? .null,
        ]
        if includeType { payload["type"] = .string("status") }
        return payload
    }
}
