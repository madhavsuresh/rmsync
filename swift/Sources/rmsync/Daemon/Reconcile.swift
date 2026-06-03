import Foundation

/// Startup reconciliation passes. Ports the three-step sequence in
/// ``src/rm_sync/daemon.py``:
///
///   1. **Local deletions** — files that were tracked but no longer
///      exist on disk get a ``DELETE_REMOTE`` job. Runs BEFORE the
///      initial pull so we don't re-pull a file the user just deleted.
///   2. **Initial pull** — walk the remote tree, enqueue PULL for every
///      document. Workers drain the queue before we continue.
///   3. **Local creates/edits** — files that are on disk but unknown to
///      state (or whose hash differs from ``last_synced_md_hash``) get
///      a PUSH job. Runs AFTER the pull so the state DB is current.
enum Reconcile {
    /// First-startup deletion reconcile.
    ///
    /// ``skipDeletePropagation`` (v0.2.31+): when true, tracked-
    /// but-locally-missing rows are PARKED with
    /// ``error_state = "missing_pre_upgrade"`` instead of being
    /// enqueued for cloud-side delete. Used on the first daemon
    /// start after a version change — protects users who rm'd
    /// files locally on a version that didn't propagate (the
    /// pre-v0.2.27 default behavior) from having those rms
    /// silently cascade to the cloud now that propagation is on
    /// by default.
    ///
    /// Pending-op resumes still fire even with the flag set;
    /// those represent in-flight ops the daemon was already
    /// committed to before the upgrade, not "old deletes from
    /// before propagation was on".
    static func localDeletions(
        state: State, queue: JobQueue,
        skipDeletePropagation: Bool = false
    ) async throws {
        var enqueued = 0
        var resumed = 0
        var parkedAsUpgradeMissing = 0
        let docs = try await state.allDocuments()

        // First pass: resume any in-flight ``pending_delete`` /
        // ``pending_rename`` row. These are docs whose worker had
        // already crossed the "trash + pending_op stamp" line before
        // the daemon last exited, but didn't get to clear the row.
        // We re-enqueue the same kind of job so the (now-clean)
        // worker runs the cloud step to completion.
        for doc in docs where doc.pendingOp == "pending_delete" {
            Logger.shared.info(
                "resuming in-flight delete from prior run",
                meta: ["doc_id": doc.docID, "remote": doc.remotePath]
            )
            await queue.enqueue(Job(
                kind: .deleteRemote, docID: doc.docID, hint: doc.remotePath
            ))
            resumed += 1
        }
        // Resume pending_rename: the row's ``local_path`` already
        // points at the destination (the worker writes that before
        // the cloud mv); ``remote_path`` is still the source. Re-
        // enqueue a renameRemote with hint "<localPath>\t<localPath>"
        // — both halves point at the (already-moved) file, and the
        // worker's path-relative remote computation derives the
        // correct new remote from local_path. The from-side of the
        // hint is unused except for the lookup, which falls through
        // to the to-side via state.byLocalPath.
        for doc in docs where doc.pendingOp == "pending_rename" {
            Logger.shared.info(
                "resuming in-flight rename from prior run",
                meta: ["doc_id": doc.docID, "remote": doc.remotePath, "path": doc.localPath]
            )
            await queue.enqueue(Job(
                kind: .renameRemote,
                docID: doc.docID,
                hint: RenameHint.encode(from: doc.localPath, to: doc.localPath)
            ))
            resumed += 1
        }

        // Second pass: fresh local-deletion detection. Skip rows we
        // already enqueued above (they're still in pending_op state),
        // skip rows that haven't been synced (lastSyncedMDHash empty
        // ≡ never confirmed on the cloud side, nothing to delete).
        for doc in docs where doc.docType == "DocumentType" {
            if doc.pendingOp != nil { continue }
            guard let hash = doc.lastSyncedMDHash, !hash.isEmpty else { continue }
            if FileManager.default.fileExists(atPath: doc.localPath) { continue }

            if skipDeletePropagation {
                // First-start-after-upgrade guard: park the row
                // with a distinct error_state so the user sees it
                // in ``rmsync errors`` and can decide
                // (intentional delete → ``rmapi rm`` to cloud-
                // delete; accidental delete → restore from
                // backup / re-pull from cloud). Crucially, we
                // do NOT enqueue a deleteRemote — that would
                // cascade old user rm's into cloud trash and is
                // exactly the data-loss scenario this guard
                // exists to prevent.
                Logger.shared.warn(
                    "tracked doc missing locally; NOT propagating "
                      + "(first start after upgrade — see `rmsync errors`)",
                    meta: [
                        "doc_id": doc.docID,
                        "path": doc.localPath,
                        "remote": doc.remotePath,
                    ]
                )
                try? await state.setError(
                    docID: doc.docID, state: "missing_pre_upgrade"
                )
                parkedAsUpgradeMissing += 1
                continue
            }

            Logger.shared.info(
                "local file missing on startup; propagating to cloud trash",
                meta: [
                    "doc_id": doc.docID,
                    "path": doc.localPath,
                    "remote": doc.remotePath,
                ]
            )
            await queue.enqueue(Job(
                kind: .deleteRemote, docID: doc.docID, hint: doc.remotePath
            ))
            enqueued += 1
        }
        if enqueued + resumed + parkedAsUpgradeMissing > 0 {
            Logger.shared.info(
                "startup deletion reconcile",
                meta: [
                    "enqueued": "\(enqueued)",
                    "resumed": "\(resumed)",
                    "parked_as_upgrade_missing": "\(parkedAsUpgradeMissing)",
                ]
            )
        }
    }

