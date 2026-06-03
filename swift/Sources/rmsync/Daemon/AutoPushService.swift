import Foundation

/// Opt-in local-to-cloud auto-push. This deliberately does not reuse the
/// legacy daemon worker loop: watcher delete / rename / mkdir signals are
/// ignored, and every upload goes through ``ExplicitSync.autoPush`` with
/// ``includeDeletes = false`` and ``force = false``.
final class AutoPushService: @unchecked Sendable {
    private let cfg: Config
    private let state: State
    private let cloud: any CloudWriteClient
    private let queue = JobQueue()
    private let fence: EchoFence
    private let engine: AutoPushEngine
    private var tasks: [Task<Void, Never>] = []

    #if os(macOS)
    private var watcher: LocalWatcher?
    #elseif os(Linux)
    private var watcher: INotifyWatcher?
    #endif

    init(cfg: Config, state: State, cloud: any CloudWriteClient = Cloud()) {
        self.cfg = cfg
        self.state = state
        self.cloud = cloud
        self.fence = EchoFence(windowSeconds: cfg.echoFenceSeconds)
        self.engine = AutoPushEngine(cfg: cfg, state: state, cloud: cloud)
    }

    func start() {
        guard cfg.autoPush.enabled else {
            Logger.shared.info("auto-push disabled")
            return
        }

        Logger.shared.info("auto-push starting", meta: [
            "scan_interval_seconds": "\(cfg.autoPush.scanIntervalSeconds)",
            "stable_sample_count": "\(cfg.autoPush.stableSampleCount)",
        ])

        tasks.append(Task { [engine] in
            await engine.startup()
        })
        tasks.append(Task { [weak self] in await self?.consumeEvents() })
        tasks.append(Task { [weak self] in await self?.scanLoop() })
        tasks.append(Task { [weak self] in await self?.sampleLoop() })

        #if os(macOS)
        let watcher = LocalWatcher(
            syncDir: cfg.syncDir,
            queue: queue,
            fence: fence,
            debounceSeconds: cfg.autoPush.debounceSeconds,
            mode: .markdown
        )
        self.watcher = watcher
        watcher.start()
        #elseif os(Linux)
        let watcher = INotifyWatcher(
            syncDir: cfg.syncDir,
            queue: queue,
            fence: fence,
            debounceSeconds: cfg.autoPush.debounceSeconds,
            mode: .markdown
        )
        self.watcher = watcher
        watcher.start()
        #endif
    }

    func stop() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        #if os(macOS)
        watcher?.stop()
        watcher = nil
        #elseif os(Linux)
        watcher?.stop()
        watcher = nil
        #endif
        Logger.shared.info("auto-push stopped")
    }

    private func consumeEvents() async {
        while !Task.isCancelled {
            guard let job = await queue.dequeue(timeout: 1.0) else { continue }
            if job.kind == .push {
                await engine.enqueue(path: job.hint)
            } else {
                Logger.shared.debug(
                    "auto-push ignored non-push watcher event",
                    meta: ["kind": job.kind.rawValue, "path": job.hint]
                )
            }
            await queue.taskDone()
        }
    }

    private func scanLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(cfg.autoPush.scanIntervalSeconds))
            await engine.scanOnce()
        }
    }

    private func sampleLoop() async {
        let delay = max(0.25, cfg.autoPush.debounceSeconds)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(delay))
            await engine.processCandidates()
        }
    }
}

