import Foundation

enum ExplicitSync {
    enum ChangeKind: String, Codable, Sendable {
        case added
        case modified
        case deleted
        case conflict
        case localModified = "local_modified"
        case unchanged
        case error
    }

    struct Manifest: Codable, Sendable {
        var id: String
        var createdAt: String
        var remoteFolder: String
        var syncDir: String
        var entries: [Entry]
    }

    struct Entry: Codable, Sendable {
        var kind: ChangeKind
        var docID: String
        var remotePath: String
        var localPath: String
        var relativePath: String
        var stagedPath: String?
        var remoteModified: String?
        var remoteVersion: Int
        var remoteHash: String?
        var remoteTabletHash: String?
        var localHashAtPull: String?
        var baselineHash: String?
        var pageIDs: [String]
        var error: String?
    }

    struct StageResult {
        var id: String
        var root: URL
        var entries: [Entry]
    }

    struct AcceptResult {
        var applied: Int = 0
        var deleted: Int = 0
        var skipped: Int = 0
        var refused: [String] = []
    }

    struct PushResult {
        var pushed: Int = 0
        var skipped: Int = 0
        var refused: [String] = []
    }

    private enum PushFileOutcome {
        case uploaded
        case skipped
    }

    enum PushMode: Sendable {
        case manual
        case auto
    }

    enum ForcePushAction: String, Codable, Sendable {
        case createRemote = "create_remote"
        case overwriteRemote = "overwrite_remote"
        case moveRemote = "move_remote"
        case moveAndOverwriteRemote = "move_and_overwrite_remote"
        case deleteRemote = "delete_remote"
        case unchanged
        case error
    }

    struct ForcePushRename: Sendable, Hashable {
        var oldPath: String
        var newPath: String
    }

    struct ForcePushPlanItem: Codable, Sendable {
        var action: ForcePushAction
        var relativePath: String
        var sourceRelativePath: String?
        var localPath: String?
        var remotePath: String?
        var destinationRemotePath: String?
        var docID: String?
        var remoteModified: String?
        var remoteVersion: Int?
        var remoteHash: String?
        var remoteTabletHash: String?
        var localHash: String?
        var stagedPath: String?
        var pageIDs: [String]
        var error: String?
    }

    struct ForcePushPlan {
        var stage: StageResult
        var items: [ForcePushPlanItem]
    }

    struct ForcePushResult {
        var created: Int = 0
        var moved: Int = 0
        var overwritten: Int = 0
        var deleted: Int = 0
        var unchanged: Int = 0
        var refused: [String] = []
    }

    struct LocalFile: Sendable {
        var url: URL
        var relativePath: String
        var hash: String
    }

    enum SyncError: Error, CustomStringConvertible {
        case noStagedPull
        case noSelection
        case pathNotStaged(String)
        case destructiveDeleteRequiresFlag(String)
        case conflictRequiresForce(String)
        case staleLocal(String)
        case cloudChanged(String)
        case cloudMissing(String)
        case cloudAlreadyHasPath(String)
        case missingRemoteBaseline(String)
        case localDatalessPlaceholder(String)
        case localEmptyWouldOverwrite(String)
        case invalidPath(String)
        case stagedDiffUnavailable(String)
        case diffFailed(exitCode: Int32, stderr: String)

        var description: String {
            switch self {
            case .noStagedPull:
                return "no staged pull found; run `rmsync pull` first"
            case .noSelection:
                return "nothing selected; pass paths or --all"
            case .pathNotStaged(let path):
                return "path not found in staged pull: \(path)"
            case .destructiveDeleteRequiresFlag(let path):
                return "refusing staged delete for \(path); rerun with --include-deletes"
            case .conflictRequiresForce(let path):
                return "refusing conflict overwrite for \(path); rerun with --force"
            case .staleLocal(let path):
                return "local file changed since pull was staged: \(path)"
            case .cloudChanged(let path):
                return "cloud changed since last accepted baseline: \(path)"
            case .cloudMissing(let path):
                return "cloud document missing at tracked path: \(path)"
            case .cloudAlreadyHasPath(let path):
                return "cloud already has a document at \(path); refusing new push without --force"
            case .missingRemoteBaseline(let path):
                return "missing remote baseline for \(path); run `rmsync push` manually"
            case .localDatalessPlaceholder(let path):
                return "refusing to push dataless cloud-storage placeholder: \(path)"
            case .localEmptyWouldOverwrite(let path):
                return "refusing to push empty local read over previously non-empty cloud content: \(path)"
            case .invalidPath(let path):
                return "path is outside sync_dir: \(path)"
            case .stagedDiffUnavailable(let path):
                return "staged diff unavailable for \(path)"
            case .diffFailed(let code, let stderr):
                return "diff(1) failed (exit \(code)): \(stderr)"
            }
        }
    }

