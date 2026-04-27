import Foundation

/// Top-level daemon event loop — the real one, no longer a scaffold.
///
/// Startup sequence mirrors the Python ``_run`` in
/// ``src/rm_sync/daemon.py``:
///
///   1. Load config, open state DB (migrations apply).
///   2. Start IPC server so the CLI / menu bar can connect even during
///      the slow initial reconcile.
///   3. Start workers (using the initial-sync rmapi concurrency cap).
///   4. Reconcile local deletions (before pulling, so we don't re-pull
///      files the user deleted).
///   5. Initial pull of the entire Writing tree.
///   6. Reconcile local creates/edits (after the pull, so state is
///      current before we decide what looks "new").
///   7. Start watcher + poller for steady-state operation.
///   8. Park until SIGTERM.
enum DaemonScaffold {
    static func run() async throws {
        // First thing: announce we got off the ground. If the user's
        // log file is empty later, that means we crashed before this
        // line — almost always a config-load or filesystem permission
        // problem, NOT a sync issue. Without this line, an empty log
        // is ambiguous between "daemon never started" and "daemon
        // started but had nothing to say yet"; with it, the question
        // collapses to "is this line present?".
        Logger.shared.info("daemon starting", meta: [
            "pid": "\(getpid())",
            "version": Version.current,
            "executable": Bundle.main.executablePath ?? "(unknown)",
        ])

        let cfg: Config
        do {
            cfg = try Config.load()
        } catch {
            // Surface the config error explicitly. Without this, the
            // daemon dies and the user sees a launchd auto-restart
            // loop in stderr.log without a clear cause.
            Logger.shared.error("config load failed; daemon exiting", meta: [
                "error": "\(error)",
                "expected_path": Paths.configPath.path,
            ])
            throw error
        }
        Logger.shared.info("config loaded", meta: [
            "sync_dir": cfg.syncDir.path,
            "remote_folder": cfg.remoteFolder,
        ])

        try FileManager.default.createDirectory(
            at: cfg.syncDir, withIntermediateDirectories: true
        )
        // Idempotent — no-op after the first successful install.
        FolderIcon.ensure(folder: cfg.syncDir)

        let state = try State(path: Paths.stateDBPath)
        let bus = StateBus()
        let queue = JobQueue()
        let fence = EchoFence(windowSeconds: cfg.echoFenceSeconds)
        let locks = LockRegistry()

        // Initial-sync rmapi gets capped concurrency so we don't stack
        // our worker pool × RMAPI_CONCURRENT during the big pull.
        let initialCloud = Cloud(concurrentOverride: 5)
        let steadyCloud = Cloud()

        // Workers come up first so they're ready to drain the queue as
        // soon as the reconciliation step enqueues jobs.
        var workers: [SyncWorker] = []
        for i in 0..<cfg.workerPoolSize {
            workers.append(SyncWorker(
                id: i, queue: queue, cloud: initialCloud, state: state,
                cfg: cfg, locks: locks, fence: fence
            ))
        }
        let workerTasks = workers.map { worker in
            Task.detached { await worker.run() }
        }

        do { try await steadyCloud.checkVersion() } catch {
            Logger.shared.warn(
                "rmapi version check failed", meta: ["error": "\(error)"]
            )
        }

        try await refreshBus(bus: bus, state: state, cfg: cfg, queue: queue)

        // Poller is needed before IPC so the ``sync_now`` command can
        // poke the real poller's force-cycle event.
        let poller = CloudPoller(
            cloud: steadyCloud, state: state, cfg: cfg, queue: queue
        )

        // IPC server accepts pause/resume/sync_now/get_status. Matches
        // the Python daemon's protocol byte-for-byte.
        let server = IPCServer(socketPath: Paths.ipcSocketPath, bus: bus)
        await server.register("pause") { _ in
            try? await state.setPaused(true)
            try? await refreshBus(bus: bus, state: state, cfg: cfg, queue: queue)
            return SendableJSON.dict([:])
        }
        await server.register("resume") { _ in
            try? await state.setPaused(false)
            try? await refreshBus(bus: bus, state: state, cfg: cfg, queue: queue)
            return SendableJSON.dict([:])
        }
        await server.register("sync_now") { _ in
            await poller.requestCycle()
            return SendableJSON.dict([:])
        }
        await server.register("get_status") { _ in
            let snap = await bus.snapshot()
            return Self.snapshotFrame(snap)
        }
        try await server.start()
        Logger.shared.info(
            "ipc server listening",
            meta: ["path": Paths.ipcSocketPath.path]
        )

        // Reconcile: deletions → initial pull → local creates/edits.
        do {
            try await Reconcile.localDeletions(state: state, queue: queue)
            await queue.waitUntilEmpty()
            try await Reconcile.initialPull(cloud: initialCloud, cfg: cfg, queue: queue)
            try await Reconcile.localCreatesAndEdits(
                state: state, cfg: cfg, queue: queue
            )
            await queue.waitUntilEmpty()
        } catch {
            Logger.shared.error(
                "initial reconcile failed; continuing into steady state",
                meta: ["error": "\(error)"]
            )
        }

        // Switch the workers over to the un-capped ``steadyCloud`` now
        // that the initial burst is done. Done by cancelling the old
        // workers and starting fresh ones pointed at ``steadyCloud``.
        for w in workers { await w.stop() }
        for t in workerTasks { _ = await t.value }
        workers.removeAll()
        var steadyTasks: [Task<Void, Never>] = []
        for i in 0..<cfg.workerPoolSize {
            let steady = SyncWorker(
                id: i, queue: queue, cloud: steadyCloud, state: state,
                cfg: cfg, locks: locks, fence: fence
            )
            workers.append(steady)
            steadyTasks.append(Task.detached { await steady.run() })
        }

        // Watcher and poller start only AFTER reconcile so they don't
        // observe the initial flurry of writes.
        let watcher = LocalWatcher(
            syncDir: cfg.syncDir,
            queue: queue,
            fence: fence,
            debounceSeconds: cfg.debounceSeconds
        )
        watcher.start()
        let pollerTask = Task.detached { await poller.run() }

        // Periodic bus refresh so the menu bar sees live counts even
        // during quiet stretches. Light touch — 5s tick.
        let busTask = Task.detached {
            while !Task.isCancelled {
                try? await refreshBus(bus: bus, state: state, cfg: cfg, queue: queue)
                try? await Task.sleep(for: .seconds(5))
            }
        }

        // Park until SIGTERM.
        let forever = AsyncStream<Never> { _ in }
        for await _ in forever {}

        // Orderly shutdown (unreached in practice — launchd SIGTERMs the
        // process, but kept for completeness).
        busTask.cancel()
        watcher.stop()
        await poller.stop()
        pollerTask.cancel()
        for w in workers { await w.stop() }
        for t in steadyTasks { _ = await t.value }
        await server.stop()
    }

