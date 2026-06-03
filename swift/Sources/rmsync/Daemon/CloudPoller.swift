import Foundation

/// Adaptive cloud poller. Port of ``src/rm_sync/poller.py``.
///
/// Walks the configured remote tree at an interval that adapts to recent
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
    private let cloud: any CloudClient
    private let state: State
    private let cfg: Config
    private let queue: JobQueue

    private var lastChangeAt: TimeInterval = 0
    private var stopFlag = false
    private var forceCycle = false
    /// doc_id → first time we saw it missing on the remote.
    private var pendingDeletes: [String: TimeInterval] = [:]
    /// Cloud-side collection paths observed in the previous
    /// cycle. Diffed against this cycle's set so we can detect
    /// folders that were removed on the tablet and mirror the
    /// removal into local empty-dir cleanup. Populated lazily —
    /// stays empty until the first cycle with collection nodes.
    private var lastObservedCloudFolders: Set<String> = []

    private static let activeWindow: TimeInterval = 5 * 60
    private static let idleWindow: TimeInterval = 20 * 60

    /// Decide whether the current poll cycle's ``seenIDs`` cardinality
    /// is plausible enough to act on for delete detection. A
    /// drastically-shortened listing relative to what state.db tracks
    /// is more likely a partial response from rmapi (transient,
    /// retryable on the next cycle) than a genuine wave of cloud-side
    /// deletions, so we refuse to enqueue ``deleteLocal`` jobs in
    /// that case.
    ///
    /// Threshold logic:
    ///   - Trivial libraries (``trackedCount < 5``): no gate. The
    ///     bulk-delete brake at the worker level is sufficient
    ///     protection at small scale, and a strict ratio gate at
    ///     these sizes would refuse legitimate deletions of 1-2 docs
    ///     out of 4-5 total.
    ///   - Otherwise: ``seenCount`` must be at least 70 % of
    ///     ``trackedCount``. So a 50-doc library missing 20 in one
    ///     listing trips the gate (likely partial listing); missing
    ///     5 of 50 (90 %) does not (legitimate deletion path).
    /// Static so unit tests can drive the decision directly without
    /// constructing a CloudPoller.
    static func shouldRunMissingDetection(
        seenCount: Int, trackedCount: Int
    ) -> Bool {
        guard trackedCount >= 5 else { return true }
        let floor = Int(Double(trackedCount) * 0.7)
        return seenCount >= floor
    }

    init(cloud: any CloudClient, state: State, cfg: Config, queue: JobQueue) {
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
        let nodes = try await cloud.tree(PathUtilities.remoteFolderPath(cfg.remoteFolder))
        var seenIDs: Set<String> = []
        var seenCloudFolders: Set<String> = []
        var anyChange = false

        // Cloud → local folder mirroring (v0.2.22+). Empty cloud
        // folders are surfaced by ``cloud.tree`` as ``.collection``
        // nodes; we ensure each has a matching local directory.
        // The pull side already auto-creates intermediate dirs
        // when a doc lands inside, but standalone empty folders
        // wouldn't appear locally without this branch.
        for node in nodes where node.type == .collection {
            seenCloudFolders.insert(node.remotePath)
            let localDir = PathUtilities.remoteToLocalDir(
                remotePath: node.remotePath,
                syncDir: cfg.syncDir,
                remoteFolder: cfg.remoteFolder
            )
            // Symlink-escape / hidden-dir guards apply to the
            // computed local path too — refuse to materialize a
            // dir at e.g. ``.git/`` even if the cloud somehow
            // surfaces such a node.
            if WatcherFilter.shouldIgnoreDir(
                localDir.path, root: cfg.syncDir, mode: .markdown
            ) { continue }
            if !FileManager.default.fileExists(atPath: localDir.path) {
                Logger.shared.info(
                    "creating local dir to mirror cloud folder",
                    meta: ["remote": node.remotePath, "local": localDir.path]
                )
                try? FileManager.default.createDirectory(
                    at: localDir, withIntermediateDirectories: true
                )
                anyChange = true
            }
        }

        // Cloud-side folder removal mirrored locally. Conservative:
        //   1. Only act on folders we observed in a previous cycle
        //      AND no longer see this cycle (so a daemon restart
        //      can't immediately wipe local dirs that were never
        //      confirmed against the cloud).
        //   2. Only remove if the local dir exists and is empty —
        //      half-cascaded delete bursts mustn't trash docs.
        //   3. Gated on ``deletion.enable_propagation`` because
        //      removing on-disk content is destructive.
        if cfg.deletion.enablePropagation, !lastObservedCloudFolders.isEmpty {
            let removed = lastObservedCloudFolders.subtracting(seenCloudFolders)
            for remotePath in removed {
                let localDir = PathUtilities.remoteToLocalDir(
                    remotePath: remotePath,
                    syncDir: cfg.syncDir,
                    remoteFolder: cfg.remoteFolder
                )
                guard FileManager.default.fileExists(atPath: localDir.path) else { continue }
                let contents = (try? FileManager.default.contentsOfDirectory(atPath: localDir.path)) ?? []
                guard contents.isEmpty else {
                    Logger.shared.debug(
                        "cloud folder gone but local has content; leaving",
                        meta: ["remote": remotePath, "local": localDir.path]
                    )
                    continue
                }
                Logger.shared.info(
                    "removing local dir to mirror deleted cloud folder",
                    meta: ["remote": remotePath, "local": localDir.path]
                )
                try? FileManager.default.removeItem(at: localDir)
                anyChange = true
            }
        }
        lastObservedCloudFolders = seenCloudFolders

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
                    meta: [
                        "doc_id": node.id,
                        "old_remote": stored.remotePath,
                        "new_remote": remotePath,
                    ]
                )
                if cfg.deletion.enablePropagation {
                    // hint = "<oldRemote>\t<newRemote>" so the
                    // worker can compute both old and new local
                    // paths via Paths.remoteToLocal and seed the
                    // echo fence on the new local before doing
                    // the move.
                    await queue.enqueue(Job(
                        kind: .renameLocal,
                        docID: node.id,
                        hint: RenameHint.encode(from: stored.remotePath, to: remotePath)
                    ))
                } else {
                    Logger.shared.info(
                        "remote rename detected (propagation disabled — skip)",
                        meta: ["doc_id": node.id]
                    )
                }
            }
        }

        // Cardinality gate before delete-detection. If ``cloud.tree``
        // returned a partial listing (rmapi quirk, paginated-endpoint
        // mid-flight failure that didn't bubble up as a thrown error,
        // etc.), ``seenIDs`` would be incomplete and ``handleMissing``
        // would treat every absent tracked doc as cloud-deleted.
        // Combined with the two-poll grace and the bulk-delete brake,
        // a sustained partial listing could still slip through and
        // mass-trash the user's library.
        //
        // First line of defense: if the listing came back with far
        // fewer documents than state.db tracks, refuse delete-
        // detection this cycle — wait for the next poll. The
        // tracked-doc count is read here (not in handleMissing) so
        // the warn-log is precise about what was suspect.
        let trackedDocs = (try? await state.allDocuments()) ?? []
        let trackedDocCount = trackedDocs
            .filter { $0.docType == "DocumentType" }
            .count
        if Self.shouldRunMissingDetection(
            seenCount: seenIDs.count,
            trackedCount: trackedDocCount
        ) {
            await handleMissing(seenIDs: seenIDs)
        } else {
            Logger.shared.warn(
                "cloud listing returned suspiciously few docs; skipping delete detection this cycle",
                meta: [
                    "seen": "\(seenIDs.count)",
                    "tracked": "\(trackedDocCount)",
                ]
            )
            // Reset pendingDeletes so a subsequent recovered listing
            // doesn't punish us for the missing-detection skip we
            // just performed. Otherwise a doc that's *legitimately*
            // gone but happened to land in a partial-listing cycle
            // would be one cycle older in pendingDeletes than it
            // should be — fine, but cleaner to clear and let the
            // next good listing restart the grace timer.
            pendingDeletes.removeAll()
        }

        if anyChange {
            lastChangeAt = now()
        }
    }

    /// If a doc disappears from the cloud listing, wait one full poll
    /// interval before treating it as a deletion — handles transient
    /// listing glitches without immediately destroying local files.
    ///
    /// The diff is keyed on ``doc_id``, not path, on purpose: a cloud-
    /// side rename preserves the doc UUID across the ``rmapi mv``
    /// call, so a renamed doc continues to appear in ``seenIDs`` and
    /// is *not* treated as deleted. The Phase-5 ``.renameLocal``
    /// handler picks up the path-change branch in the main ``cycle``
    /// loop. This is the load-bearing reason we never key delete
    /// detection on remote_path.
    ///
    /// Gating: when ``cfg.deletion.enablePropagation`` is false (the
    /// default for v0.2.19), we still log the missing doc but do not
    /// enqueue the ``.deleteLocal`` job. That way users can verify
    /// the detection works on their tree before flipping the switch.
    /// Internal-but-not-private so unit tests can drive the
    /// missing-doc branch directly without spinning up rmapi.
    /// Production callers go through ``cycle()``.
    func handleMissing(seenIDs: Set<String>) async {
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
                if cfg.deletion.enablePropagation {
                    Logger.shared.info(
                        "remote deletion confirmed; enqueuing local delete",
                        meta: ["doc_id": doc.docID, "path": doc.localPath]
                    )
                    await queue.enqueue(
                        Job(kind: .deleteLocal, docID: doc.docID, hint: doc.localPath)
                    )
                } else {
                    Logger.shared.info(
                        "remote deletion detected (propagation disabled — skip)",
                        meta: ["doc_id": doc.docID, "path": doc.localPath]
                    )
                }
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