    static func stagePull(
        cfg: Config,
        state: State,
        cloud: any CloudClient = Cloud(),
        full: Bool = false,
        stagingDir: URL? = nil,
        initiator: String = "manual"
    ) async throws -> StageResult {
        Logger.shared.audit("explicit pull started", meta: [
            "initiator": initiator,
            "sync_dir": cfg.syncDir.path,
            "remote_folder": cfg.remoteFolder,
            "full": boolString(full),
        ])
        do {
        let fm = FileManager.default
        let id = stageID()
        let stagingRoot = stagingDir ?? Paths.stagingDir
        let root = stagingRoot.appendingPathComponent(id, isDirectory: true)
        let filesRoot = root.appendingPathComponent("files", isDirectory: true)
        let archivesRoot = root.appendingPathComponent("archives", isDirectory: true)
        try fm.createDirectory(at: filesRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: archivesRoot, withIntermediateDirectories: true)

        let nodes = try await cloud.tree(PathUtilities.remoteFolderPath(cfg.remoteFolder))
        let remoteDocs = nodes
            .filter { $0.type == .document }
            .sorted { $0.remotePath < $1.remotePath }

        var entries: [Entry] = []
        var seenIDs: Set<String> = []

        for node in remoteDocs {
            seenIDs.insert(node.id)
            let localURL = PathUtilities.remoteToLocal(
                remotePath: node.remotePath,
                syncDir: cfg.syncDir,
                remoteFolder: cfg.remoteFolder
            )
            let rel = relativeMarkdownPath(
                remotePath: node.remotePath,
                remoteFolder: cfg.remoteFolder
            )
            let archiveDest = archivesRoot.appendingPathComponent(node.id, isDirectory: true)
            let stored = try await state.get(docID: node.id)
            let byPath = try await state.byLocalPath(localURL.path)

            do {
                if !full,
                   let cached = try await cachedStageEntry(
                        node: node,
                        localURL: localURL,
                        relativePath: rel,
                        filesRoot: filesRoot,
                        state: state,
                        stored: stored,
                        byPath: byPath
                   ) {
                    entries.append(cached)
                    continue
                }

                entries.append(try await downloadedStageEntry(
                    node: node,
                    localURL: localURL,
                    relativePath: rel,
                    filesRoot: filesRoot,
                    archiveDest: archiveDest,
                    state: state,
                    cloud: cloud,
                    stored: stored,
                    byPath: byPath
                ))
            } catch {
                entries.append(Entry(
                    kind: .error,
                    docID: node.id,
                    remotePath: node.remotePath,
                    localPath: localURL.path,
                    relativePath: rel,
                    stagedPath: nil,
                    remoteModified: node.modifiedClient.isEmpty ? nil : node.modifiedClient,
                    remoteVersion: node.version,
                    remoteHash: nil,
                    remoteTabletHash: nil,
                    localHashAtPull: try? hashIfExists(localURL),
                    baselineHash: stored?.lastSyncedMDHash ?? byPath?.lastSyncedMDHash,
                    pageIDs: [],
                    error: "\(error)"
                ))
            }
        }

        let tracked = try await state.allDocuments()
        for doc in tracked where doc.docType == "DocumentType" && !seenIDs.contains(doc.docID) {
            let rel = relativePathForLocal(doc.localPath, syncDir: cfg.syncDir)
                ?? relativeMarkdownPath(remotePath: doc.remotePath, remoteFolder: cfg.remoteFolder)
            entries.append(Entry(
                kind: .deleted,
                docID: doc.docID,
                remotePath: doc.remotePath,
                localPath: doc.localPath,
                relativePath: rel,
                stagedPath: nil,
                remoteModified: doc.remoteModified,
                remoteVersion: doc.remoteVersion,
                remoteHash: nil,
                remoteTabletHash: nil,
                localHashAtPull: try? hashIfExists(URL(fileURLWithPath: doc.localPath)),
                baselineHash: doc.lastSyncedMDHash,
                pageIDs: doc.pageIDs,
                error: nil
            ))
        }

        entries.sort { lhs, rhs in
            if lhs.kind.rawValue == rhs.kind.rawValue { return lhs.relativePath < rhs.relativePath }
            return lhs.relativePath < rhs.relativePath
        }

        let manifest = Manifest(
            id: id,
            createdAt: ISO8601.now(),
            remoteFolder: cfg.remoteFolder,
            syncDir: cfg.syncDir.path,
            entries: entries
        )
        try writeManifest(manifest, root: root)
        try PathUtilities.atomicWriteText(id + "\n", to: stagingRoot.appendingPathComponent("current"))
        let result = StageResult(id: id, root: root, entries: entries)
        Logger.shared.audit(
            "explicit pull staged",
            meta: stageResultMeta(result, initiator: initiator, full: full)
        )
        return result
        } catch {
            Logger.shared.audit("explicit pull failed", meta: [
                "initiator": initiator,
                "sync_dir": cfg.syncDir.path,
                "remote_folder": cfg.remoteFolder,
                "full": boolString(full),
                "error": "\(error)",
            ], level: "error")
            throw error
        }
    }

    private static func cachedStageEntry(
        node: Node,
        localURL: URL,
        relativePath rel: String,
        filesRoot: URL,
        state: State,
        stored: Document?,
        byPath: Document?
    ) async throws -> Entry? {
        let fingerprint = remoteFingerprint(node)
        guard let snapshot = try await state.remoteSnapshot(docID: node.id),
              snapshot.remoteFingerprint == fingerprint,
              snapshot.remotePath == node.remotePath,
              let cachedText = cachedSourceText(snapshot)
        else { return nil }

        let localHash = try? hashIfExists(localURL)
        let baseline = stored?.lastSyncedMDHash ?? byPath?.lastSyncedMDHash
        let kind = classify(
            docID: node.id,
            stored: stored,
            byPath: byPath,
            localHash: localHash,
            remoteHash: snapshot.sourceHash,
            baseline: baseline
        )
        let stagedRel: String?
        if requiresStagedSource(kind) {
            let stagedURL = appendRelative(rel, to: filesRoot)
            try PathUtilities.atomicWriteText(cachedText, to: stagedURL)
            stagedRel = "files/" + rel
        } else {
            stagedRel = nil
        }

        return Entry(
            kind: kind,
            docID: node.id,
            remotePath: node.remotePath,
            localPath: localURL.path,
            relativePath: rel,
            stagedPath: stagedRel,
            remoteModified: remoteModified(node),
            remoteVersion: node.version,
            remoteHash: snapshot.sourceHash,
            remoteTabletHash: snapshot.tabletHash,
            localHashAtPull: localHash,
            baselineHash: baseline,
            pageIDs: snapshot.pageIDs,
            error: nil
        )
    }

    private static func downloadedStageEntry(
        node: Node,
        localURL: URL,
        relativePath rel: String,
        filesRoot: URL,
        archiveDest: URL,
        state: State,
        cloud: any CloudClient,
        stored: Document?,
        byPath: Document?
    ) async throws -> Entry {
        let stagedURL = appendRelative(rel, to: filesRoot)
        let stagedRel = "files/" + rel
        let archive = try await cloud.get(node.remotePath, dest: archiveDest)
        let rmdoc = try await Archive.unpack(archive)
        let rendered = try renderSourceMarkdown(
            rmdoc,
            localURL: localURL,
            stored: stored ?? byPath
        )
        let md = rendered.source
        try PathUtilities.atomicWriteText(md, to: stagedURL)

        let remoteHash = rendered.sourceHash
        let localHash = try? hashIfExists(localURL)
        let baseline = stored?.lastSyncedMDHash ?? byPath?.lastSyncedMDHash
        let kind = classify(
            docID: node.id,
            stored: stored,
            byPath: byPath,
            localHash: localHash,
            remoteHash: remoteHash,
            baseline: baseline
        )
        let pageIDs = rmdoc.pages.map(\.pageID)

        await storeRemoteSnapshot(
            node: node,
            rendered: rendered,
            pageIDs: pageIDs,
            archive: archive,
            state: state
        )

        return Entry(
            kind: kind,
            docID: node.id,
            remotePath: node.remotePath,
            localPath: localURL.path,
            relativePath: rel,
            stagedPath: stagedRel,
            remoteModified: remoteModified(node),
            remoteVersion: node.version,
            remoteHash: remoteHash,
            remoteTabletHash: rendered.tabletHash,
            localHashAtPull: localHash,
            baselineHash: baseline,
            pageIDs: pageIDs,
            error: nil
        )
    }