    // MARK: - helpers (shared with the Week 2-era scaffold)

    static func refreshBus(
        bus: StateBus, state: State, cfg: Config, queue: JobQueue
    ) async throws {
        let docs = try await state.allDocuments()
        let tracked = docs.filter { $0.docType == "DocumentType" }.count

        // Reconcile any docs whose state.db says "unresolved" but whose
        // ``.conflict`` marker file on disk has since been deleted by
        // the user. Deleting the marker is the canonical "I resolved
        // this" gesture per the conflict workflow; previously the
        // state.db row was only cleared on the NEXT push of that doc,
        // which could be hours away and left the menubar stuck on
        // ``conflicts: N`` even after all ``.conflict`` files were
        // gone. Do it here so every status refresh self-heals.
        let unresolvedFromDB = docs.filter { $0.conflictState == "unresolved" }
        for doc in unresolvedFromDB {
            let path = URL(fileURLWithPath: doc.localPath)
            if !Conflict.hasUnresolvedConflictFile(at: path) {
                try? await state.setConflict(docID: doc.docID, state: nil)
                Logger.shared.info(
                    "auto-cleared conflict state (marker file deleted)",
                    meta: ["doc_id": doc.docID, "path": doc.localPath]
                )
            }
        }
        // Re-read after the reconciliation pass so the count matches
        // the post-cleanup state.
        let liveDocs = try await state.allDocuments()
        let conflicts = liveDocs.filter { $0.conflictState == "unresolved" }.count
        let errors = liveDocs.filter { $0.errorState != nil }.count
        let lastPull = liveDocs.compactMap(\.lastPullAt).max()
        let lastPush = liveDocs.compactMap(\.lastPushAt).max()
        let paused = try await state.isPaused()
        let queueDepth = await queue.size()

        await bus.update { s in
            s.state = paused ? "paused" : (queueDepth > 0 ? "syncing" : "idle")
            s.syncDir = cfg.syncDir.path
            s.remoteFolder = cfg.remoteFolder
            s.trackedDocs = tracked
            s.conflicts = conflicts
            s.errors = errors
            s.queueDepth = queueDepth
            s.lastPullAt = lastPull
            s.lastPushAt = lastPush
            s.paused = paused
            s.pid = Int(getpid())
            s.version = Version.current
        }
    }

    private static func snapshotFrame(_ snap: IPC.Status) -> SendableJSON {
        let status: [String: SendableValue] = [
            "state": .string(snap.state),
            "sync_dir": .string(snap.syncDir),
            "remote_folder": .string(snap.remoteFolder),
            "tracked_docs": .int(snap.trackedDocs),
            "conflicts": .int(snap.conflicts),
            "errors": .int(snap.errors),
            "queue_depth": .int(snap.queueDepth),
            "paused": .bool(snap.paused),
            "updated_at": .string(snap.updatedAt),
            "pid": .int(snap.pid),
            "version": .string(snap.version),
            "last_pull_at": snap.lastPullAt.map { .string($0) } ?? .null,
            "last_push_at": snap.lastPushAt.map { .string($0) } ?? .null,
            "last_error": snap.lastError.map { .string($0) } ?? .null,
        ]
        return SendableJSON.dict(["status": .object(status)])
    }
}