actor AutoPushEngine {
    struct FileSample: Equatable, Sendable {
        var size: Int
        var modifiedAt: TimeInterval
        var hash: String
    }

    private struct Candidate: Sendable {
        var path: String
        var lastSample: FileSample?
        var stableCount: Int
    }

    private enum Refusal: Error, CustomStringConvertible {
        case ignoredPath
        case missing
        case nonRegularFile
        case datalessPlaceholder
        case unreadableFile
        case invalidUTF8
        case newFilesDisabled

        var description: String {
            switch self {
            case .ignoredPath: return "ignored_path"
            case .missing: return "missing"
            case .nonRegularFile: return "non_regular_file"
            case .datalessPlaceholder: return "dataless_placeholder"
            case .unreadableFile: return "unreadable_file"
            case .invalidUTF8: return "invalid_utf8"
            case .newFilesDisabled: return "new_files_disabled"
            }
        }
    }

    private let cfg: Config
    private let state: State
    private let cloud: any CloudWriteClient
    private let locks = LockRegistry()
    private var candidates: [String: Candidate] = [:]
    private var pushTimestamps: [Date] = []
    private var suspendedReason: String?
    private var failureStreak = 0
    private var startupChecked = false

    init(cfg: Config, state: State, cloud: any CloudWriteClient = Cloud()) {
        self.cfg = cfg
        self.state = state
        self.cloud = cloud
    }

    func startup() async {
        guard await ensureReady() else { return }
        await reconcileInterruptedOperations()
        scanOnce()
    }

    func reconcileInterruptedOperations() async {
        do {
            let operations = try await state.interruptedAutoPushOperations()
            for operation in operations {
                await verifyInterruptedOperation(operation)
            }
            if !operations.isEmpty {
                Logger.shared.warn(
                    "auto-push interrupted operations reconciled",
                    meta: ["count": "\(operations.count)"]
                )
            }
        } catch {
            Logger.shared.warn("auto-push operation reconcile failed", meta: ["error": "\(error)"])
        }
    }

    func enqueue(path: String) {
        let canonical = canonicalPath(path)
        guard !WatcherFilter.shouldIgnore(canonical, root: cfg.syncDir, mode: .markdown) else {
            return
        }
        if candidates[canonical] == nil {
            candidates[canonical] = Candidate(path: canonical, lastSample: nil, stableCount: 0)
        }
    }

    func scanOnce() {
        guard let enumerator = FileManager.default.enumerator(
            at: cfg.syncDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let url as URL in enumerator {
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            if isRegular { enqueue(path: url.path) }
        }
    }

    func processCandidates() async {
        guard await ensureReady() else { return }
        do {
            if try await state.isPaused() { return }
        } catch {
            Logger.shared.warn("auto-push pause check failed", meta: ["error": "\(error)"])
            return
        }

        for path in Array(candidates.keys).sorted() {
            guard !Task.isCancelled else { return }
            await processCandidate(path: path)
        }
    }

    private func ensureReady() async -> Bool {
        if let suspendedReason {
            Logger.shared.debug("auto-push suspended", meta: ["reason": suspendedReason])
            return false
        }
        guard !startupChecked else { return true }
        startupChecked = true
        if let repo = await GitSync.configuredRepository(containing: cfg.syncDir) {
            let reason = "git_sync_managed"
            suspendedReason = reason
            await recordServiceRefusal(
                reason: reason,
                detail: "sync_dir is inside rmsync-git repository \(repo.root.path); use `rmsync git push`"
            )
            Notifications.notify(
                title: "rmsync auto-push paused",
                body: "Auto-push is disabled in rmsync-git repositories; use rmsync git push."
            )
            return false
        }
        return true
    }

    private func processCandidate(path: String) async {
        guard var candidate = candidates[path] else { return }
        do {
            let sample = try sampleFile(path: path)
            if candidate.lastSample == sample {
                candidate.stableCount += 1
            } else {
                candidate.lastSample = sample
                candidate.stableCount = 1
            }

            if candidate.stableCount < cfg.autoPush.stableSampleCount {
                candidates[path] = candidate
                return
            }

            guard await reservePushSlot() else {
                candidates[path] = candidate
                return
            }
            candidates.removeValue(forKey: path)
            await pushStable(path: path, sample: sample)
        } catch Refusal.missing {
            candidates.removeValue(forKey: path)
        } catch let refusal as Refusal {
            candidates.removeValue(forKey: path)
            await recordRefusal(path: path, sample: nil, reason: refusal.description)
        } catch {
            candidates.removeValue(forKey: path)
            await recordRefusal(path: path, sample: nil, reason: "sample_failed: \(error)")
        }
    }

    private func pushStable(path: String, sample: FileSample) async {
        let doc = try? await state.byLocalPath(path)
        if let doc, doc.lastSyncedMDHash == sample.hash {
            return
        }
        if doc == nil, !cfg.autoPush.newFiles {
            await recordRefusal(path: path, sample: sample, reason: Refusal.newFilesDisabled.description)
            return
        }

        let lockKey = doc?.docID ?? "new:\(path)"
        let token = await locks.acquire(lockKey)
        defer { Task { await token.release() } }

        let opID: Int64
        do {
            opID = try await state.createAutoPushOperation(
                path: path,
                docID: doc?.docID,
                localHash: sample.hash,
                baselineRemoteModified: doc?.remoteModified,
                state: "queued"
            )
            try await state.updateAutoPushOperation(id: opID, state: "uploading")
        } catch {
            Logger.shared.warn("auto-push operation record failed", meta: ["path": path, "error": "\(error)"])
            return
        }

        do {
            let result = try await ExplicitSync.autoPush(
                cfg: cfg,
                state: state,
                cloud: cloud,
                path: path
            )
            if result.pushed > 0 {
                let updated = try? await state.byLocalPath(path)
                try await state.updateAutoPushOperation(
                    id: opID,
                    state: "succeeded",
                    remoteModified: updated?.remoteModified
                )
                failureStreak = 0
                Logger.shared.info("auto-push succeeded", meta: ["path": path])
                return
            }
            if result.skipped > 0, result.refused.isEmpty {
                try await state.updateAutoPushOperation(id: opID, state: "skipped")
                return
            }
            let message = result.refused.first ?? "auto-push refused"
            let reason = Self.reason(from: message)
            try await state.updateAutoPushOperation(id: opID, state: "refused", reason: reason)
            await noteFailure(reason: reason, path: path)
        } catch {
            let reason = Self.reason(from: "\(error)")
            try? await state.updateAutoPushOperation(id: opID, state: "failed", reason: reason)
            await noteFailure(reason: reason, path: path)
        }
    }

    private func verifyInterruptedOperation(_ op: State.AutoPushOperation) async {
        guard op.state == "queued" || op.state == "uploading" else { return }
        guard let localHash = op.localHash else {
            await failInterruptedOperation(op, reason: "interrupted_missing_local_hash")
            return
        }
        guard let docID = op.docID,
              let doc = try? await state.get(docID: docID)
        else {
            await failInterruptedOperation(op, reason: "interrupted_new_doc_verify_manually")
            return
        }

        let stat: StatResult
        do {
            guard let remoteStat = try await cloud.stat(doc.remotePath) else {
                await failInterruptedOperation(op, reason: "interrupted_cloud_missing")
                return
            }
            stat = remoteStat
        } catch {
            await failInterruptedOperation(op, reason: "interrupted_stat_failed")
            return
        }

        if let baseline = op.baselineRemoteModified, stat.modifiedClient == baseline {
            await failInterruptedOperation(op, reason: "interrupted_before_upload")
            return
        }

        let verifyRoot = Paths.scratchDir
            .appendingPathComponent("rmsync-auto-push-verify-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: verifyRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: verifyRoot) }

            let archive = try await cloud.get(doc.remotePath, dest: verifyRoot)
            let rmdoc = try await Archive.unpack(archive)
            let rendered = try ExplicitSync.renderSourceMarkdown(
                rmdoc,
                localURL: URL(fileURLWithPath: op.path),
                stored: doc
            )
            guard rendered.sourceHash == localHash else {
                await failInterruptedOperation(op, reason: "interrupted_remote_changed")
                return
            }

            let pageIDs = rmdoc.pages.map(\.pageID)
            let remoteModified = stat.modifiedClient.isEmpty ? nil : stat.modifiedClient
            var repaired = doc
            repaired.remoteVersion = max(doc.remoteVersion + 1, stat.version)
            repaired.remoteModified = remoteModified
            repaired.lastSyncedMDHash = localHash
            repaired.lastSyncedTabletHash = rendered.tabletHash
            repaired.lastPushAt = ISO8601.now()
            repaired.errorState = nil
            repaired.pageIDs = pageIDs
            try await state.upsert(repaired)
            try await state.updateAutoPushOperation(
                id: op.id,
                state: "succeeded",
                remoteModified: remoteModified
            )
            await ExplicitSync.storeVerifiedRemoteSnapshot(
                docID: doc.docID,
                remotePath: doc.remotePath,
                stat: stat,
                source: rendered.source,
                sourceHash: rendered.sourceHash,
                tabletHash: rendered.tabletHash,
                pageIDs: pageIDs,
                archive: archive,
                state: state
            )
            Logger.shared.info("auto-push interrupted upload verified", meta: ["path": op.path])
        } catch {
            await failInterruptedOperation(op, reason: "interrupted_verify_failed")
        }
    }

    private func failInterruptedOperation(_ op: State.AutoPushOperation, reason: String) async {
        do {
            try await state.updateAutoPushOperation(id: op.id, state: "failed", reason: reason)
        } catch {
            Logger.shared.warn(
                "auto-push interrupted operation update failed",
                meta: ["id": "\(op.id)", "error": "\(error)"]
            )
        }
        await noteFailure(reason: reason, path: op.path)
    }

    private func sampleFile(path: String) throws -> FileSample {
        guard !WatcherFilter.shouldIgnore(path, root: cfg.syncDir, mode: .markdown) else {
            throw Refusal.ignoredPath
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw Refusal.missing
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true else {
            throw Refusal.nonRegularFile
        }
        if FileProvider.status(of: url).isDataless {
            throw Refusal.datalessPlaceholder
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw Refusal.unreadableFile
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw Refusal.invalidUTF8
        }
        return FileSample(
            size: values.fileSize ?? data.count,
            modifiedAt: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
            hash: PathUtilities.sha256(text)
        )
    }

    private func recordRefusal(path: String, sample: FileSample?, reason: String) async {
        do {
            let doc = try await state.byLocalPath(path)
            let id = try await state.createAutoPushOperation(
                path: path,
                docID: doc?.docID,
                localHash: sample?.hash,
                baselineRemoteModified: doc?.remoteModified,
                state: "refused",
                reason: reason
            )
            try await state.updateAutoPushOperation(id: id, state: "refused", reason: reason)
        } catch {
            Logger.shared.warn("auto-push refusal record failed", meta: ["path": path, "error": "\(error)"])
        }
        await noteFailure(reason: reason, path: path)
    }

    private func recordServiceRefusal(reason: String, detail: String) async {
        do {
            _ = try await state.createAutoPushOperation(
                path: cfg.syncDir.path,
                docID: nil,
                localHash: nil,
                baselineRemoteModified: nil,
                state: "refused",
                reason: reason
            )
        } catch {
            Logger.shared.warn(
                "auto-push service refusal record failed",
                meta: ["reason": reason, "error": "\(error)"]
            )
        }
        Logger.shared.warn("auto-push refused", meta: ["reason": reason, "detail": detail])
    }

    private func noteFailure(reason: String, path: String) async {
        failureStreak += 1
        Logger.shared.warn("auto-push refused", meta: ["path": path, "reason": reason])
        if reason == "remote_changed" || reason == "missing_baseline" || failureStreak >= 3 {
            suspendedReason = reason
            Notifications.notify(
                title: "rmsync auto-push paused",
                body: "Auto-push paused for \(URL(fileURLWithPath: path).lastPathComponent): \(reason)"
            )
        }
    }

    private func reservePushSlot(now: Date = Date()) async -> Bool {
        let cutoff = now.addingTimeInterval(-60)
        pushTimestamps.removeAll { $0 < cutoff }
        guard pushTimestamps.count < cfg.autoPush.maxPushesPerMinute else {
            return false
        }
        pushTimestamps.append(now)
        return true
    }

    private static func reason(from message: String) -> String {
        if message.contains("remote changed") || message.contains("cloud changed") {
            return "remote_changed"
        }
        if message.contains("missing remote baseline") {
            return "missing_baseline"
        }
        if message.contains("dataless") {
            return "dataless_placeholder"
        }
        if message.contains("empty local read") {
            return "empty_over_nonempty"
        }
        if message.contains("already has a document") {
            return "path_collision"
        }
        if message.contains("document missing") || message.contains("cloud document missing") {
            return "cloud_missing"
        }
        return message
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