    static func loadCurrentStage() throws -> (root: URL, manifest: Manifest) {
        let fm = FileManager.default
        let current = Paths.stagingDir.appendingPathComponent("current")
        if let id = try? String(contentsOf: current, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !id.isEmpty {
            let root = Paths.stagingDir.appendingPathComponent(id, isDirectory: true)
            return (root, try readManifest(root: root))
        }

        guard let children = try? fm.contentsOfDirectory(
            at: Paths.stagingDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { throw SyncError.noStagedPull }

        let candidates = children
            .filter { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                return values?.isDirectory == true
                    && fm.fileExists(atPath: url.appendingPathComponent("manifest.json").path)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let latest = candidates.last else { throw SyncError.noStagedPull }
        return (latest, try readManifest(root: latest))
    }

    static func accept(
        cfg: Config,
        state: State,
        paths: [String],
        all: Bool,
        includeDeletes: Bool,
        force: Bool,
        initiator: String = "manual"
    ) async throws -> AcceptResult {
        Logger.shared.audit("explicit accept started", meta: [
            "initiator": initiator,
            "sync_dir": cfg.syncDir.path,
            "all": boolString(all),
            "include_deletes": boolString(includeDeletes),
            "force": boolString(force),
            "path_count": "\(paths.count)",
        ])
        do {
        let (root, manifest) = try loadCurrentStage()
        let selected = try selectEntries(manifest.entries, paths: paths, all: all)
        var result = AcceptResult()

        for entry in selected {
            do {
                switch entry.kind {
                case .unchanged, .localModified:
                    result.skipped += 1
                case .error:
                    result.refused.append("\(entry.relativePath): staged pull had error: \(entry.error ?? "unknown")")
                case .conflict where !force:
                    throw SyncError.conflictRequiresForce(entry.relativePath)
                case .deleted:
                    guard includeDeletes else {
                        throw SyncError.destructiveDeleteRequiresFlag(entry.relativePath)
                    }
                    try await acceptDelete(entry, cfg: cfg, state: state, force: force)
                    result.deleted += 1
                case .added, .modified, .conflict:
                    try await acceptFile(entry, root: root, cfg: cfg, state: state, force: force)
                    result.applied += 1
                }
            } catch {
                result.refused.append("\(entry.relativePath): \(error)")
            }
        }

        Logger.shared.audit(
            "explicit accept completed",
            meta: acceptResultMeta(
                result,
                initiator: initiator,
                stageID: manifest.id,
                selected: selected.count
            )
        )
        return result
        } catch {
            Logger.shared.audit("explicit accept failed", meta: [
                "initiator": initiator,
                "sync_dir": cfg.syncDir.path,
                "all": boolString(all),
                "include_deletes": boolString(includeDeletes),
                "force": boolString(force),
                "path_count": "\(paths.count)",
                "error": "\(error)",
            ], level: "error")
            throw error
        }
    }

    static func push(
        cfg: Config,
        state: State,
        cloud: any CloudWriteClient = Cloud(),
        paths: [String],
        includeDeletes: Bool,
        force: Bool,
        initiator: String = "manual",
        mode: PushMode = .manual
    ) async throws -> PushResult {
        Logger.shared.audit("explicit push started", meta: [
            "initiator": initiator,
            "sync_dir": cfg.syncDir.path,
            "remote_folder": cfg.remoteFolder,
            "include_deletes": boolString(includeDeletes),
            "force": boolString(force),
            "path_count": "\(paths.count)",
            "target_mode": paths.isEmpty ? "all_local_markdown" : "selected_paths",
        ])
        do {
        var result = PushResult()
        var targets = try localPushTargets(cfg: cfg, paths: paths)

        if includeDeletes {
            for doc in try await state.allDocuments() where doc.docType == "DocumentType" {
                if !FileManager.default.fileExists(atPath: doc.localPath) {
                    targets.append(URL(fileURLWithPath: doc.localPath))
                }
            }
        }

        var seen: Set<String> = []
        for target in targets {
            let path = target.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            do {
                if FileManager.default.fileExists(atPath: path) {
                    switch try await pushFile(target, cfg: cfg, state: state, cloud: cloud, force: force, mode: mode) {
                    case .uploaded:
                        result.pushed += 1
                    case .skipped:
                        result.skipped += 1
                    }
                } else if includeDeletes {
                    try await pushDelete(target, state: state, cloud: cloud, force: force)
                    result.pushed += 1
                } else {
                    result.skipped += 1
                }
            } catch {
                result.refused.append("\(displayPath(target, syncDir: cfg.syncDir)): \(error)")
            }
        }

        Logger.shared.audit(
            "explicit push completed",
            meta: pushResultMeta(
                result,
                initiator: initiator,
                targets: seen.count,
                includeDeletes: includeDeletes,
                force: force
            )
        )
        return result
        } catch {
            Logger.shared.audit("explicit push failed", meta: [
                "initiator": initiator,
                "sync_dir": cfg.syncDir.path,
                "remote_folder": cfg.remoteFolder,
                "include_deletes": boolString(includeDeletes),
                "force": boolString(force),
                "path_count": "\(paths.count)",
                "target_mode": paths.isEmpty ? "all_local_markdown" : "selected_paths",
                "error": "\(error)",
            ], level: "error")
            throw error
        }
    }

    static func autoPush(
        cfg: Config,
        state: State,
        cloud: any CloudWriteClient = Cloud(),
        path: String
    ) async throws -> PushResult {
        try await push(
            cfg: cfg,
            state: state,
            cloud: cloud,
            paths: [path],
            includeDeletes: false,
            force: false,
            initiator: "auto-push",
            mode: .auto
        )
    }

    static func planForcePush(
        cfg: Config,
        state: State,
        cloud: any CloudClient = Cloud(),
        stagingDir: URL? = nil,
        renames: [ForcePushRename] = [],
        initiator: String = "manual"
    ) async throws -> ForcePushPlan {
        Logger.shared.audit("force push plan started", meta: [
            "initiator": initiator,
            "sync_dir": cfg.syncDir.path,
            "remote_folder": cfg.remoteFolder,
        ])
        do {
        let stage = try await stagePull(
            cfg: cfg,
            state: state,
            cloud: cloud,
            stagingDir: stagingDir,
            initiator: initiator
        )
        let localFiles = try localForcePushFiles(cfg: cfg)
        let items = forcePushPlanItems(
            remoteEntries: stage.entries,
            localFiles: localFiles,
            remoteFolder: cfg.remoteFolder,
            renames: renames
        )
        let plan = ForcePushPlan(stage: stage, items: items)
        Logger.shared.audit(
            "force push plan completed",
            meta: forcePlanMeta(plan, initiator: initiator)
        )
        return plan
        } catch {
            Logger.shared.audit("force push plan failed", meta: [
                "initiator": initiator,
                "sync_dir": cfg.syncDir.path,
                "remote_folder": cfg.remoteFolder,
                "error": "\(error)",
            ], level: "error")
            throw error
        }
    }

    static func applyForcePush(
        _ plan: ForcePushPlan,
        cfg: Config,
        state: State,
        cloud: any CloudWriteClient = Cloud(),
        initiator: String = "manual"
    ) async throws -> ForcePushResult {
        Logger.shared.audit("force push apply started", meta: [
            "initiator": initiator,
            "stage_id": plan.stage.id,
            "sync_dir": cfg.syncDir.path,
            "remote_folder": cfg.remoteFolder,
            "item_count": "\(plan.items.count)",
        ])
        var result = ForcePushResult()

        for item in plan.items {
            do {
                switch item.action {
                case .createRemote:
                    guard let localPath = item.localPath else {
                        throw SyncError.invalidPath(item.relativePath)
                    }
                    try await pushFile(
                        URL(fileURLWithPath: localPath),
                        cfg: cfg,
                        state: state,
                        cloud: cloud,
                        force: true
                    )
                    result.created += 1
                case .overwriteRemote:
                    guard let localPath = item.localPath else {
                        throw SyncError.invalidPath(item.relativePath)
                    }
                    try await pushFile(
                        URL(fileURLWithPath: localPath),
                        cfg: cfg,
                        state: state,
                        cloud: cloud,
                        force: true,
                        remoteOverride: item
                    )
                    result.overwritten += 1
                case .moveRemote:
                    try await moveRemote(item, cfg: cfg, state: state, cloud: cloud)
                    result.moved += 1
                case .moveAndOverwriteRemote:
                    try await moveRemote(item, cfg: cfg, state: state, cloud: cloud)
                    guard let localPath = item.localPath else {
                        throw SyncError.invalidPath(item.relativePath)
                    }
                    var moved = item
                    moved.remotePath = item.destinationRemotePath
                    try await pushFile(
                        URL(fileURLWithPath: localPath),
                        cfg: cfg,
                        state: state,
                        cloud: cloud,
                        force: true,
                        remoteOverride: moved
                    )
                    result.moved += 1
                    result.overwritten += 1
                case .deleteRemote:
                    try await deleteRemoteOnly(item, state: state, cloud: cloud)
                    result.deleted += 1
                case .unchanged:
                    try await markRemoteUnchanged(item, state: state)
                    result.unchanged += 1
                case .error:
                    throw SyncError.pathNotStaged(item.error ?? item.relativePath)
                }
            } catch {
                result.refused.append("\(item.relativePath): \(error)")
            }
        }

        Logger.shared.audit(
            "force push apply completed",
            meta: forcePushResultMeta(result, initiator: initiator, items: plan.items.count)
        )
        return result
    }

    static func printDiff(_ manifest: Manifest) {
        let visible = manifest.entries.filter { $0.kind != .unchanged }
        if visible.isEmpty {
            print("no staged cloud changes")
            return
        }
        for entry in visible {
            let label = entry.kind.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)
            if let error = entry.error, entry.kind == .error {
                print("\(label) \(entry.relativePath)  (\(error))")
            } else {
                print("\(label) \(entry.relativePath)")
            }
        }
    }

    static func printDiff(_ manifest: Manifest, root: URL, path: String) throws {
        let text = try diffText(manifest, root: root, path: path)
        if text.isEmpty {
            print("no staged cloud changes for \(normalizeSelectionPath(path))")
        } else {
            print(text, terminator: text.hasSuffix("\n") ? "" : "\n")
        }
    }

    static func diffText(_ manifest: Manifest, root: URL, path: String) throws -> String {
        guard let entry = try selectEntries(manifest.entries, paths: [path], all: false).first else {
            throw SyncError.pathNotStaged(path)
        }
        return try diffText(entry, root: root)
    }

    static func printForcePushPlan(_ items: [ForcePushPlanItem]) {
        if items.isEmpty {
            print("remote already matches an empty local tree")
            return
        }

        for item in items {
            let label = item.action.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)
            if let error = item.error, item.action == .error {
                print("\(label) \(item.relativePath)  (\(error))")
            } else {
                print("\(label) \(item.relativePath)")
            }
        }
    }

    // MARK: - audit log helpers

    private static func boolString(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    private static func stageResultMeta(
        _ result: StageResult,
        initiator: String,
        full: Bool
    ) -> [String: String] {
        var meta: [String: String] = [
            "initiator": initiator,
            "stage_id": result.id,
            "stage_dir": result.root.path,
            "entry_count": "\(result.entries.count)",
            "full": boolString(full),
        ]
        meta.merge(changeCountMeta(result.entries)) { _, new in new }
        return meta
    }

    private static func acceptResultMeta(
        _ result: AcceptResult,
        initiator: String,
        stageID: String,
        selected: Int
    ) -> [String: String] {
        [
            "initiator": initiator,
            "stage_id": stageID,
            "selected": "\(selected)",
            "applied": "\(result.applied)",
            "deleted": "\(result.deleted)",
            "skipped": "\(result.skipped)",
            "refused": "\(result.refused.count)",
        ]
    }

    private static func pushResultMeta(
        _ result: PushResult,
        initiator: String,
        targets: Int,
        includeDeletes: Bool,
        force: Bool
    ) -> [String: String] {
        [
            "initiator": initiator,
            "targets": "\(targets)",
            "pushed": "\(result.pushed)",
            "skipped": "\(result.skipped)",
            "refused": "\(result.refused.count)",
            "include_deletes": boolString(includeDeletes),
            "force": boolString(force),
        ]
    }

    private static func forcePlanMeta(
        _ plan: ForcePushPlan,
        initiator: String
    ) -> [String: String] {
        var meta: [String: String] = [
            "initiator": initiator,
            "stage_id": plan.stage.id,
            "item_count": "\(plan.items.count)",
        ]
        meta.merge(forceActionCountMeta(plan.items)) { _, new in new }
        return meta
    }

    private static func forcePushResultMeta(
        _ result: ForcePushResult,
        initiator: String,
        items: Int
    ) -> [String: String] {
        [
            "initiator": initiator,
            "items": "\(items)",
            "created": "\(result.created)",
            "moved": "\(result.moved)",
            "overwritten": "\(result.overwritten)",
            "deleted": "\(result.deleted)",
            "unchanged": "\(result.unchanged)",
            "refused": "\(result.refused.count)",
        ]
    }

    private static func changeCountMeta(_ entries: [Entry]) -> [String: String] {
        let grouped = Dictionary(grouping: entries, by: \.kind)
        return [
            "added": "\(grouped[.added]?.count ?? 0)",
            "modified": "\(grouped[.modified]?.count ?? 0)",
            "deleted": "\(grouped[.deleted]?.count ?? 0)",
            "conflict": "\(grouped[.conflict]?.count ?? 0)",
            "local_modified": "\(grouped[.localModified]?.count ?? 0)",
            "unchanged": "\(grouped[.unchanged]?.count ?? 0)",
            "error": "\(grouped[.error]?.count ?? 0)",
        ]
    }

    private static func forceActionCountMeta(_ items: [ForcePushPlanItem]) -> [String: String] {
        let grouped = Dictionary(grouping: items, by: \.action)
        return [
            "create_remote": "\(grouped[.createRemote]?.count ?? 0)",
            "overwrite_remote": "\(grouped[.overwriteRemote]?.count ?? 0)",
            "move_remote": "\(grouped[.moveRemote]?.count ?? 0)",
            "move_and_overwrite_remote": "\(grouped[.moveAndOverwriteRemote]?.count ?? 0)",
            "delete_remote": "\(grouped[.deleteRemote]?.count ?? 0)",
            "unchanged": "\(grouped[.unchanged]?.count ?? 0)",
            "error": "\(grouped[.error]?.count ?? 0)",
        ]
    }

    // MARK: - accept helpers

    private static func acceptFile(
        _ entry: Entry,
        root: URL,
        cfg: Config,
        state: State,
        force: Bool
    ) async throws {
        guard let stagedPath = entry.stagedPath,
              let remoteHash = entry.remoteHash else {
            throw SyncError.pathNotStaged(entry.relativePath)
        }
        let remoteTabletHash = entry.remoteTabletHash ?? remoteHash
        let stagedURL = appendRelative(stagedPath, to: root)
        let localURL = URL(fileURLWithPath: entry.localPath)
        if FileManager.default.fileExists(atPath: localURL.path),
           !force,
           (try? hashIfExists(localURL)) != entry.localHashAtPull {
            throw SyncError.staleLocal(entry.relativePath)
        }

        let text = try String(contentsOf: stagedURL, encoding: .utf8)
        try PathUtilities.atomicWriteText(text, to: localURL)
        Xattrs.apply(
            Xattrs.FileMetadata(
                docID: entry.docID,
                remotePath: entry.remotePath,
                remoteModified: entry.remoteModified,
                pageIDs: entry.pageIDs
            ),
            to: localURL
        )

        if let byPath = try await state.byLocalPath(localURL.path),
           byPath.docID != entry.docID,
           force {
            try await state.delete(docID: byPath.docID)
        }

        let existing = try await state.get(docID: entry.docID)
        let doc = Document(
            docID: entry.docID,
            parentID: existing?.parentID ?? "",
            docType: "DocumentType",
            remotePath: entry.remotePath,
            localPath: localURL.path,
            remoteVersion: entry.remoteVersion,
            remoteModified: entry.remoteModified,
            lastSyncedMDHash: remoteHash,
            lastSyncedTabletHash: remoteTabletHash,
            lastPullAt: ISO8601.now(),
            lastPushAt: existing?.lastPushAt,
            conflictState: nil,
            errorState: nil,
            pageIDs: entry.pageIDs,
            pendingOp: nil
        )
        try await state.upsert(doc)
        try await state.markPulled(
            docID: entry.docID,
            version: entry.remoteVersion,
            mdHash: remoteHash,
            modified: entry.remoteModified,
            tabletHash: remoteTabletHash
        )
    }

    private static func acceptDelete(
        _ entry: Entry,
        cfg: Config,
        state: State,
        force: Bool
    ) async throws {
        let localURL = URL(fileURLWithPath: entry.localPath)
        if FileManager.default.fileExists(atPath: localURL.path),
           !force,
           (try? hashIfExists(localURL)) != entry.localHashAtPull {
            throw SyncError.staleLocal(entry.relativePath)
        }
        if FileManager.default.fileExists(atPath: localURL.path) {
            _ = try Trash.moveIn(localURL, syncDir: cfg.syncDir)
        }
        try await state.delete(docID: entry.docID)
    }

    // MARK: - push helpers

    @discardableResult
    private static func pushFile(
        _ localURL: URL,
        cfg: Config,
        state: State,
        cloud: any CloudWriteClient,
        force: Bool,
        mode: PushMode = .manual,
        remoteOverride: ForcePushPlanItem? = nil
    ) async throws -> PushFileOutcome {
        guard PathUtilities.resolvedRelativePath(from: cfg.syncDir, to: localURL) != nil else {
            throw SyncError.invalidPath(localURL.path)
        }
        if WatcherFilter.shouldIgnore(localURL.path, root: cfg.syncDir, mode: .markdown) {
            return .skipped
        }

        let stored = try await state.byLocalPath(localURL.path)
        let providerStatus = FileProvider.status(of: localURL)
        if providerStatus.isDataless {
            throw SyncError.localDatalessPlaceholder(displayPath(localURL, syncDir: cfg.syncDir))
        }

        let text = try String(contentsOf: localURL, encoding: .utf8)
        let newHash = PathUtilities.sha256(text)
        let previousHash = stored?.lastSyncedMDHash ?? remoteOverride?.remoteHash
        let previouslyNonEmpty = previousHash.map {
            !$0.isEmpty && $0 != PathUtilities.sha256("")
        } ?? false
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           previouslyNonEmpty {
            throw SyncError.localEmptyWouldOverwrite(displayPath(localURL, syncDir: cfg.syncDir))
        }

        if !force, let stored, stored.lastSyncedMDHash == newHash {
            return .skipped
        }

        if !force, let stored {
            try await ensureCloudStillAtBaseline(
                stored,
                state: state,
                cloud: cloud,
                requireBaseline: mode == .auto
            )
        }

        let tabletText = TabletText.normalizeForTablet(text)
        let tabletHash = PathUtilities.sha256(tabletText)
        let authorUUID = try await state.getOrCreateAuthorUUID()
        let pagesMd = PageSplitter.split(tabletText)
        let targetDocID = remoteOverride?.docID ?? stored?.docID ?? UUID().uuidString.lowercased()
        let reuseIDs: [String]
        if stored?.docID == targetDocID {
            reuseIDs = stored?.pageIDs ?? []
        } else {
            reuseIDs = remoteOverride?.pageIDs ?? stored?.pageIDs ?? []
        }
        var pageIDs: [String] = []
        var pageBytes: [Data] = []
        for (idx, pageText) in pagesMd.enumerated() {
            pageIDs.append(idx < reuseIDs.count ? reuseIDs[idx] : Archive.newPageID())
            pageBytes.append(try PageCodec.renderPage(text: pageText, authorUUID: authorUUID))
        }

        let visible = localURL.deletingPathExtension().lastPathComponent
        let derivation = PathUtilities.localToRemoteParentChain(
            localPath: localURL,
            syncDir: cfg.syncDir,
            remoteFolder: cfg.remoteFolder
        )
        let remoteDocPath = remoteOverride?.remotePath
            ?? stored?.remotePath
            ?? "\(derivation.parentPath)/\(visible)"
        if stored == nil, !force, (try await cloud.stat(remoteDocPath)) != nil {
            throw SyncError.cloudAlreadyHasPath(remoteDocPath)
        }

        for prefix in derivation.mkdirChain { try? await cloud.mkdir(prefix) }

        let tmpDir = Paths.scratchDir
            .appendingPathComponent("rmsync-explicit-push-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let archive = tmpDir.appendingPathComponent("\(visible).rmdoc")
        _ = try await Archive.pack(
            Archive.RmDoc(
                docID: targetDocID,
                visibleName: visible,
                parent: "",
                pages: zip(pageIDs, pageBytes).map {
                    Archive.RmDocPage(pageID: $0.0, rmBytes: $0.1)
                },
                version: (remoteOverride?.remoteVersion ?? stored?.remoteVersion ?? 0) + 1,
                lastModified: Int64(Date().timeIntervalSince1970 * 1000)
            ),
            to: archive
        )

        try await cloud.put(
            local: archive,
            remoteParent: derivation.parentPath,
            update: stored != nil || remoteOverride != nil
        )

        let stat: StatResult?
        if mode == .auto {
            guard let verified = try await cloud.stat(remoteDocPath) else {
                throw SyncError.cloudMissing(remoteDocPath)
            }
            stat = verified
        } else {
            stat = try? await cloud.stat(remoteDocPath)
        }
        let remoteModified = stat?.modifiedClient ?? ""
        let remoteVersion = (remoteOverride?.remoteVersion ?? stored?.remoteVersion ?? 0) + 1
        if let stored, stored.docID != targetDocID, force {
            try await state.delete(docID: stored.docID)
        }
        let existing = try await state.get(docID: targetDocID)
        try await state.upsert(Document(
            docID: targetDocID,
            parentID: existing?.parentID ?? "",
            docType: "DocumentType",
            remotePath: remoteDocPath,
            localPath: localURL.path,
            remoteVersion: remoteVersion,
            remoteModified: remoteModified,
            lastSyncedMDHash: newHash,
            lastSyncedTabletHash: tabletHash,
            lastPullAt: existing?.lastPullAt,
            lastPushAt: ISO8601.now(),
            conflictState: nil,
            errorState: nil,
            pageIDs: pageIDs,
            pendingOp: nil
        ))
        try await state.markPushed(
            docID: targetDocID,
            version: remoteVersion,
            mdHash: newHash,
            modified: remoteModified,
            tabletHash: tabletHash
        )
        if let stat {
            await storeVerifiedRemoteSnapshot(
                docID: targetDocID,
                remotePath: remoteDocPath,
                stat: stat,
                source: text,
                sourceHash: newHash,
                tabletHash: tabletHash,
                pageIDs: pageIDs,
                archive: archive,
                state: state
            )
        }
        return .uploaded
    }

    private static func pushDelete(
        _ localURL: URL,
        state: State,
        cloud: any CloudWriteClient,
        force: Bool
    ) async throws {
        guard let stored = try await state.byLocalPath(localURL.path) else { return }
        if !force {
            try await ensureCloudStillAtBaseline(stored, cloud: cloud)
        }
        try await cloud.rm(stored.remotePath)
        try await state.delete(docID: stored.docID)
    }

    private static func deleteRemoteOnly(
        _ item: ForcePushPlanItem,
        state: State,
        cloud: any CloudWriteClient
    ) async throws {
        guard let remotePath = item.remotePath, let docID = item.docID else {
            throw SyncError.pathNotStaged(item.relativePath)
        }
        try await cloud.rm(remotePath)
        try await state.delete(docID: docID)
    }

    private static func moveRemote(
        _ item: ForcePushPlanItem,
        cfg: Config,
        state: State,
        cloud: any CloudWriteClient
    ) async throws {
        guard let remotePath = item.remotePath,
              let destinationRemotePath = item.destinationRemotePath,
              let docID = item.docID,
              let localPath = item.localPath else {
            throw SyncError.pathNotStaged(item.relativePath)
        }

        let derivation = PathUtilities.localToRemoteParentChain(
            localPath: URL(fileURLWithPath: localPath),
            syncDir: cfg.syncDir,
            remoteFolder: cfg.remoteFolder
        )
        for prefix in derivation.mkdirChain.dropFirst() { try? await cloud.mkdir(prefix) }

        try await cloud.mv(from: remotePath, to: destinationRemotePath)

        let existing = try await state.get(docID: docID)
        try await state.upsert(Document(
            docID: docID,
            parentID: existing?.parentID ?? "",
            docType: "DocumentType",
            remotePath: destinationRemotePath,
            localPath: localPath,
            remoteVersion: item.remoteVersion ?? existing?.remoteVersion ?? 0,
            remoteModified: item.remoteModified ?? existing?.remoteModified,
            lastSyncedMDHash: item.remoteHash ?? existing?.lastSyncedMDHash,
            lastSyncedTabletHash: item.remoteTabletHash ?? existing?.lastSyncedTabletHash,
            lastPullAt: existing?.lastPullAt,
            lastPushAt: existing?.lastPushAt,
            conflictState: nil,
            errorState: nil,
            pageIDs: item.pageIDs,
            pendingOp: nil
        ))
    }

    private static func markRemoteUnchanged(
        _ item: ForcePushPlanItem,
        state: State
    ) async throws {
        guard let docID = item.docID,
              let remotePath = item.remotePath,
              let localPath = item.localPath,
              let remoteVersion = item.remoteVersion,
              let hash = item.remoteHash ?? item.localHash else {
            return
        }
        let tabletHash = item.remoteTabletHash ?? hash
        let existing = try await state.get(docID: docID)
        try await state.upsert(Document(
            docID: docID,
            parentID: existing?.parentID ?? "",
            docType: "DocumentType",
            remotePath: remotePath,
            localPath: localPath,
            remoteVersion: remoteVersion,
            remoteModified: item.remoteModified,
            lastSyncedMDHash: hash,
            lastSyncedTabletHash: tabletHash,
            lastPullAt: existing?.lastPullAt,
            lastPushAt: existing?.lastPushAt,
            conflictState: nil,
            errorState: nil,
            pageIDs: item.pageIDs,
            pendingOp: nil
        ))
    }

    private static func ensureCloudStillAtBaseline(
        _ doc: Document,
        state: State? = nil,
        cloud: any CloudWriteClient,
        requireBaseline: Bool = false
    ) async throws {
        guard let baseline = doc.remoteModified, !baseline.isEmpty else {
            if requireBaseline { throw SyncError.missingRemoteBaseline(doc.localPath) }
            return
        }
        guard let stat = try await cloud.stat(doc.remotePath) else {
            throw SyncError.cloudMissing(doc.remotePath)
        }
        if stat.modifiedClient != baseline {
            throw SyncError.cloudChanged(doc.remotePath)
        }
        if requireBaseline {
            guard let snapshot = try await state?.remoteSnapshot(docID: doc.docID),
                  snapshot.remotePath == doc.remotePath,
                  snapshot.remoteModified == baseline,
                  snapshot.remoteFingerprint == remoteFingerprint(stat, remotePath: doc.remotePath),
                  snapshot.sourceHash == doc.lastSyncedMDHash
            else {
                throw SyncError.missingRemoteBaseline(doc.localPath)
            }
        }
    }

    // MARK: - remote snapshot cache

    private static func storeRemoteSnapshot(
        node: Node,
        rendered: (source: String, sourceHash: String, tabletHash: String),
        pageIDs: [String],
        archive: URL,
        state: State
    ) async {
        let fingerprint = remoteFingerprint(node)
        let cacheURL = remoteCacheURL(docID: node.id, fingerprint: fingerprint)
        do {
            try PathUtilities.atomicWriteText(rendered.source, to: cacheURL)
            let writtenHash = try PathUtilities.sha256File(cacheURL)
            guard writtenHash == rendered.sourceHash else {
                try? FileManager.default.removeItem(at: cacheURL)
                Logger.shared.warn(
                    "remote snapshot cache hash mismatch",
                    meta: ["doc_id": node.id, "path": node.remotePath]
                )
                return
            }

            try await state.upsertRemoteSnapshot(RemoteSnapshot(
                docID: node.id,
                remotePath: node.remotePath,
                remoteModified: remoteModified(node),
                remoteVersion: node.version,
                remoteFingerprint: fingerprint,
                sourceHash: rendered.sourceHash,
                tabletHash: rendered.tabletHash,
                pageIDs: pageIDs,
                cachedSourcePath: cacheURL.path,
                archiveHash: try? PathUtilities.sha256File(archive)
            ))
        } catch {
            Logger.shared.warn(
                "remote snapshot cache write failed",
                meta: ["doc_id": node.id, "path": node.remotePath, "error": "\(error)"]
            )
        }
    }

    static func storeVerifiedRemoteSnapshot(
        docID: String,
        remotePath: String,
        stat: StatResult,
        source: String,
        sourceHash: String,
        tabletHash: String?,
        pageIDs: [String],
        archive: URL?,
        state: State
    ) async {
        let fingerprint = remoteFingerprint(stat, remotePath: remotePath)
        let cacheURL = remoteCacheURL(docID: docID, fingerprint: fingerprint)
        do {
            try PathUtilities.atomicWriteText(source, to: cacheURL)
            let writtenHash = try PathUtilities.sha256File(cacheURL)
            guard writtenHash == sourceHash else {
                try? FileManager.default.removeItem(at: cacheURL)
                Logger.shared.warn(
                    "verified remote snapshot cache hash mismatch",
                    meta: ["doc_id": docID, "path": remotePath]
                )
                return
            }

            try await state.upsertRemoteSnapshot(RemoteSnapshot(
                docID: docID,
                remotePath: remotePath,
                remoteModified: stat.modifiedClient.isEmpty ? nil : stat.modifiedClient,
                remoteVersion: stat.version,
                remoteFingerprint: fingerprint,
                sourceHash: sourceHash,
                tabletHash: tabletHash,
                pageIDs: pageIDs,
                cachedSourcePath: cacheURL.path,
                archiveHash: archive.flatMap { try? PathUtilities.sha256File($0) }
            ))
        } catch {
            Logger.shared.warn(
                "verified remote snapshot cache write failed",
                meta: ["doc_id": docID, "path": remotePath, "error": "\(error)"]
            )
        }
    }

    private static func cachedSourceText(_ snapshot: RemoteSnapshot) -> String? {
        let url = URL(fileURLWithPath: snapshot.cachedSourcePath)
        guard FileManager.default.fileExists(atPath: url.path),
              let text = try? String(contentsOf: url, encoding: .utf8),
              PathUtilities.sha256(text) == snapshot.sourceHash
        else { return nil }
        return text
    }

    private static func remoteCacheURL(docID: String, fingerprint: String) -> URL {
        Paths.remoteCacheDir
            .appendingPathComponent(cacheComponent(docID), isDirectory: true)
            .appendingPathComponent("\(fingerprint).md")
    }

    private static func cacheComponent(_ raw: String) -> String {
        if raw.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil {
            return raw
        }
        return PathUtilities.sha256(raw)
    }

    static func remoteFingerprint(_ node: Node) -> String {
        remoteFingerprint(
            docID: node.id,
            remotePath: node.remotePath,
            name: node.name,
            parent: node.parent,
            type: node.type.rawValue,
            modifiedClient: node.modifiedClient,
            version: node.version,
            currentPage: node.currentPage
        )
    }

    static func remoteFingerprint(_ stat: StatResult, remotePath: String) -> String {
        remoteFingerprint(
            docID: stat.id,
            remotePath: remotePath,
            name: stat.name,
            parent: stat.parent,
            type: stat.type,
            modifiedClient: stat.modifiedClient,
            version: stat.version,
            currentPage: stat.currentPage
        )
    }

    private static func remoteFingerprint(
        docID: String,
        remotePath: String,
        name: String,
        parent: String,
        type: String,
        modifiedClient: String,
        version: Int,
        currentPage: Int
    ) -> String {
        let fields = [
            "doc_id=\(docID)",
            "remote_path=\(remotePath)",
            "name=\(name)",
            "parent=\(parent)",
            "type=\(type)",
            "modified_client=\(modifiedClient)",
            "version=\(version)",
            "current_page=\(currentPage)",
        ]
        return PathUtilities.sha256(fields.joined(separator: "\n"))
    }

    private static func remoteModified(_ node: Node) -> String? {
        node.modifiedClient.isEmpty ? nil : node.modifiedClient
    }

    private static func requiresStagedSource(_ kind: ChangeKind) -> Bool {
        switch kind {
        case .added, .modified, .conflict:
            return true
        case .deleted, .localModified, .unchanged, .error:
            return false
        }
    }

    // MARK: - manifest helpers

    private static func writeManifest(_ manifest: Manifest, root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: root.appendingPathComponent("manifest.json"))
    }

    private static func readManifest(root: URL) throws -> Manifest {
        let data = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    private static func diffText(_ entry: Entry, root: URL) throws -> String {
        let label = entry.kind.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)
        let heading = "\(label) \(entry.relativePath)\n"

        if let error = entry.error, entry.kind == .error {
            return "\(heading)(\(error))\n"
        }

        let fm = FileManager.default
        let localURL = URL(fileURLWithPath: entry.localPath)
        let oldURL: URL?
        let newURL: URL?

        if entry.kind == .deleted {
            oldURL = fm.fileExists(atPath: localURL.path) ? localURL : nil
            newURL = nil
        } else {
            guard let stagedPath = entry.stagedPath else {
                throw SyncError.stagedDiffUnavailable(entry.relativePath)
            }
            let stagedURL = appendRelative(stagedPath, to: root)
            guard fm.fileExists(atPath: stagedURL.path) else {
                throw SyncError.stagedDiffUnavailable(entry.relativePath)
            }
            oldURL = fm.fileExists(atPath: localURL.path) ? localURL : nil
            newURL = stagedURL
        }

        let diff = try unifiedDiff(old: oldURL, new: newURL)
        if diff.isEmpty {
            return entry.kind == .unchanged ? "" : "\(heading)(no text diff)\n"
        }
        return heading + diff
    }

    private static func selectEntries(
        _ entries: [Entry],
        paths: [String],
        all: Bool
    ) throws -> [Entry] {
        if all {
            return entries.filter { $0.kind != .unchanged && $0.kind != .localModified }
        }
        guard !paths.isEmpty else { throw SyncError.noSelection }
        let wanted = Set(paths.map(normalizeSelectionPath))
        var selected: [Entry] = []
        for path in wanted {
            guard let entry = entries.first(where: {
                normalizeSelectionPath($0.relativePath) == path
                    || normalizeSelectionPath($0.localPath) == path
            }) else {
                throw SyncError.pathNotStaged(path)
            }
            selected.append(entry)
        }
        return selected
    }

    // MARK: - classification and paths

    private static func classify(
        docID: String,
        stored: Document?,
        byPath: Document?,
        localHash: String?,
        remoteHash: String,
        baseline: String?
    ) -> ChangeKind {
        if let byPath, byPath.docID != docID { return .conflict }
        guard let localHash else { return .added }
        guard let baseline, !baseline.isEmpty else {
            return localHash == remoteHash ? .unchanged : .conflict
        }
        if remoteHash == baseline {
            return localHash == baseline ? .unchanged : .localModified
        }
        if localHash == baseline { return .modified }
        if localHash == remoteHash { return .unchanged }
        return .conflict
    }

    static func forcePushPlanItems(
        remoteEntries: [Entry],
        localFiles: [LocalFile],
        remoteFolder: String = Config.defaultRemoteFolder,
        renames: [ForcePushRename] = []
    ) -> [ForcePushPlanItem] {
        let remoteDocs = remoteEntries.filter { $0.kind != .deleted }
        var remoteByPath: [String: Entry] = [:]
        for entry in remoteDocs {
            remoteByPath[normalizeSelectionPath(entry.relativePath)] = entry
        }
        var localByPath: [String: LocalFile] = [:]
        for file in localFiles {
            localByPath[normalizeSelectionPath(file.relativePath)] = file
        }
        var allPaths = Set(remoteByPath.keys).union(localByPath.keys)
        var renameByDestination: [String: String] = [:]
        var blockedRenameByDestination: [String: String] = [:]
        for rename in renames {
            let oldPath = normalizeSelectionPath(rename.oldPath)
            let newPath = normalizeSelectionPath(rename.newPath)
            guard remoteByPath[oldPath] != nil,
                  localByPath[newPath] != nil else {
                continue
            }
            if remoteByPath[newPath] != nil {
                blockedRenameByDestination[newPath] = oldPath
                allPaths.remove(oldPath)
                continue
            }
            renameByDestination[newPath] = oldPath
            allPaths.remove(oldPath)
        }

        return allPaths.sorted().map { path in
            let local = localByPath[path]
            let remote = remoteByPath[path]

            if let remote, remote.kind == .error {
                return forcePushItem(
                    action: .error,
                    path: path,
                    local: local,
                    remote: remote,
                    error: remote.error ?? "remote snapshot failed"
                )
            }
            if let source = blockedRenameByDestination[path] {
                return forcePushItem(
                    action: .error,
                    path: path,
                    local: local,
                    remote: remote,
                    sourcePath: source,
                    error: "rename destination already exists on cloud"
                )
            }

            switch (local, remote) {
            case let (.some(local), .some(remote)):
                let action: ForcePushAction = local.hash == remote.remoteHash
                    ? .unchanged
                    : .overwriteRemote
                return forcePushItem(action: action, path: path, local: local, remote: remote)
            case let (.some(local), .none):
                if let source = renameByDestination[path],
                   let sourceRemote = remoteByPath[source] {
                    let action: ForcePushAction = local.hash == sourceRemote.remoteHash
                        ? .moveRemote
                        : .moveAndOverwriteRemote
                    return forcePushItem(
                        action: action,
                        path: path,
                        local: local,
                        remote: sourceRemote,
                        sourcePath: source,
                        destinationRemotePath: remotePath(relativePath: path, remoteFolder: remoteFolder)
                    )
                }
                return forcePushItem(action: .createRemote, path: path, local: local, remote: nil)
            case let (.none, .some(remote)):
                return forcePushItem(action: .deleteRemote, path: path, local: nil, remote: remote)
            case (.none, .none):
                return forcePushItem(action: .error, path: path, local: nil, remote: nil, error: "missing local and remote")
            }
        }
    }

    private static func forcePushItem(
        action: ForcePushAction,
        path: String,
        local: LocalFile?,
        remote: Entry?,
        sourcePath: String? = nil,
        destinationRemotePath: String? = nil,
        error: String? = nil
    ) -> ForcePushPlanItem {
        ForcePushPlanItem(
            action: action,
            relativePath: path,
            sourceRelativePath: sourcePath,
            localPath: local?.url.path,
            remotePath: remote?.remotePath,
            destinationRemotePath: destinationRemotePath,
            docID: remote?.docID,
            remoteModified: remote?.remoteModified,
            remoteVersion: remote?.remoteVersion,
            remoteHash: remote?.remoteHash,
            remoteTabletHash: remote?.remoteTabletHash,
            localHash: local?.hash,
            stagedPath: remote?.stagedPath,
            pageIDs: remote?.pageIDs ?? [],
            error: error
        )
    }

    private static func remotePath(relativePath: String, remoteFolder: String) -> String {
        var rel = normalizeSelectionPath(relativePath)
        if rel.hasSuffix(".md") { rel.removeLast(3) }
        let parts = PathUtilities.remoteFolderSegments(remoteFolder)
            + rel.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        return "/" + parts.joined(separator: "/")
    }

    private static func renderTabletMarkdown(_ rmdoc: Archive.RmDoc) throws -> String {
        var pages: [String] = []
        for page in rmdoc.pages {
            let text = try PageCodec.parsePage(page.rmBytes)
            if !text.isEmpty { pages.append(text) }
        }
        return pages.isEmpty ? "" : PageSplitter.join(pages)
    }

    static func renderSourceMarkdown(
        _ rmdoc: Archive.RmDoc,
        localURL: URL,
        stored: Document?
    ) throws -> (source: String, sourceHash: String, tabletHash: String) {
        let tablet = try renderTabletMarkdown(rmdoc)
        let tabletHash = PathUtilities.sha256(tablet)
        guard let stored else { return (tablet, PathUtilities.sha256(tablet), tabletHash) }

        let localText = try? String(contentsOf: localURL, encoding: .utf8)
        if stored.lastSyncedTabletHash == tabletHash,
           let localText {
            return (
                localText,
                stored.lastSyncedMDHash ?? PathUtilities.sha256(localText),
                tabletHash
            )
        }

        if let localText,
           stored.lastSyncedMDHash == PathUtilities.sha256(localText) {
            let expectedTabletHash = PathUtilities.sha256(TabletText.normalizeForTablet(localText))
            if stored.lastSyncedTabletHash == nil, expectedTabletHash == tabletHash {
                return (localText, PathUtilities.sha256(localText), tabletHash)
            }
            if let translated = TabletText.sourceByApplyingTabletEdit(
                baseSource: localText,
                editedTablet: tablet
            ) {
                return (translated, PathUtilities.sha256(translated), tabletHash)
            }
        }

        return (tablet, PathUtilities.sha256(tablet), tabletHash)
    }

    private static func localPushTargets(cfg: Config, paths: [String]) throws -> [URL] {
        if !paths.isEmpty {
            return paths.map { raw in
                raw.hasPrefix("/")
                    ? URL(fileURLWithPath: raw)
                    : appendRelative(raw, to: cfg.syncDir)
            }
        }

        var urls: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: cfg.syncDir,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return urls }
        for case let url as URL in enumerator {
            if WatcherFilter.shouldIgnore(url.path, root: cfg.syncDir, mode: .markdown) {
                continue
            }
            urls.append(url)
        }
        return urls
    }

    private static func localForcePushFiles(cfg: Config) throws -> [LocalFile] {
        try localPushTargets(cfg: cfg, paths: [])
            .map { url in
                guard let rel = relativePathForLocal(url.path, syncDir: cfg.syncDir) else {
                    throw SyncError.invalidPath(url.path)
                }
                if FileProvider.status(of: url).isDataless {
                    throw SyncError.localDatalessPlaceholder(rel)
                }
                return LocalFile(
                    url: url,
                    relativePath: rel,
                    hash: try PathUtilities.sha256File(url)
                )
            }
    }

    private static func hashIfExists(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try PathUtilities.sha256File(url)
    }

    private static func stageID(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date) + "-" + UUID().uuidString.prefix(8).lowercased()
    }

