import Foundation

/// Read-only cloud probe for menubar/status hints.
///
/// This is deliberately not a sync worker: it never downloads archives, writes
/// staged pulls, accepts changes, deletes local files, or enqueues work. It
/// only compares cloud document metadata against the current state database so
/// the UI can say whether `rmsync pull` is likely to stage work.
final class PullAvailabilityProbe: @unchecked Sendable {
    struct Result: Sendable, Equatable {
        var changes: Int
    }

    private let cfg: Config
    private let state: State
    private let bus: StateBus
    private let cloud: any CloudClient
    private let interval: TimeInterval
    private var task: Task<Void, Never>?

    init(
        cfg: Config,
        state: State,
        bus: StateBus,
        cloud: any CloudClient = Cloud(),
        interval: TimeInterval = 60
    ) {
        self.cfg = cfg
        self.state = state
        self.bus = bus
        self.cloud = cloud
        self.interval = interval
    }

    func start() {
        task = Task { [cfg, state, bus, cloud, interval] in
            while !Task.isCancelled {
                await Self.publishProbe(cfg: cfg, state: state, bus: bus, cloud: cloud)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    static func publishProbe(
        cfg: Config,
        state: State,
        bus: StateBus,
        cloud: any CloudClient
    ) async {
        await bus.update { status in
            status.pullState = "checking"
            status.pullError = nil
        }
        do {
            let result = try await measure(cfg: cfg, state: state, cloud: cloud)
            await bus.update { status in
                status.pullState = result.changes > 0 ? "available" : "clean"
                status.pullChanges = result.changes
                status.pullCheckedAt = ISO8601.now()
                status.pullError = nil
            }
        } catch {
            await bus.update { status in
                status.pullState = "error"
                status.pullChanges = 0
                status.pullCheckedAt = ISO8601.now()
                status.pullError = "\(error)"
            }
            Logger.shared.warn("pull availability probe failed", meta: ["error": "\(error)"])
        }
    }

    static func measure(
        cfg: Config,
        state: State,
        cloud: any CloudClient
    ) async throws -> Result {
        let nodes = try await cloud.tree(PathUtilities.remoteFolderPath(cfg.remoteFolder))
        let remoteDocs = nodes.filter { $0.type == .document }
        let allDocs = try await state.allDocuments()
        let localDocs = allDocs.filter { $0.docType == "DocumentType" }
        let localByID = Dictionary(uniqueKeysWithValues: localDocs.map { ($0.docID, $0) })

        var seenIDs: Set<String> = []
        var changes = 0

        for node in remoteDocs {
            seenIDs.insert(node.id)
            guard let doc = localByID[node.id] else {
                changes += 1
                continue
            }
            if try await remoteNodeNeedsPull(node, stored: doc, state: state) {
                changes += 1
            }
        }

        for doc in localDocs where !seenIDs.contains(doc.docID) {
            changes += 1
        }

        return Result(changes: changes)
    }

    private static func remoteNodeNeedsPull(
        _ node: Node,
        stored doc: Document,
        state: State
    ) async throws -> Bool {
        if doc.remotePath != node.remotePath {
            return true
        }

        let fingerprint = ExplicitSync.remoteFingerprint(node)
        if let snapshot = try await state.remoteSnapshot(docID: node.id) {
            return snapshot.remotePath != node.remotePath
                || snapshot.remoteFingerprint != fingerprint
        }

        let remoteModified = node.modifiedClient.isEmpty ? nil : node.modifiedClient
        return doc.remoteModified != remoteModified || doc.remoteVersion != node.version
    }
}
