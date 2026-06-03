import Foundation

/// Top-level daemon event loop.
///
/// The daemon is intentionally status-only in the explicit sync model.
/// It keeps IPC / dashboard status online, but it does not watch local
/// files, poll the cloud, or reconcile deletions. Sync mutations happen
/// only through explicit CLI commands: ``pull``, ``accept``, and ``push``.
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

        try await refreshBus(bus: bus, state: state, cfg: cfg, queue: queue)

        // IPC server accepts pause/resume/sync_now/get_status. In
        // explicit mode, sync_now and push_path return clear errors
        // instead of scheduling hidden mutation work.
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
            Logger.shared.info("sync_now ignored in explicit sync mode")
            return SendableJSON.dict([
                "ok": false,
                "error": "explicit_sync_mode",
                "hint": "use `rmsync pull`, `rmsync accept`, and `rmsync push`",
            ])
        }
        await server.register("get_status") { _ in
            let snap = await bus.snapshot()
            return Self.snapshotFrame(snap)
        }
        // Compatibility endpoint for older clients. It deliberately
        // refuses to enqueue hidden work in explicit sync mode.
        await server.register("push_path") { _ in
            Logger.shared.info("push_path ignored in explicit sync mode")
            return SendableJSON.dict([
                "ok": false,
                "error": "explicit_sync_mode",
                "hint": "use `rmsync push <path>`",
            ])
        }
        try await server.start()
        Logger.shared.info(
            "ipc server listening",
            meta: ["path": Paths.ipcSocketPath.path]
        )

        // Optional embedded HTTP dashboard (``[web]`` config block).
        // Disabled by default; when enabled, generates a random
        // auth token if the user didn't set one and writes it to
        // ``$STATE_DIR/web-token`` so they can read it without
        // hand-editing config.
        let httpServer = try await Self.startHTTPDashboardIfEnabled(
            cfg: cfg, bus: bus, queue: queue, state: state
        )

        // Explicit sync mode: no reconcile, no watcher, no cloud poller.
        // Keep only IPC / dashboard status alive.
        Logger.shared.info(
            "explicit sync mode: daemon is status-only; use rmsync pull/push"
        )
        let autoPush = AutoPushService(cfg: cfg, state: state)
        autoPush.start()

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
        autoPush.stop()
        if let httpServer { await httpServer.stop() }
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

    /// Spin up the optional HTTP dashboard if the user enabled it
    /// in ``[web]``. Returns nil if the block is absent or
    /// ``enabled`` is false. Generates a random auth token on first
    /// run and persists it to ``$STATE_DIR/web-token`` so the user
    /// can paste it into the dashboard URL without editing config.
    private static func startHTTPDashboardIfEnabled(
        cfg: Config, bus: StateBus, queue: JobQueue,
        state: State
    ) async throws -> HTTPServer? {
        guard let web = cfg.web, web.enabled else { return nil }

        // Resolve the auth token: prefer config-provided value;
        // otherwise generate one and write to STATE_DIR/web-token.
        // The on-disk file is the user's "where do I get the
        // token?" answer when they haven't set it explicitly.
        let token: String
        if let configured = web.authToken, !configured.isEmpty {
            token = configured
        } else {
            let tokenPath = Paths.stateDir.appendingPathComponent("web-token")
            if let existing = try? String(contentsOf: tokenPath, encoding: .utf8),
               !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                token = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                token = "rmsync-" + UUID().uuidString
                try? FileManager.default.createDirectory(
                    at: Paths.stateDir, withIntermediateDirectories: true
                )
                try? token.write(to: tokenPath, atomically: true, encoding: .utf8)
                Logger.shared.info(
                    "web dashboard token written",
                    meta: ["path": tokenPath.path, "hint": "open the dashboard at the URL with ?token=..."]
                )
            }
        }

        let http = HTTPServer(
            bindAddr: web.bindAddr, port: web.port, authToken: token,
            bus: bus, queue: queue, state: state
        )
        await http.register("sync-now") {
            Logger.shared.info("dashboard sync-now ignored in explicit sync mode")
        }
        await http.register("pause") {
            try? await state.setPaused(true)
            try? await refreshBus(bus: bus, state: state, cfg: cfg, queue: queue)
        }
        await http.register("resume") {
            try? await state.setPaused(false)
            try? await refreshBus(bus: bus, state: state, cfg: cfg, queue: queue)
        }
        try await http.start()
        return http
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