    private static func relativeMarkdownPath(remotePath: String, remoteFolder: String) -> String {
        let url = PathUtilities.remoteToLocal(
            remotePath: remotePath,
            syncDir: URL(fileURLWithPath: "/", isDirectory: true),
            remoteFolder: remoteFolder
        )
        return url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func relativePathForLocal(_ localPath: String, syncDir: URL) -> String? {
        guard let rel = PathUtilities.resolvedRelativePath(
            from: syncDir,
            to: URL(fileURLWithPath: localPath)
        ) else { return nil }
        return rel.joined(separator: "/")
    }

    private static func appendRelative(_ rel: String, to root: URL) -> URL {
        var url = root
        for part in rel.split(separator: "/", omittingEmptySubsequences: true) {
            url.appendPathComponent(String(part))
        }
        return url
    }

    private static func normalizeSelectionPath(_ path: String) -> String {
        var p = path
        if p.hasPrefix("./") { p.removeFirst(2) }
        while p.hasPrefix("/") { p.removeFirst() }
        return p
    }

    private static func displayPath(_ url: URL, syncDir: URL) -> String {
        relativePathForLocal(url.path, syncDir: syncDir) ?? url.path
    }

    private struct DiffResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private static func unifiedDiff(old: URL?, new: URL?) throws -> String {
        let result = try runDiff(args: ["-u", old?.path ?? "/dev/null", new?.path ?? "/dev/null"])
        if result.exitCode == 0 || result.exitCode == 1 {
            return result.stdout
        }
        throw SyncError.diffFailed(exitCode: result.exitCode, stderr: result.stderr)
    }

    private static func runDiff(args: [String]) throws -> DiffResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return DiffResult(
            exitCode: proc.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
