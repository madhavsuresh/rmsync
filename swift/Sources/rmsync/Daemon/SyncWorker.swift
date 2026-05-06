import Foundation

/// Pulls and (eventually) pushes documents against the reMarkable cloud.
///
/// Week 4 ships the pull side. Push arrives in Week 5 along with the
/// page_id/author_uuid invariants, archive packing, and ``rmapi put --force``.
///
/// Flow mirrors ``src/rm_sync/worker.py:_pull`` verbatim:
///   1. Acquire per-doc lock so two pulls of the same doc serialize.
///   2. If the doc is in ``conflict_state = unresolved`` and the .conflict
///      file is still present, skip — user hasn't resolved yet.
///   3. rmapi get → unpack → parse each page via the rmscene bridge →
///      join with page-break sentinel → sha256.
///   4. If the joined hash matches ``last_synced_md_hash``, no-op.
///   5. If the local file has changed since last sync, it's a conflict:
///      write the .conflict file, set state, notify the user.
///   6. Otherwise atomic-write the new content, stamp the echo fence,
///      re-stat the cloud for ``ModifiedClient``, update state.
actor SyncWorker {
    private let id: Int
    private let queue: JobQueue
    private let cloud: Cloud
    private let state: State
    private let cfg: Config
    private let locks: LockRegistry
    private let fence: EchoFence
    /// Bulk-delete brake. Shared across every worker in the pool so
    /// the rolling window measures the *aggregate* rate. ``nil``
    /// means propagation is disabled (``cfg.deletion.enable_propagation
    /// = false``); the worker treats every destructive job as a
    /// no-op in that case.
    private let limiter: DeletionRateLimiter?
    /// StateBus we publish cloud-health classifications onto. On
    /// push failure, the worker classifies the error via
    /// ``CloudHealthProbe.classifyAndPublish(_:on:)`` and the
    /// menubar / `rmsync status` reads the result from here.
    /// ``nil`` means the worker was constructed without IPC
    /// plumbing (early tests); classification is skipped.
    ///
    /// v0.2.29 dropped the previous ``CloudHealthProbe`` actor
    /// (which shelled out to ``rmapi mkdir`` against a sentinel
    /// path and left ``.rmsync-health-<uuid>`` directories on
    /// the cloud whenever the cleanup ``rmapi rm`` couldn't
    /// clean up). The replacement classifier is stateless —
    /// inspects the original push error's text — so no extra
    /// cloud writes happen.
    private let bus: StateBus?
    private var stopFlag = false

    init(
        id: Int,
        queue: JobQueue,
        cloud: Cloud,
        state: State,
        cfg: Config,
        locks: LockRegistry,
        fence: EchoFence,
        limiter: DeletionRateLimiter? = nil,
        bus: StateBus? = nil
    ) {
        self.id = id
        self.queue = queue
        self.cloud = cloud
        self.state = state
        self.cfg = cfg
        self.locks = locks
        self.fence = fence
        self.limiter = limiter
        self.bus = bus
    }

    func stop() { stopFlag = true }

    func run() async {
        Logger.shared.info("worker started", meta: ["worker": "\(id)"])
        while !stopFlag {
            guard let job = await queue.dequeue(timeout: 1.0) else { continue }
            defer { Task { await queue.taskDone() } }

            if cfg.dryRun {
                Logger.shared.info(
                    "dry-run skip",
                    meta: ["kind": job.kind.rawValue, "hint": job.hint]
                )
                continue
            }
            do {
                try await dispatch(job)
            } catch let e as RmapiError where e.isThrottle {
                Logger.shared.warn("worker throttled", meta: ["worker": "\(id)"])
                try? await Task.sleep(for: .seconds(60))
                await queue.enqueue(job)
            } catch {
                Logger.shared.error(
                    "worker job crashed",
                    meta: ["worker": "\(id)", "error": "\(error)"]
                )
            }
        }
        Logger.shared.info("worker stopped", meta: ["worker": "\(id)"])
    }

    // MARK: - dispatch

    private func dispatch(_ job: Job) async throws {
        switch job.kind {
        case .pull:
            guard let docID = job.docID else {
                Logger.shared.warn("pull without doc_id", meta: ["hint": job.hint])
                return
            }
            let token = await locks.acquire(docID)
            defer { Task { await token.release() } }
            try await pull(docID: docID, remotePath: job.hint)

        case .push:
            try await push(job)

        case .pushInbox:
            try await pushInbox(localPath: job.hint)

        case .deleteLocal:
            try await deleteLocalAndCloud(job)

        case .deleteRemote:
            try await deleteRemote(job)

        case .renameRemote:
            try await renameOnCloud(job)

        case .renameLocal:
            try await renameOnLocal(job)

        case .mkdirRemote:
            try await mkdirOnCloud(job)

        case .rmdirRemote:
            try await rmdirOnCloud(job)
        }
    }

    // MARK: - directory propagation

    /// Mirror a local mkdir on the cloud. Always-on (no
    /// propagation gate) — creating a folder is non-destructive
    /// and the case where rmapi mkdir errors because the folder
    /// already exists is the expected idempotent behavior.
    ///
    /// ``hint`` is the absolute local directory path. Empty /
    /// missing local dir is a logic bug (the watcher only fires
    /// when the dir exists), but we tolerate it: missing → log
    /// and bail.
    private func mkdirOnCloud(_ job: Job) async throws {
        let localDir = URL(fileURLWithPath: job.hint)
        guard FileManager.default.fileExists(atPath: localDir.path) else {
            Logger.shared.debug(
                "mkdirRemote: local dir vanished before worker fire",
                meta: ["path": job.hint]
            )
            return
        }
        let derivation = PathUtilities.localDirToRemoteChain(
            localDir: localDir,
            syncDir: cfg.syncDir,
            remoteFolder: cfg.remoteFolder
        )
        // mkdir each prefix; rmapi mkdir errors when the dir
        // exists — swallow with try?, the goal is "ensure
        // exists", not "create fresh".
        for prefix in derivation.mkdirChain {
            try? await cloud.mkdir(prefix)
        }
        Logger.shared.info(
            "mkdir: cloud folder ensured",
            meta: ["local": localDir.path, "remote": derivation.cloudPath]
        )
    }

    /// Mirror a local rmdir on the cloud. Destructive on the
    /// cloud (rmapi rm on a folder cascades into its contents),
    /// so:
    ///
    ///   1. Skip if propagation is off.
    ///   2. Skip if the cloud folder still has children — a
    ///      cascading delete burst may not have caught up yet.
    ///      Better to leave the folder than to nuke half-deleted
    ///      docs.
    ///   3. Cloud.rm only when verified empty.
    private func rmdirOnCloud(_ job: Job) async throws {
        guard cfg.deletion.enablePropagation else {
            Logger.shared.debug(
                "rmdir propagation disabled; ignoring rmdirRemote",
                meta: ["path": job.hint]
            )
            return
        }
        let localDir = URL(fileURLWithPath: job.hint)
        let derivation = PathUtilities.localDirToRemoteChain(
            localDir: localDir,
            syncDir: cfg.syncDir,
            remoteFolder: cfg.remoteFolder
        )
        let cloudPath = derivation.cloudPath

        // Safety: walk the cloud subtree. If anything is in
        // there, refuse — a cascading file-delete burst probably
        // hasn't completed yet.
        let children: [Node]
        do {
            children = try await cloud.tree(cloudPath)
        } catch {
            Logger.shared.warn(
                "rmdir: tree walk failed; refusing to delete",
                meta: ["remote": cloudPath, "error": "\(error)"]
            )
            return
        }
        guard children.isEmpty else {
            Logger.shared.info(
                "rmdir: cloud folder not empty; leaving in place",
                meta: ["remote": cloudPath, "child_count": "\(children.count)"]
            )
            return
        }

        do {
            try await cloud.rm(cloudPath)
            Logger.shared.info(
                "rmdir: cloud folder removed",
                meta: ["local": localDir.path, "remote": cloudPath]
            )
        } catch {
            Logger.shared.error(
                "rmdir: cloud rm failed",
                meta: ["remote": cloudPath, "error": "\(error)"]
            )
        }
    }

    // MARK: - rename propagation

    /// Apply a watcher-detected local rename to the cloud:
    ///   1. Decode hint as ``"<from>\t<to>"``.
    ///   2. Look up the doc by ``from`` (the pre-rename local path).
    ///      If unknown, the file wasn't tracked — bail.
    ///   3. Acquire the per-doc lock so we serialise against any
    ///      in-flight push for the same document.
    ///   4. Compute the new remote path from ``to`` relative to
    ///      ``cfg.syncDir``.
    ///   5. Mark ``pending_op = "pending_rename"`` and update
    ///      ``local_path`` to ``to`` so a crash here is recoverable.
    ///   6. ``Cloud.mv(oldRemote → newRemote)``.
    ///   7. Update ``remote_path`` and clear ``pending_op``.
    ///
    /// Cross-folder renames inside the sync tree (e.g. moving
    /// ``foo/x.md`` to ``bar/x.md``) take the same code path —
    /// rmapi's ``mv`` understands directory destinations natively.
    private func renameOnCloud(_ job: Job) async throws {
        guard cfg.deletion.enablePropagation else {
            Logger.shared.debug(
                "rename propagation disabled; ignoring renameRemote",
                meta: ["hint": job.hint]
            )
            return
        }
        guard let pair = RenameHint.decode(job.hint) else {
            Logger.shared.warn(
                "renameRemote: malformed hint",
                meta: ["hint": job.hint]
            )
            return
        }

        // Find the doc via its pre-rename local path. If the
        // watcher already updated state.db for any reason (e.g.
        // resume-after-crash with pending_op = "pending_rename")
        // we also accept the post-rename path so the resume path
        // self-heals.
        let fromHit = try await state.byLocalPath(pair.from)
        let toHit = try await state.byLocalPath(pair.to)
        guard let doc = fromHit ?? toHit else {
            Logger.shared.info(
                "renameRemote ignored: untracked file",
                meta: ["from": pair.from, "to": pair.to]
            )
            return
        }

        let token = await locks.acquire(doc.docID)
        defer { Task { await token.release() } }

        // Compute the new remote path. Path semantics: the cloud
        // doc lives at "/Writing/<rel-without-extension>" by
        // convention. We sanitize each segment the same way
        // ``Paths.remoteToLocal`` does so a round-trip is stable.
        guard let relTo = PathUtilities.resolvedRelativePath(
            from: cfg.syncDir, to: URL(fileURLWithPath: pair.to)
        ) else {
            Logger.shared.warn(
                "renameRemote: target outside sync_dir",
                meta: ["doc_id": doc.docID, "to": pair.to]
            )
            return
        }
        let cleanRel = relTo.dropLast() + [
            URL(fileURLWithPath: pair.to).deletingPathExtension().lastPathComponent
        ]
        let newRemote = "/" + ([cfg.remoteFolder] + cleanRel).joined(separator: "/")

        // Stamp pending_op and the new local_path. The local file
        // already lives at ``pair.to`` on disk; matching state.db
        // before the cloud call means a crash here resumes
        // correctly via Reconcile's pending_rename pass.
        var updated = doc
        updated.localPath = pair.to
        updated.pendingOp = "pending_rename"
        try await state.upsert(updated)

        do {
            try await cloud.mv(from: doc.remotePath, to: newRemote)
        } catch {
            Logger.shared.error(
                "renameRemote: cloud mv failed; pending_op left set for retry",
                meta: [
                    "doc_id": doc.docID,
                    "from": doc.remotePath,
                    "to": newRemote,
                    "error": "\(error)",
                ]
            )
            return
        }

        var done = updated
        done.remotePath = newRemote
        done.pendingOp = nil
        try await state.upsert(done)

        Logger.shared.info(
            "rename: cloud mv complete",
            meta: [
                "doc_id": doc.docID,
                "from": doc.remotePath,
                "to": newRemote,
            ]
        )
    }

    /// Apply a cloud-detected rename to the local tree. Job hint
    /// is ``"<oldRemote>\t<newRemote>"``. Steps:
    ///   1. Decode hint; resolve doc by docID.
    ///   2. Compute old + new local paths via ``Paths.remoteToLocal``.
    ///   3. Per-doc lock.
    ///   4. **Seed the echo fence on the new local path FIRST.**
    ///      Otherwise the watcher's ``.itemRenamed`` /
    ///      ``IN_MOVED_TO`` event for our own move bounces back
    ///      through the rename pairer and we ship a spurious
    ///      ``.renameRemote`` job → infinite loop. The fence is
    ///      load-bearing safety here.
    ///   5. ``FileManager.moveItem`` from old local to new local.
    ///      If the old file isn't there (user already renamed it
    ///      themselves, then the cloud caught up) we just stamp
    ///      the new path and move on.
    ///   6. Update ``local_path`` and ``remote_path`` in state.db.
    private func renameOnLocal(_ job: Job) async throws {
        guard cfg.deletion.enablePropagation else {
            Logger.shared.debug(
                "rename propagation disabled; ignoring renameLocal",
                meta: ["hint": job.hint]
            )
            return
        }
        guard let docID = job.docID else {
            Logger.shared.warn(
                "renameLocal: missing doc_id",
                meta: ["hint": job.hint]
            )
            return
        }
        guard let pair = RenameHint.decode(job.hint) else {
            Logger.shared.warn(
                "renameLocal: malformed hint",
                meta: ["hint": job.hint]
            )
            return
        }
        guard let doc = try await state.get(docID: docID) else {
            Logger.shared.info(
                "renameLocal ignored: no state row",
                meta: ["doc_id": docID]
            )
            return
        }

        let token = await locks.acquire(docID)
        defer { Task { await token.release() } }

        let oldLocal = URL(fileURLWithPath: doc.localPath)
        let newLocal = PathUtilities.remoteToLocal(
            remotePath: pair.to,
            syncDir: cfg.syncDir,
            remoteFolder: cfg.remoteFolder
        )

        // Seed the echo fence BEFORE the move so the watcher's
        // event for our own write is suppressed. Mark BOTH the
        // destination and (for the FSEvents path that fires on
        // the source endpoint) the origin — the rename pairer
        // would otherwise see a "from" half it can't match.
        await fence.mark(newLocal.path)
        await fence.mark(oldLocal.path)

        let fm = FileManager.default
        if fm.fileExists(atPath: oldLocal.path) {
            // Make sure the destination directory exists. Cross-
            // folder cloud renames legitimately land in a parent
            // that doesn't yet exist locally.
            try? fm.createDirectory(
                at: newLocal.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            do {
                try fm.moveItem(at: oldLocal, to: newLocal)
            } catch {
                Logger.shared.error(
                    "renameLocal: filesystem move failed",
                    meta: [
                        "doc_id": docID,
                        "from": oldLocal.path,
                        "to": newLocal.path,
                        "error": "\(error)",
                    ]
                )
                return
            }
        } else {
            Logger.shared.debug(
                "renameLocal: source absent; updating state only",
                meta: ["doc_id": docID, "from": oldLocal.path]
            )
        }

        var updated = doc
        updated.localPath = newLocal.path
        updated.remotePath = pair.to
        updated.pendingOp = nil
        try await state.upsert(updated)

        Logger.shared.info(
            "rename: local mv complete",
            meta: [
                "doc_id": docID,
                "from": oldLocal.path,
                "to": newLocal.path,
                "remote": pair.to,
            ]
        )
    }

    // MARK: - delete propagation

    /// Handle a watcher-emitted ``.deleteLocal``. The local file may
    /// or may not still exist — if a user re-creates the same path
    /// before the worker fires, treat that as a no-op. Otherwise:
    ///
    ///   1. Resolve the doc via state.db (job.docID OR by local path).
    ///   2. Acquire the per-doc lock so we serialise against any
    ///      in-flight push for the same document.
    ///   3. Consult the bulk-delete brake. Trip → refuse + park
    ///      ``error_state = "bulk_delete_refused"``.
    ///   4. Move the local file into trash (if it's still there).
    ///   5. Stamp ``pending_op = "pending_delete"`` so a crash here
    ///      can be resumed by ``Reconcile`` on next startup.
    ///   6. Cloud-stat to confirm the doc still exists, then
    ///      ``Cloud.rm`` (which moves to cloud trash, not a hard
    ///      delete).
    ///   7. Drop the state.db row.
    ///
    /// Every step is logged so an operator can diff progress against
    /// ``rmsync status`` after a partial failure.
    private func deleteLocalAndCloud(_ job: Job) async throws {
        guard cfg.deletion.enablePropagation else {
            Logger.shared.debug(
                "delete propagation disabled; ignoring deleteLocal",
                meta: ["hint": job.hint, "doc_id": job.docID ?? ""]
            )
            return
        }

        // Resolve the doc. The watcher has the local path; the cloud
        // poller has the docID. Either is sufficient.
        let stored: Document?
        if let id = job.docID {
            stored = try await state.get(docID: id)
        } else {
            stored = try await state.byLocalPath(job.hint)
        }
        guard let doc = stored else {
            Logger.shared.info(
                "deleteLocal ignored: no state row (untracked file)",
                meta: ["hint": job.hint, "doc_id": job.docID ?? ""]
            )
            return
        }

        let token = await locks.acquire(doc.docID)
        defer { Task { await token.release() } }

        // Bulk-delete brake.
        if let limiter, await !limiter.mayDelete(docID: doc.docID) {
            Logger.shared.error(
                "delete refused: bulk-delete brake tripped",
                meta: [
                    "doc_id": doc.docID,
                    "path": doc.localPath,
                    "remote": doc.remotePath,
                ]
            )
            try? await state.setError(docID: doc.docID, state: "bulk_delete_refused")
            return
        }

        // Soft-delete: park the local file into the trash. If it's
        // already gone (the cloud-delete-arriving-locally path) the
        // helper returns ``.sourceMissing`` and we proceed straight
        // to the cloud rm.
        let localURL = URL(fileURLWithPath: doc.localPath)
        let moveResult: Trash.MoveResult
        do {
            moveResult = try Trash.moveIn(localURL, syncDir: cfg.syncDir)
        } catch {
            Logger.shared.error(
                "delete aborted: trash move failed",
                meta: ["doc_id": doc.docID, "path": doc.localPath, "error": "\(error)"]
            )
            return
        }
        switch moveResult {
        case .moved(let stamp, _):
            Logger.shared.info(
                "delete: parked local in trash",
                meta: ["doc_id": doc.docID, "stamp": stamp, "path": doc.localPath]
            )
        case .sourceMissing:
            Logger.shared.debug(
                "delete: local already missing",
                meta: ["doc_id": doc.docID, "path": doc.localPath]
            )
        case .alreadyTrashed(let stamp, _):
            Logger.shared.info(
                "delete: local already trashed",
                meta: ["doc_id": doc.docID, "stamp": stamp, "path": doc.localPath]
            )
        }

        try await runCloudDelete(for: doc)
    }

    /// Handle a startup-reconcile-emitted ``.deleteRemote`` (and the
    /// resume path for in-flight ``pending_delete`` rows). Skips
    /// the trash-move step — the local file is already gone, that's
    /// why we're here. Everything else mirrors ``.deleteLocal``.
    private func deleteRemote(_ job: Job) async throws {
        guard cfg.deletion.enablePropagation else {
            Logger.shared.debug(
                "delete propagation disabled; ignoring deleteRemote",
                meta: ["hint": job.hint, "doc_id": job.docID ?? ""]
            )
            return
        }

        guard let docID = job.docID,
              let doc = try await state.get(docID: docID) else {
            Logger.shared.warn(
                "deleteRemote ignored: no state row",
                meta: ["doc_id": job.docID ?? "", "hint": job.hint]
            )
            return
        }

        let token = await locks.acquire(doc.docID)
        defer { Task { await token.release() } }

        if let limiter, await !limiter.mayDelete(docID: doc.docID) {
            Logger.shared.error(
                "deleteRemote refused: bulk-delete brake tripped",
                meta: ["doc_id": doc.docID, "remote": doc.remotePath]
            )
            try? await state.setError(docID: doc.docID, state: "bulk_delete_refused")
            return
        }

        try await runCloudDelete(for: doc)
    }

    /// Common tail used by both delete handlers. Stamps
    /// ``pending_op``, calls ``Cloud.rm`` (after a defensive
    /// ``Cloud.stat`` to handle the "already gone" case), records
    /// the deletion in the limiter, and removes the state row.
    private func runCloudDelete(for doc: Document) async throws {
        try? await state.setPendingOp(docID: doc.docID, op: "pending_delete")

        let exists: Bool
        do {
            exists = try await cloud.stat(doc.remotePath) != nil
        } catch {
            Logger.shared.warn(
                "delete: cloud stat failed; assuming present",
                meta: ["doc_id": doc.docID, "remote": doc.remotePath, "error": "\(error)"]
            )
            exists = true
        }

        if exists {
            do {
                try await cloud.rm(doc.remotePath)
                Logger.shared.info(
                    "delete: cloud rm complete",
                    meta: ["doc_id": doc.docID, "remote": doc.remotePath]
                )
            } catch {
                Logger.shared.error(
                    "delete: cloud rm failed; pending_op left set for retry",
                    meta: ["doc_id": doc.docID, "remote": doc.remotePath, "error": "\(error)"]
                )
                return
            }
        } else {
            Logger.shared.info(
                "delete: cloud doc already gone; clearing local state",
                meta: ["doc_id": doc.docID, "remote": doc.remotePath]
            )
        }

        await limiter?.record(docID: doc.docID)
        try? await state.delete(docID: doc.docID)
    }

    // MARK: - push inbox

    /// Pushes a PDF / EPUB from the inbox directory to the configured
    /// ``inbox.remote_folder`` cloud path. Bypasses the Markdown
    /// pipeline entirely — no rmdoc archive, no state.db tracking,
    /// no page CRDT generation. ``rmapi put --force`` does the
    /// upload directly. On success we (by default) delete the
    /// local file so the inbox stays drainable.
    private func pushInbox(localPath: String) async throws {
        guard let inbox = cfg.inbox else {
            Logger.shared.warn("pushInbox job with no [inbox] config", meta: ["path": localPath])
            return
        }
        let url = URL(fileURLWithPath: localPath)
        guard FileManager.default.fileExists(atPath: localPath) else {
            // File vanished between watcher fire and worker pickup —
            // user moved it back out, or another consumer drained it.
            // Quiet log and bail.
            Logger.shared.debug("inbox file gone", meta: ["path": localPath])
            return
        }

        Logger.shared.info(
            "inbox push starting",
            meta: ["path": localPath, "remote": inbox.remoteFolder]
        )

        // rmapi accepts PDF and EPUB directly to ``put --force``; no
        // archive packing required. The cloud doc gets named after
        // the file's basename minus extension. Same path semantics
        // the macOS Send-to-reMarkable shortcut produces.
        do {
            try await cloud.putRaw(
                localPath: url,
                remoteFolder: inbox.remoteFolder
            )
        } catch {
            Logger.shared.error(
                "inbox push failed",
                meta: ["path": localPath, "error": "\(error)"]
            )
            return
        }

        if inbox.deleteAfterPush {
            do {
                try FileManager.default.removeItem(at: url)
                Logger.shared.info(
                    "inbox push complete; local removed",
                    meta: ["path": localPath]
                )
            } catch {
                Logger.shared.warn(
                    "inbox push complete; local removal failed",
                    meta: ["path": localPath, "error": "\(error)"]
                )
            }
        } else {
            Logger.shared.info("inbox push complete; local kept", meta: ["path": localPath])
        }
    }

    // MARK: - pull

    private func pull(docID: String, remotePath: String) async throws {
        let stored = try await state.get(docID: docID)
        let localPath: URL = stored.map { URL(fileURLWithPath: $0.localPath) }
            ?? PathUtilities.remoteToLocal(
                remotePath: remotePath,
                syncDir: cfg.syncDir,
                remoteFolder: cfg.remoteFolder
            )
        guard PathUtilities.resolvedRelativePath(from: cfg.syncDir, to: localPath) != nil else {
            Logger.shared.warn(
                "pull skipped: local path escapes sync_dir",
                meta: ["doc_id": docID, "path": localPath.path]
            )
            return
        }

        // Respect outstanding conflicts.
        if stored?.conflictState == "unresolved",
           Conflict.hasUnresolvedConflictFile(at: localPath) {
            Logger.shared.info(
                "pull skipped: unresolved conflict",
                meta: ["doc_id": docID]
            )
            return
        }

        // rmapi get into a tempdir. Parse pages in-process via RMScene.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmsync-pull-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let archive: URL
        do {
            archive = try await cloud.get(remotePath, dest: tmpDir)
        } catch {
            Logger.shared.error(
                "rmapi get failed",
                meta: ["doc_id": docID, "error": "\(error)"]
            )
            return
        }

        let rmdoc: Archive.RmDoc
        do {
            rmdoc = try await Archive.unpack(archive)
        } catch {
            Logger.shared.error(
                "rmdoc unpack failed",
                meta: ["doc_id": docID, "error": "\(error)"]
            )
            if stored != nil {
                try? await state.setError(docID: docID, state: "parse_failed")
            }
            return
        }

        var pagesMd: [String] = []
        pagesMd.reserveCapacity(rmdoc.pages.count)
        for page in rmdoc.pages {
            do {
                let text = try PageCodec.parsePage(page.rmBytes)
                pagesMd.append(text)
            } catch {
                Logger.shared.error(
                    "page parse failed; parking doc",
                    meta: ["doc_id": docID, "page_id": page.pageID, "error": "\(error)"]
                )
                if stored != nil {
                    try? await state.setError(docID: docID, state: "parse_failed")
                }
                return
            }
        }

        // Diagnostic: correlate pushed vs pulled bytes per page so we can
        // tell whether empty-parse results are a decoder bug, a rmapi /
        // cloud re-serialisation, or a tablet-side edit. Paired with the
        // "push page encoded" log on the push path.
        //
        // Log level gets promoted to ``warn`` when *any* page parses to
        // empty — that's the actionable signature of the attacks.md
        // class of bugs. Default ``debug`` for the normal case keeps
        // the log quiet on healthy pulls. We checked hypothesis D
        // (rmapi/cloud re-serialisation) empirically via the
        // ``rmapiByteFidelity`` live test on 2026-04-20: the cloud is
        // byte-faithful, so every empty_parse_count > 0 is either a
        // tablet-side edit that flipped typed text to handwriting
        // (hypothesis C — expected, defended against in the Bug 1
        // guard below) or a decoder bug on a specific input shape
        // (hypothesis A — actionable, fix in-tree).
        let emptyCount = pagesMd.filter { $0.isEmpty }.count
        let meta: [String: String] = [
            "doc_id": docID,
            "page_count": "\(rmdoc.pages.count)",
            "empty_parse_count": "\(emptyCount)",
            "total_rm_bytes": "\(rmdoc.pages.reduce(0) { $0 + $1.rmBytes.count })",
            "page_ids": rmdoc.pages.map(\.pageID).joined(separator: ","),
            "per_page_rm_sha256": rmdoc.pages
                .map { PathUtilities.sha256(bytes: $0.rmBytes) }
                .joined(separator: ",")
        ]
        if emptyCount > 0 {
            Logger.shared.warn("pull page parse report", meta: meta)
        } else {
            Logger.shared.debug("pull page parse report", meta: meta)
        }

        // Bug 1 guard — PageCodec.parsePage returns "" for handwriting-only
        // and drawing pages (see PageCodec.swift:28-30), and the contract
        // says the pull path should treat that as "skip". Prior behaviour
        // appended the empty string and PageSplitter.join then turned a
        // single-empty-page doc into a lone "\n", silently wiping the
        // user's local file. Refuse to overwrite when *every* page parsed
        // empty; surface a warning so the event is visible in logs.
        if !rmdoc.pages.isEmpty, emptyCount == rmdoc.pages.count {
            Logger.shared.warn(
                "pull refused: remote parsed to empty on every page (possible data-loss guard)",
                meta: [
                    "doc_id": docID,
                    "path": localPath.path,
                    "page_count": "\(rmdoc.pages.count)"
                ]
            )
            return
        }
        // Drop empty pages (handwriting-only / drawing) before join so
        // they don't contribute a blank section to the rendered markdown.
        let nonEmpty = pagesMd.filter { !$0.isEmpty }
        let newMD = nonEmpty.isEmpty ? "" : PageSplitter.join(nonEmpty)
        let newHash = PathUtilities.sha256(newMD)

        // Short-circuit: content hasn't changed since we last synced.
        if stored?.lastSyncedMDHash == newHash {
            Logger.shared.debug("pull no-op (hash unchanged)", meta: ["doc_id": docID])
            return
        }

        // If local exists and has been edited since last sync, it's a conflict.
        var localChanged = false
        if FileManager.default.fileExists(atPath: localPath.path),
           let stored = stored,
           let lastHash = stored.lastSyncedMDHash,
           let currentHash = try? PathUtilities.sha256File(localPath),
           currentHash != lastHash {
            localChanged = true
        }

        // Bug 2 guard — remote shrank catastrophically since our last
        // sync. Even after Bug 1's empty-page filter, a partial regression
        // could still hand us (say) 20 bytes of markdown to replace 10 KB
        // of user content. Treat that like a local-diverged conflict
        // rather than silently overwriting: write a ``.conflict`` file,
        // notify, and let the user pick a side. Thresholds are tuned to
        // skip genuinely short notes (``lastBytes >= shrinkMinPrev``) and
        // only trigger on a clearly pathological ratio (<10% of previous).
        // We use the local file's on-disk size as a proxy for "what we
        // last synced" — safe because ``!localChanged`` means the file
        // still matches ``lastSyncedMDHash``.
        let shrinkMinPrev = 64
        let shrinkMaxRatio = 0.1
        var remoteShrank = false
        if !localChanged,
           stored?.lastSyncedMDHash != nil,
           let attrs = try? FileManager.default.attributesOfItem(atPath: localPath.path),
           let lastBytes = (attrs[.size] as? NSNumber)?.intValue,
           lastBytes >= shrinkMinPrev,
           Double(newMD.utf8.count) / Double(lastBytes) < shrinkMaxRatio {
            remoteShrank = true
        }

        if localChanged || remoteShrank {
            let localText = (try? String(contentsOf: localPath, encoding: .utf8)) ?? ""
            _ = try Conflict.write(md: localPath, local: localText, remote: newMD)
            try await state.setConflict(docID: docID, state: "unresolved")
            Logger.shared.warn(
                "conflict written",
                meta: [
                    "doc_id": docID,
                    "path": localPath.path,
                    "reason": remoteShrank && !localChanged
                        ? "remote_shrank_catastrophically"
                        : "local_diverged",
                    "new_bytes": "\(newMD.utf8.count)"
                ]
            )
            // Surface the conflict in Notification Center — otherwise it
            // silently lives in a .conflict file the user never checks.
            Notifications.notifyConflict(
                docTitle: rmdoc.visibleName.isEmpty
                    ? localPath.deletingPathExtension().lastPathComponent
                    : rmdoc.visibleName,
                localPath: localPath
            )
            return
        }

        // Capture cloud-assigned ModifiedClient for stable change detection.
        let statResult = try? await cloud.stat(remotePath)
        let remoteModified = statResult?.modifiedClient ?? ""

        // Snapshot the about-to-be-clobbered local content for
        // tracked docs. This is the "daemon just overwrote my
        // edit on a remote pull, gimme the previous version
        // back" recovery path. We only snapshot when the local
        // file actually exists — first-pull lands new content
        // with no predecessor to capture. Best-effort; never
        // blocks the pull on snapshot I/O.
        if stored != nil,
           FileManager.default.fileExists(atPath: localPath.path),
           let oldText = try? String(contentsOf: localPath, encoding: .utf8) {
            do {
                _ = try Snapshots.take(
                    content: oldText,
                    docID: docID,
                    cause: Snapshots.Cause.pullOverwrite,
                    in: Paths.stateDir
                )
                _ = try Snapshots.prune(
                    docID: docID,
                    keep: cfg.backupSnapshotsToKeep,
                    in: Paths.stateDir
                )
            } catch {
                Logger.shared.warn(
                    "snapshot on pull failed; proceeding",
                    meta: ["doc_id": docID, "error": "\(error)"]
                )
            }
        }

        // Write atomically + stamp the echo fence before the watcher
        // observes the write.
        await fence.mark(localPath.path)
        try PathUtilities.atomicWriteText(newMD, to: localPath)

        // Apply xattrs so Finder / Spotlight show the file as coming
        // from the reMarkable cloud. Best-effort; failures are logged
        // at debug level only.
        Xattrs.apply(
            Xattrs.FileMetadata(
                docID: docID,
                remotePath: remotePath,
                remoteModified: remoteModified,
                pageIDs: rmdoc.pages.map(\.pageID)
            ),
            to: localPath
        )

        let doc = Document(
            docID: docID,
            parentID: stored?.parentID ?? "",
            docType: "DocumentType",
            remotePath: remotePath,
            localPath: localPath.path,
            remoteVersion: rmdoc.version,
            remoteModified: remoteModified,
            lastSyncedMDHash: newHash,
            lastPullAt: nil,
            lastPushAt: stored?.lastPushAt,
            conflictState: nil,
            errorState: nil,
            pageIDs: rmdoc.pages.map(\.pageID)
        )
        try await state.upsert(doc)
        try await state.markPulled(
            docID: docID,
            version: rmdoc.version,
            mdHash: newHash,
            modified: remoteModified
        )
        Logger.shared.info(
            "pulled", meta: ["doc_id": docID, "path": localPath.path]
        )
    }

    // MARK: - push

    /// Push a local ``.md`` up to the reMarkable cloud. Mirrors
    /// ``src/rm_sync/worker.py:_push`` and the ``_do_push`` it delegates
    /// to. The function is long because the six invariants it enforces
    /// are all load-bearing; see inline comments and CHANGES_FROM_SPEC.md
    /// for why each guard exists.
    private func push(_ job: Job) async throws {
        let localPath = URL(fileURLWithPath: job.hint)
        if !FileManager.default.fileExists(atPath: localPath.path) {
            Logger.shared.debug("push ignored: file gone", meta: ["path": localPath.path])
            return
        }

        // Guard: push only from ``sync_dir`` (not its subdirs or from a
        // stray location). A file at ``sync_dir/Writing/foo.md`` is
        // almost always residue from an earlier buggy pull; pushing it
        // would clone the whole Writing tree into a nested phantom.
        guard let rel = relativePath(from: cfg.syncDir, to: localPath) else {
            Logger.shared.warn(
                "push refused: path not in sync_dir",
                meta: ["path": localPath.path]
            )
            return
        }
        if rel.components.contains(where: { $0.hasPrefix(".") }) {
            return  // hidden dir like .rmsync-trash
        }

        if await fence.isRecent(localPath.path) {
            Logger.shared.debug("push echo-suppressed", meta: ["path": localPath.path])
            return
        }

        let stored = try await state.byLocalPath(localPath.path)

        // Cascade guard: a .md file whose stem is a UUID and which has no
        // state row is almost certainly the tail of an old bug. Users
        // never name a note like ``abc12345-...``.
        if stored == nil, looksLikeUUID(localPath.deletingPathExtension().lastPathComponent) {
            Logger.shared.warn(
                "push refused: new doc with UUID-like name (cascade guard)",
                meta: ["stem": localPath.deletingPathExtension().lastPathComponent]
            )
            return
        }

        // Unresolved conflict: if the ``.conflict`` file is still present
        // we skip. If the user deleted it, clear the state row and push
        // the live content.
        if stored?.conflictState == "unresolved" {
            if Conflict.hasUnresolvedConflictFile(at: localPath) {
                Logger.shared.info(
                    "push skipped: unresolved conflict",
                    meta: ["doc_id": stored?.docID ?? ""]
                )
                return
            }
            if let storedDoc = stored {
                try await state.setConflict(docID: storedDoc.docID, state: nil)
            }
        }

        let lockKey = stored?.docID ?? "new:\(localPath.path)"
        let token = await locks.acquire(lockKey)
        defer { Task { await token.release() } }
        try await doPush(localPath: localPath, stored: stored, force: job.force)
    }

    private func doPush(
        localPath: URL, stored: Document?, force: Bool = false
    ) async throws {
        let text = (try? String(contentsOf: localPath, encoding: .utf8)) ?? ""
        let newHash = PathUtilities.sha256(text)

        if !force, let stored, stored.lastSyncedMDHash == newHash {
            // v0.2.26: ``force`` skips this short-circuit. Used by
            // ``rmsync retry-parked`` to retry a doc whose push
            // previously errored even though the on-disk hash
            // matches what we last claimed to sync — the parked
            // row's hash was set at the failed push attempt, so
            // the file content didn't actually reach the cloud.
            Logger.shared.debug(
                "push no-op (hash unchanged)",
                meta: ["doc_id": stored.docID]
            )
            return
        }

        // Snapshot the about-to-be-pushed bytes for tracked docs.
        // Skipped on first-push (stored == nil): brand-new files
        // have no prior history to capture, and the doc-id isn't
        // known until the cloud put completes anyway. Snapshots
        // are best-effort — never block the push on snapshot
        // I/O. Pruning runs in the same step so the on-disk count
        // stays at cfg.backupSnapshotsToKeep.
        if let stored {
            do {
                _ = try Snapshots.take(
                    content: text,
                    docID: stored.docID,
                    cause: Snapshots.Cause.push,
                    in: Paths.stateDir
                )
                _ = try Snapshots.prune(
                    docID: stored.docID,
                    keep: cfg.backupSnapshotsToKeep,
                    in: Paths.stateDir
                )
            } catch {
                Logger.shared.warn(
                    "snapshot on push failed; proceeding",
                    meta: ["doc_id": stored.docID, "error": "\(error)"]
                )
            }
        }

        // Cloud-provider-eviction guard — a macOS File Provider (Dropbox,
        // iCloud, OneDrive, Google Drive, Box) can demote a local file
        // to a dataless placeholder when disk is tight, even if the
        // user has ticked "Always keep on this device". The placeholder
        // keeps the logical size in stat() but has zero physical blocks
        // allocated. ``String(contentsOf:)`` then returns empty bytes
        // without surfacing a proper I/O error — which our hash-and-
        // push pipeline would happily propagate to the reMarkable
        // cloud, wiping the doc.
        //
        // Two-layer detection, both have to vote "empty" for us to
        // refuse:
        //
        //   Layer 1 (precise, provider-agnostic): FileProvider.status()
        //     reads stat() and reports ``.dataless`` when
        //     ``st_size > 0 && st_blocks == 0`` — the APFS signature
        //     of a placeholder file whose bytes were demoted. This
        //     is the authoritative signal; it distinguishes evicted
        //     files from genuinely-empty ones with no ambiguity.
        //
        //   Layer 2 (text-read sanity): even if stat() somehow lies
        //     (exotic filesystem, racing eviction), if the in-memory
        //     text trims empty AND we previously synced non-empty
        //     content for this doc, the push would destroy data. So
        //     we fall back to refusing on that basis too.
        //
        // The two layers converge on the same "refuse the push"
        // decision but produce different log / notification text so
        // the user can tell whether this was a provider eviction
        // (self-healing) or something weirder (investigate).
        //
        // We intentionally do NOT write a ``.conflict`` file or mutate
        // ``conflictState`` — see v0.2.8 for the reasoning (there's
        // nothing to merge; the case self-resolves when the provider
        // re-materialises the bytes).
        let providerStatus = FileProvider.status(of: localPath)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let previouslyNonEmpty = stored?.lastSyncedMDHash.map { !$0.isEmpty && $0 != PathUtilities.sha256("") } ?? false

        if providerStatus.isDataless, let stored {
            // Authoritative path: APFS + stat() are unambiguous.
            let providerName: String
            if case .dataless(_, let p) = providerStatus {
                providerName = p?.rawValue ?? "your cloud-storage provider"
            } else {
                providerName = "your cloud-storage provider"
            }
            Logger.shared.warn(
                "push refused: local file is a dataless placeholder (cloud-provider eviction confirmed via stat)",
                meta: [
                    "doc_id": stored.docID,
                    "path": localPath.path,
                    "detected_provider": providerName,
                    "logical_size": {
                        if case .dataless(let size, _) = providerStatus { return "\(size)" }
                        return "?"
                    }()
                ]
            )
            let docTitle = localPath.deletingPathExtension().lastPathComponent
            Notifications.notify(
                title: "rmsync: push skipped",
                body: "\(docTitle) has been demoted to online-only by \(providerName). " +
                      "The cloud copy is untouched. Open the file in Finder to re-download it.",
                subtitle: localPath.deletingLastPathComponent().path
            )
            return
        }

        if trimmed.isEmpty, previouslyNonEmpty, let stored {
            // Fallback path: stat didn't give a clear dataless signal,
            // but the read came back empty against a doc we know used
            // to have content. Rare but worth catching.
            Logger.shared.warn(
                "push refused: local reads empty but previously synced non-empty (possible provider eviction, stat check inconclusive)",
                meta: [
                    "doc_id": stored.docID,
                    "path": localPath.path,
                    "bytes_on_disk": "\(text.utf8.count)",
                    "prev_hash": stored.lastSyncedMDHash ?? ""
                ]
            )
            let docTitle = localPath.deletingPathExtension().lastPathComponent
            Notifications.notify(
                title: "rmsync: push skipped",
                body: "\(docTitle) read as empty but was previously non-empty. " +
                      "The cloud copy is untouched. Open the file to verify; if this " +
                      "persists, see the README's 'Cloud-storage sync folders' section.",
                subtitle: localPath.deletingLastPathComponent().path
            )
            return
        }

        // Persistent author UUID — same across every push from this
        // install, to keep the tablet's CRDT engine treating our writes
        // as "same author updating its own item" rather than a
        // character-by-character merge.
        let authorUUID = try await state.getOrCreateAuthorUUID()

        let pagesMd = PageSplitter.split(text)
        var pageBytes: [Data] = []
        pageBytes.reserveCapacity(pagesMd.count)
        switch cfg.pushStrategy {
        case .nativePlain:
            for pageText in pagesMd {
                let rmBytes = try PageCodec.renderPage(
                    text: pageText, authorUUID: authorUUID
                )
                pageBytes.append(rmBytes)
            }
        case .nativeFormatted:
            Logger.shared.error(
                "native_formatted push strategy not yet implemented",
                meta: ["doc_id": stored?.docID ?? "new"]
            )
            return
        case .pdf:
            Logger.shared.warn("pdf push not yet wired into worker")
            return
        }

        // Reuse page UUIDs for stable sync15 cPages. Extra pages get
        // fresh UUIDs; if the doc shrinks, the tail IDs are dropped from
        // the next state write.
        let reuseIDs: [String] = stored?.pageIDs ?? []
        var pageIDs: [String] = []
        for i in 0..<pageBytes.count {
            if i < reuseIDs.count {
                pageIDs.append(reuseIDs[i])
            } else {
                pageIDs.append(Archive.newPageID())
            }
        }

        let docID = stored?.docID ?? UUID().uuidString.lowercased()
        let rmDocPages = zip(pageIDs, pageBytes).map { (pid, bytes) in
            Archive.RmDocPage(pageID: pid, rmBytes: bytes)
        }
        let nextVersion = (stored?.remoteVersion ?? 0) + 1

        // Diagnostic: per-page SHA256 of the bytes we're about to put.
        // Pairs with "pull page parse report" so we can see whether bytes
        // survive the rmapi / cloud round-trip unchanged. Author UUID is
        // truncated to the first 8 chars so UUID drift across daemon
        // restarts is visible without leaking the full identity.
        for (i, bytes) in pageBytes.enumerated() {
            Logger.shared.debug(
                "push page encoded",
                meta: [
                    "doc_id": docID,
                    "page_index": "\(i)",
                    "page_id": pageIDs[i],
                    "author_uuid_prefix": String(authorUUID.prefix(8)),
                    "rm_bytes_len": "\(bytes.count)",
                    "rm_sha256": PathUtilities.sha256(bytes: bytes),
                    "input_md_len": "\(pagesMd[i].utf8.count)",
                    "input_md_sha256": PathUtilities.sha256(pagesMd[i])
                ]
            )
        }

        // rmapi v0.0.32 names the cloud doc after the .rmdoc filename,
        // not the ``visibleName`` inside the archive. So pack the file
        // with the local stem — packing by ``doc_id`` spawns
        // UUID-named cloud phantoms. The local file is the WYSIWYG
        // source of truth (v0.2.27+ filename round-trip), so reading
        // the stem here means a rename always lands the next push at
        // the new name — no cached field to drift.
        let visible = localPath.deletingPathExtension().lastPathComponent

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmsync-push-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let outArchive = tmpDir.appendingPathComponent("\(visible).rmdoc")

        _ = try await Archive.pack(
            Archive.RmDoc(
                docID: docID,
                visibleName: visible,
                parent: "",
                pages: rmDocPages,
                version: nextVersion,
                lastModified: Int64(Date().timeIntervalSince1970 * 1000)
            ),
            to: outArchive
        )

        let remoteParent: String
        if let stored, let lastSlash = stored.remotePath.lastIndex(of: "/") {
            // Existing tracked doc: keep its current parent. Local
            // moves are handled by the rename pipeline (Phase 4
            // of the v0.2.19 propagation work).
            remoteParent = String(stored.remotePath[..<lastSlash])
            // v0.2.26 bugfix: a doc parked from a prior failed
            // push (v0.2.23+) carries an optimistic
            // ``stored.remotePath`` that promises a cloud
            // location whose intermediate folders may never
            // have been actually created. Phase A only ran the
            // mkdir chain for ``stored == nil`` — so retries
            // skipped it and put() failed with "directory
            // doesn't exist". Defensive-mkdir each prefix here
            // too. Cheap (rmapi mkdir errors on existing dirs
            // and we swallow with try?), idempotent.
            for prefix in PathUtilities.remoteParentPrefixes(remoteParent) {
                try? await cloud.mkdir(prefix)
            }
        } else {
            // New doc: derive remoteParent from the local file's
            // position under sync_dir so subdirectory structure
            // propagates to the cloud. Each prefix in the chain
            // gets a defensive mkdir; rmapi's mkdir errors when
            // the folder already exists, so we swallow with
            // ``try?`` — the goal is "ensure exists", not "create
            // fresh".
            let derivation = PathUtilities.localToRemoteParentChain(
                localPath: localPath,
                syncDir: cfg.syncDir,
                remoteFolder: cfg.remoteFolder
            )
            for prefix in derivation.mkdirChain {
                try? await cloud.mkdir(prefix)
            }
            remoteParent = derivation.parentPath
        }

        do {
            try await cloud.put(
                local: outArchive,
                remoteParent: remoteParent,
                update: stored != nil
            )
        } catch {
            Logger.shared.error(
                "rmapi put failed",
                meta: ["doc_id": docID, "error": "\(error)"]
            )
            // v0.2.29 — classify the failure from the error
            // string itself. v0.2.25 ran a separate ``rmapi
            // mkdir`` canary against a sentinel path, which left
            // ``.rmsync-health-<uuid>`` cruft on the cloud
            // whenever the cleanup ``rmapi rm`` couldn't clean
            // up. The current push error already tells us what
            // we need (auth/missing/compat-break/unknown); no
            // extra cloud writes.
            if let bus {
                await CloudHealthProbe.classifyAndPublish(error, on: bus)
            }
            // Park the failure in state.db so the next reconcile
            // pass doesn't re-enqueue this push on every daemon
            // restart. Two distinct paths:
            //
            //   * stored == nil — a brand-new file's first push
            //     failed. Without this row, the file remains
            //     "untracked" and Reconcile.localCreatesAndEdits
            //     re-enqueues it on every startup → infinite
            //     retry loop on a permanent failure (e.g. rmapi
            //     400 from a duplicate-name collision). Insert
            //     the row with lastSyncedMDHash = the bytes we
            //     just tried to push, so reconcile's
            //     ``hash != currentHash`` gate stays false until
            //     the user actually edits the file again.
            //
            //   * stored != nil — an existing tracked doc's
            //     update failed. Stamp error_state on the
            //     existing row; lastSyncedMDHash unchanged so
            //     the next user edit (different hash) re-enqueues
            //     and retries.
            //
            // Either way, ``error_state = "push_failed"`` shows
            // up in ``rmsync status`` (parked errors count) and
            // the web dashboard so the user sees the failure
            // instead of the daemon silently retrying forever.
            // ``markPushed`` will clear it on the first
            // successful retry.
            if stored == nil {
                let parked = Document(
                    docID: docID,
                    parentID: "",
                    docType: "DocumentType",
                    remotePath: "\(remoteParent)/\(visible)",
                    localPath: localPath.path,
                    remoteVersion: 0,                 // never reached cloud
                    lastSyncedMDHash: newHash,
                    errorState: "push_failed",
                    pageIDs: pageIDs
                )
                try? await state.upsert(parked)
            } else if let stored {
                try? await state.setError(docID: stored.docID, state: "push_failed")
            }
            return
        }

        // Capture the cloud-assigned ModifiedClient so the next poller
        // cycle doesn't see this push as a remote change.
        let remoteDocPath = stored?.remotePath ?? "\(remoteParent)/\(visible)"
        let stat = try? await cloud.stat(remoteDocPath)
        let newModified = stat?.modifiedClient ?? ""

        if stored == nil {
            let fresh = Document(
                docID: docID,
                parentID: "",
                docType: "DocumentType",
                remotePath: remoteDocPath,
                localPath: localPath.path,
                remoteVersion: nextVersion,
                remoteModified: newModified,
                lastSyncedMDHash: newHash,
                pageIDs: pageIDs
            )
            try await state.upsert(fresh)
        } else {
            try await state.setPageIDs(docID: docID, pageIDs: pageIDs)
        }
        try await state.markPushed(
            docID: docID,
            version: nextVersion,
            mdHash: newHash,
            modified: newModified
        )
        // A successful push contradicts any prior "rmapi cloud
        // is broken" classification on the bus. Clear it so the
        // menubar's diagnostic UI flips back to green.
        if let bus { await CloudHealthProbe.clear(on: bus) }
        Logger.shared.info(
            "pushed",
            meta: ["doc_id": docID, "path": localPath.path]
        )
    }

    // MARK: - helpers

    private struct RelativePath { let components: [String] }

    private func relativePath(from base: URL, to target: URL) -> RelativePath? {
        guard let components = PathUtilities.resolvedRelativePath(from: base, to: target)
        else { return nil }
        return RelativePath(components: components)
    }

    private func looksLikeUUID(_ s: String) -> Bool {
        // 8-4-4-4-12 hex. Use a pattern rather than ``UUID(uuidString:)``
        // because we want the strict shape, not permissive parsing.
        let pattern = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/
        return s.wholeMatch(of: pattern) != nil
    }
}
