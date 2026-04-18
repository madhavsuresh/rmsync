import Foundation

/// Adaptive cloud poller. Port of ``src/rm_sync/poller.py``.
///
/// Walks the remote Writing tree at an interval that adapts to recent
/// activity:
///
///   - **active** when something changed in the last 5 minutes
///   - **idle** when nothing changed in the last 20 minutes
///   - **default** otherwise
///
/// For each document whose ``ModifiedClient`` differs from what's
/// stored, enqueues a PULL. Missing docs (in state but not in the
/// remote listing) become DELETE_LOCAL after one poll cycle — the
/// safety delay absorbs transient listing glitches.
///
/// ``requestCycle()`` fires an immediate sync on demand; wired to the
/// IPC ``sync_now`` handler.
actor CloudPoller {
    private let cloud: Cloud
    private let state: State
    private let cfg: Config
    private let queue: JobQueue

    private var lastChangeAt: TimeInterval = 0
    private var stopFlag = false
    private var forceCycle = false
    /// doc_id → first time we saw it missing on the remote.
    private var pendingDeletes: [String: TimeInterval] = [:]

    private static let activeWindow: TimeInterval = 5 * 60
    private static let idleWindow: TimeInterval = 20 * 60

    init(cloud: Cloud, state: State, cfg: Config, queue: JobQueue) {
        self.cloud = cloud
        self.state = state
        self.cfg = cfg
        self.queue = queue
    }

    func stop() { stopFlag = true }

    /// Ask the poller to run its next cycle immediately.
    func requestCycle() { forceCycle = true }

    func run() async {
        Logger.shared.info("poller started")
        while !stopFlag {
            do {
                try await cycle()
            } catch let e as RmapiError where e.isThrottle {
                Logger.shared.warn("rmapi throttled", meta: ["error": "\(e)"])
                try? await Task.sleep(for: .seconds(60))
            } catch {
                Logger.shared.error(
                    "poller cycle crashed", meta: ["error": "\(error)"]
                )
                try? await Task.sleep(for: .seconds(cfg.pollIntervalSeconds))
                continue
            }
            await sleepUntilNextCycle()
        }
        Logger.shared.info("poller stopped")
    }

    // MARK: - cycle

    private func cycle() async throws {
        let nodes = try await cloud.tree("/\(cfg.remoteFolder)")
        var seenIDs: Set<String> = []
        var anyChange = false

        for node in nodes where node.type == .document {
            seenIDs.insert(node.id)
            let stored = try await state.get(docID: node.id)
            let remotePath = node.remotePath
            let localPath = PathUtilities.remoteToLocal(
                remotePath: remotePath,
                syncDir: cfg.syncDir,
                remoteFolder: cfg.remoteFolder
            ).path

            guard let stored else {
                anyChange = true
                Logger.shared.info(
                    "new remote doc",
                    meta: ["doc_id": node.id, "path": remotePath]
                )
                await queue.enqueue(Job(kind: .pull, docID: node.id, hint: remotePath))
                continue
            }

            if !node.modifiedClient.isEmpty,
               node.modifiedClient != (stored.remoteModified ?? "") {
                anyChange = true
                Logger.shared.info(
                    "remote changed",
                    meta: [
                        "doc_id": node.id,
                        "old": stored.remoteModified ?? "",
                        "new": node.modifiedClient,
                    ]
                )
                await queue.enqueue(Job(kind: .pull, docID: node.id, hint: remotePath))
            }

            if remotePath != stored.remotePath || localPath != stored.localPath {
                anyChange = true
                Logger.shared.info(
                    "remote renamed/moved",
                    meta: ["doc_id": node.id, "new_path": remotePath]
                )
                await queue.enqueue(
                    Job(kind: .renameRemote, docID: node.id, hint: remotePath)
                )
            }
        }

        await handleMissing(seenIDs: seenIDs)

        if anyChange {
            lastChangeAt = now()
        }
    }

    /// If a doc disappears from the cloud listing, wait one full poll
    /// interval before treating it as a deletion — handles transient
    /// listing glitches without immediately destroying local files.
    private func handleMissing(seenIDs: Set<String>) async {
        let currentTime = now()
        let docs = (try? await state.allDocuments()) ?? []
        for doc in docs where doc.docType == "DocumentType" {
            if seenIDs.contains(doc.docID) {
                pendingDeletes.removeValue(forKey: doc.docID)
                continue
            }
            let firstSeen = pendingDeletes[doc.docID] ?? currentTime
            pendingDeletes[doc.docID] = firstSeen
            if currentTime - firstSeen >= Double(cfg.pollIntervalSeconds) {
                Logger.shared.info(
                    "remote deletion confirmed",
                    meta: ["doc_id": doc.docID]
                )
                await queue.enqueue(
                    Job(kind: .deleteLocal, docID: doc.docID, hint: doc.localPath)
                )
                pendingDeletes.removeValue(forKey: doc.docID)
            }
        }
    }

    // MARK: - sleep with force-break

    private func sleepUntilNextCycle() async {
        let since = lastChangeAt == 0 ? .infinity : now() - lastChangeAt
        let interval: TimeInterval
        if since < Self.activeWindow {
            interval = Double(cfg.pollActiveIntervalSeconds)
        } else if since > Self.idleWindow {
            interval = Double(cfg.pollIdleIntervalSeconds)
        } else {
            interval = Double(cfg.pollIntervalSeconds)
        }

        // Poll ``forceCycle`` in short sleeps. Cheaper and simpler than
        // a continuation-based race, and the granularity of "up to 500ms
        // of extra wait when a sync_now arrives" is fine.
        let deadline = Date().addingTimeInterval(interval)
        while !stopFlag, Date() < deadline {
            if forceCycle {
                forceCycle = false
                Logger.shared.info("force-sync requested")
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func now() -> TimeInterval { Date().timeIntervalSince1970 }
}