    /// Prune trash entries older than the configured retention
    /// window. Called at daemon startup alongside
    /// ``localDeletions``. Conservative: removes whole stamp
    /// directories whose timestamp is older than ``retentionDays``
    /// — never partial cleanups. Set ``trash_retention_days = 0``
    /// to keep trash forever (skip the prune entirely).
    ///
    /// Best-effort: a non-readable trash dir or a
    /// permission-denied removeItem doesn't stop reconcile from
    /// proceeding to the deletion / pull passes. Failures are
    /// logged at warn so an operator can spot them in
    /// ``rmsync logs``.
    static func pruneTrash(syncDir: URL, retentionDays: Int) {
        guard retentionDays > 0 else {
            Logger.shared.debug("trash retention = 0; skipping prune")
            return
        }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        do {
            let removed = try Trash.prune(syncDir: syncDir, olderThan: cutoff)
            if removed > 0 {
                Logger.shared.info(
                    "trash pruned",
                    meta: [
                        "removed": "\(removed)",
                        "retention_days": "\(retentionDays)",
                    ]
                )
            }
        } catch {
            Logger.shared.warn(
                "trash prune failed",
                meta: ["error": "\(error)"]
            )
        }
    }

    static func initialPull(
        cloud: any CloudClient, cfg: Config, queue: JobQueue
    ) async throws {
        Logger.shared.info("initial reconcile: walking remote tree")
        let nodes = try await cloud.tree(PathUtilities.remoteFolderPath(cfg.remoteFolder))
        var enqueued = 0
        for node in nodes where node.type == .document {
            await queue.enqueue(Job(
                kind: .pull, docID: node.id, hint: node.remotePath
            ))
            enqueued += 1
        }
        Logger.shared.info(
            "initial reconcile: enqueued", meta: ["count": "\(enqueued)"]
        )
        await queue.waitUntilEmpty()
        Logger.shared.info("initial reconcile: complete")
    }

    static func localCreatesAndEdits(
        state: State, cfg: Config, queue: JobQueue
    ) async throws {
        var enqueued = 0
        let fm = FileManager.default
        guard fm.fileExists(atPath: cfg.syncDir.path) else { return }

        let enumerator = fm.enumerator(
            at: cfg.syncDir,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: nil
        )
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension != "md" { continue }

            // Same ignore rules as the watcher. Routed through
            // ``WatcherFilter`` (the cross-platform extraction) so
            // this works on Linux too — ``LocalWatcher`` itself is
            // gated to macOS-only.
            if WatcherFilter.shouldIgnore(url.path, root: cfg.syncDir, mode: .markdown) { continue }

            let localPath = url.path
            let stored = try await state.byLocalPath(localPath)
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let currentHash = PathUtilities.sha256(text)

            if stored == nil {
                Logger.shared.info(
                    "startup: local-only file, enqueuing push",
                    meta: ["path": localPath]
                )
                await queue.enqueue(Job(kind: .push, docID: nil, hint: localPath))
                enqueued += 1
            } else if let hash = stored?.lastSyncedMDHash,
                      !hash.isEmpty,
                      hash != currentHash {
                Logger.shared.info(
                    "startup: local file edited while daemon was off",
                    meta: ["doc_id": stored!.docID, "path": localPath]
                )
                await queue.enqueue(Job(
                    kind: .push, docID: stored!.docID, hint: localPath
                ))
                enqueued += 1
            }
        }
        if enqueued > 0 {
            Logger.shared.info(
                "startup local-change reconcile", meta: ["enqueued": "\(enqueued)"]
            )
        }
    }
}
