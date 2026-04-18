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
    private var stopFlag = false

    init(
        id: Int,
        queue: JobQueue,
        cloud: Cloud,
        state: State,
        cfg: Config,
        locks: LockRegistry,
        fence: EchoFence
    ) {
        self.id = id
        self.queue = queue
        self.cloud = cloud
        self.state = state
        self.cfg = cfg
        self.locks = locks
        self.fence = fence
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

        case .deleteLocal, .deleteRemote, .renameRemote:
            // Week 6 territory (delete semantics) and Week 6's rename
            // detection. For now we ack by logging and moving on.
            Logger.shared.debug(
                "job kind not yet implemented",
                meta: ["kind": job.kind.rawValue, "hint": job.hint]
            )
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

        let newMD = pagesMd.isEmpty ? "" : PageSplitter.join(pagesMd)
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

        if localChanged {
            let localText = (try? String(contentsOf: localPath, encoding: .utf8)) ?? ""
            _ = try Conflict.write(md: localPath, local: localText, remote: newMD)
            try await state.setConflict(docID: docID, state: "unresolved")
            Logger.shared.warn(
                "conflict written",
                meta: ["doc_id": docID, "path": localPath.path]
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
            title: rmdoc.visibleName,
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
            return  // hidden dir like .rm-sync-trash
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
        try await doPush(localPath: localPath, stored: stored)
    }

    private func doPush(localPath: URL, stored: Document?) async throws {
        let text = (try? String(contentsOf: localPath, encoding: .utf8)) ?? ""
        let newHash = PathUtilities.sha256(text)

        if let stored, stored.lastSyncedMDHash == newHash {
            Logger.shared.debug(
                "push no-op (hash unchanged)",
                meta: ["doc_id": stored.docID]
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

        // rmapi v0.0.32 names the cloud doc after the .rmdoc filename,
        // not the ``visibleName`` inside the archive. So pack the file
        // with the visible/local stem — packing by ``doc_id`` spawns
        // UUID-named cloud phantoms.
        let visible = stored?.title.isEmpty == false
            ? stored!.title
            : localPath.deletingPathExtension().lastPathComponent

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

        let remoteParent: String = {
            if let stored, let lastSlash = stored.remotePath.lastIndex(of: "/") {
                return String(stored.remotePath[..<lastSlash])
            }
            return "/\(cfg.remoteFolder)"
        }()

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
                title: visible,
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
        Logger.shared.info(
            "pushed",
            meta: ["doc_id": docID, "path": localPath.path]
        )
    }

    // MARK: - helpers

    private struct RelativePath { let components: [String] }

    private func relativePath(from base: URL, to target: URL) -> RelativePath? {
        let baseComponents = base.standardizedFileURL.pathComponents
        let targetComponents = target.standardizedFileURL.pathComponents
        guard targetComponents.count > baseComponents.count,
              Array(targetComponents.prefix(baseComponents.count)) == baseComponents
        else { return nil }
        return RelativePath(components: Array(targetComponents.dropFirst(baseComponents.count)))
    }

    private func looksLikeUUID(_ s: String) -> Bool {
        // 8-4-4-4-12 hex. Use a pattern rather than ``UUID(uuidString:)``
        // because we want the strict shape, not permissive parsing.
        let pattern = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/
        return s.wholeMatch(of: pattern) != nil
    }
}
