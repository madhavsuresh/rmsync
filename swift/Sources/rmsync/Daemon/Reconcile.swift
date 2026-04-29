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
    static func localDeletions(
        state: State, queue: JobQueue
    ) async throws {
        var enqueued = 0
        let docs = try await state.allDocuments()
        for doc in docs where doc.docType == "DocumentType" {
            guard let hash = doc.lastSyncedMDHash, !hash.isEmpty else { continue }
            if FileManager.default.fileExists(atPath: doc.localPath) { continue }
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
        if enqueued > 0 {
            Logger.shared.info(
                "startup deletion reconcile", meta: ["enqueued": "\(enqueued)"]
            )
        }
    }

    static func initialPull(
        cloud: Cloud, cfg: Config, queue: JobQueue
    ) async throws {
        Logger.shared.info("initial reconcile: walking remote tree")
        let nodes = try await cloud.tree("/\(cfg.remoteFolder)")
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
