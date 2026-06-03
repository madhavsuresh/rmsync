import Foundation

enum GitSync {
    struct RepoConfig: Codable, Sendable {
        var name: String
        var syncRoot: String
        var remoteRoot: String

        var remoteFolder: String { "\(remoteRoot)/\(name)" }
        var cloudRef: String { "refs/rmsync-git/\(name)/cloud" }
        var lastRemoteSnapshotRef: String { "refs/rmsync-git/\(name)/last-remote-snapshot" }
    }

    struct InitResult: Sendable {
        var name: String
        var remotePath: String
        var cloudBase: String
    }

    struct PullResult: Sendable {
        var branch: String
        var snapshot: String
        var stageID: String
        var changed: Int
    }

    struct PushResult: Sendable {
        var target: String
        var remoteSnapshot: String
        var created: Int
        var moved: Int
        var overwritten: Int
        var deleted: Int
        var unchanged: Int
        var mergeCommit: String?
        var dryRun: Bool
    }

    struct PushManifest: Codable, Sendable {
        var id: String
        var target: String
        var remoteSnapshot: String
        var createdAt: String
        var items: [ManifestItem]
        var refusals: [String]
    }

    struct ManifestItem: Codable, Sendable {
        var path: String
        var action: String
        var status: String
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case alreadyInitialized(URL)
        case notInitialized(URL)
        case invalidName(String)
        case invalidSyncRoot(String)
        case remoteFolderExists(String)
        case cloudSnapshotFailed([String])
        case pushConflict(branch: String, detail: String)
        case verificationFailed(URL)

        var description: String {
            switch self {
            case .alreadyInitialized(let url):
                return "rmsync-git is already initialized at \(url.path)"
            case .notInitialized(let url):
                return "rmsync-git is not initialized; expected config at \(url.path)"
            case .invalidName(let name):
                return "invalid rmsync-git name '\(name)'; use one remote folder segment without slashes"
            case .invalidSyncRoot(let path):
                return "sync root must be inside the git repository: \(path)"
            case .remoteFolderExists(let path):
                return "\(path) already exists on the reMarkable cloud"
            case .cloudSnapshotFailed(let errors):
                return "cloud snapshot failed:\n" + errors.joined(separator: "\n")
            case .pushConflict(let branch, let detail):
                return """
                push cannot merge cleanly without conflict.
                cloud branch: \(branch)

                Resolve with normal git, then retry:
                    git merge \(branch)
                    # edit conflicts, git add, git commit
                    rmsync git push

                \(detail)
                """
            case .verificationFailed(let manifest):
                return "cloud upload did not verify cleanly; recovery manifest written to \(manifest.path)"
            }
        }
    }

    static func initialize(
        cwd: URL,
        name rawName: String?,
        syncRoot rawSyncRoot: String,
        remoteRoot: String,
        cloud: any CloudWriteClient = Cloud()
    ) async throws -> InitResult {
        let git = try await Git.open(at: cwd)
        let common = try await git.commonDir()
        let root = stateRoot(common: common)
        let configPath = configURL(common: common)
        if FileManager.default.fileExists(atPath: configPath.path) {
            throw Error.alreadyInitialized(configPath)
        }

        let name = rawName ?? git.root.lastPathComponent
        try validateName(name)
        let syncRoot = try normalizedSyncRoot(rawSyncRoot, git: git)
        let cfg = RepoConfig(name: name, syncRoot: syncRoot, remoteRoot: normalizeRemoteRoot(remoteRoot))
        let remotePath = "/\(cfg.remoteFolder)"

        try await ensureRemoteFolderIsNew(cfg: cfg, cloud: cloud)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeConfig(cfg, common: common)

        let head = try await git.headCommit()
        let initialTree = try await createSnapshotTree(git: git, baseCommit: head, cfg: cfg, files: [])
        let initialCommit = try await git.commitTree(
            initialTree,
            parents: [head],
            message: "rmsync-git: initialize empty cloud snapshot for \(name)\n"
        )
        try await git.updateRef(cfg.cloudRef, to: initialCommit)

        return InitResult(name: name, remotePath: remotePath, cloudBase: initialCommit)
    }

    static func pull(cwd: URL, cloud: any CloudClient = Cloud()) async throws -> PullResult {
        let git = try await Git.open(at: cwd)
        let loaded = try await load(git: git)
        guard try await git.refExists(loaded.cfg.cloudRef) else {
            throw Error.notInitialized(loaded.configURL)
        }

        let base = try await git.run(["rev-parse", loaded.cfg.cloudRef])
        let staged = try await stageCurrentCloud(git: git, cfg: loaded.cfg, baseCommit: base, cloud: cloud)
        let remoteSnapshot = try await createSnapshotCommit(
            git: git,
            baseCommit: base,
            cfg: loaded.cfg,
            stage: staged.stage,
            message: "rmsync-git: cloud snapshot for \(loaded.cfg.name)\n"
        )
        try await git.updateRef(loaded.cfg.lastRemoteSnapshotRef, to: remoteSnapshot)

        let branch = try await uniqueBranchName(git: git, name: loaded.cfg.name)
        try await git.createBranch(branch, at: remoteSnapshot)
        let changed = staged.stage.entries.filter { $0.kind != .unchanged }.count
        return PullResult(
            branch: branch,
            snapshot: remoteSnapshot,
            stageID: staged.stage.id,
            changed: changed
        )
    }

    static func push(
        cwd: URL,
        dryRun: Bool,
        allowDirty: Bool,
        cloud: any CloudWriteClient = Cloud()
    ) async throws -> PushResult {
        let git = try await Git.open(at: cwd)
        let loaded = try await load(git: git)
        guard try await git.refExists(loaded.cfg.cloudRef) else {
            throw Error.notInitialized(loaded.configURL)
        }
        if !allowDirty {
            try await git.requireCleanWorktree()
        }

        let base = try await git.run(["rev-parse", loaded.cfg.cloudRef])
        let local = try await git.headCommit()
        let remote = try await stageCurrentCloud(git: git, cfg: loaded.cfg, baseCommit: base, cloud: cloud)
        let remoteSnapshot = try await createSnapshotCommit(
            git: git,
            baseCommit: base,
            cfg: loaded.cfg,
            stage: remote.stage,
            message: "rmsync-git: current cloud snapshot for \(loaded.cfg.name)\n"
        )
        try await git.updateRef(loaded.cfg.lastRemoteSnapshotRef, to: remoteSnapshot)

        let localTree = try await git.tree(local)
        let remoteTree = try await git.tree(remoteSnapshot)
        if localTree == remoteTree {
            if !dryRun {
                try await git.updateRef(loaded.cfg.cloudRef, to: local)
            }
            return PushResult(
                target: local,
                remoteSnapshot: remoteSnapshot,
                created: 0,
                moved: 0,
                overwritten: 0,
                deleted: 0,
                unchanged: remote.stage.entries.count,
                mergeCommit: nil,
                dryRun: dryRun
            )
        }

        let merge: Git.MergeTreeResult
        do {
            merge = try await git.mergeTree(base: base, local: local, remote: remoteSnapshot)
        } catch let error as Git.GitError {
            let branch = try await uniqueBranchName(git: git, name: loaded.cfg.name)
            try await git.createBranch(branch, at: remoteSnapshot)
            throw Error.pushConflict(branch: branch, detail: error.description)
        }

        let target: String
        let mergeCommit: String?
        if merge.tree == localTree {
            target = local
            mergeCommit = nil
        } else {
            let commit = try await git.commitTree(
                merge.tree,
                parents: [local, remoteSnapshot],
                message: "rmsync-git: merge cloud changes for \(loaded.cfg.name)\n"
            )
            mergeCommit = commit
            target = commit
            if !dryRun {
                try await git.requireCleanWorktree()
                let branch = try await git.currentBranch() ?? { throw Git.GitError.detachedHead }()
                try await git.updateRef("refs/heads/\(branch)", to: commit, expectedOld: local)
                try await git.resetHard(commit)
            }
        }

        let renames = try await forcePushRenames(git: git, base: base, target: target, cfg: loaded.cfg)
        let targetSync = try await materializeSyncTree(git: git, commit: target, cfg: loaded.cfg)
        let targetCfg = Config(syncDir: targetSync, remoteFolder: loaded.cfg.remoteFolder)
        let state = try State(path: stateDBURL(common: loaded.common))
        let plan = try await ExplicitSync.planForcePush(
            cfg: targetCfg,
            state: state,
            cloud: cloud,
            stagingDir: stagingDir(common: loaded.common),
            renames: renames
        )

        if dryRun {
            ExplicitSync.printForcePushPlan(plan.items)
            return PushResult(
                target: target,
                remoteSnapshot: remoteSnapshot,
                created: plan.items.filter { $0.action == .createRemote }.count,
                moved: plan.items.filter {
                    $0.action == .moveRemote || $0.action == .moveAndOverwriteRemote
                }.count,
                overwritten: plan.items.filter {
                    $0.action == .overwriteRemote || $0.action == .moveAndOverwriteRemote
                }.count,
                deleted: plan.items.filter { $0.action == .deleteRemote }.count,
                unchanged: plan.items.filter { $0.action == .unchanged }.count,
                mergeCommit: mergeCommit,
                dryRun: true
            )
        }

        let applied = try await ExplicitSync.applyForcePush(
            plan,
            cfg: targetCfg,
            state: state,
            cloud: cloud
        )
        if !applied.refused.isEmpty {
            let manifest = try writePushManifest(
                common: loaded.common,
                target: target,
                remoteSnapshot: remoteSnapshot,
                plan: plan.items,
                refusals: applied.refused
            )
            throw Error.verificationFailed(manifest)
        }

        let verifyPlan = try await ExplicitSync.planForcePush(
            cfg: targetCfg,
            state: state,
            cloud: cloud,
            stagingDir: stagingDir(common: loaded.common)
        )
        let notUnchanged = verifyPlan.items.filter { $0.action != .unchanged }
        if !notUnchanged.isEmpty {
            let manifest = try writePushManifest(
                common: loaded.common,
                target: target,
                remoteSnapshot: remoteSnapshot,
                plan: verifyPlan.items,
                refusals: notUnchanged.map { "\($0.relativePath): still \($0.action.rawValue) after upload" }
            )
            throw Error.verificationFailed(manifest)
        }

        try await git.updateRef(loaded.cfg.cloudRef, to: target)
        return PushResult(
            target: target,
            remoteSnapshot: remoteSnapshot,
            created: applied.created,
            moved: applied.moved,
            overwritten: applied.overwritten,
            deleted: applied.deleted,
            unchanged: applied.unchanged,
            mergeCommit: mergeCommit,
            dryRun: false
        )
    }

    // MARK: - git snapshot helpers

    struct SnapshotFile: Sendable {
        var relativePath: String
        var source: Git.TreeSource

        init(relativePath: String, file: URL) {
            self.relativePath = relativePath
            self.source = .file(file)
        }

        init(relativePath: String, blob: String) {
            self.relativePath = relativePath
            self.source = .blob(blob)
        }
    }

    static func createSnapshotCommit(
        git: Git,
        baseCommit: String,
        cfg: RepoConfig,
        stage: ExplicitSync.StageResult,
        message: String
    ) async throws -> String {
        var files: [SnapshotFile] = []
        for entry in stage.entries {
            if entry.kind == .error {
                throw Error.cloudSnapshotFailed(["\(entry.relativePath): \(entry.error ?? "unknown error")"])
            }
            if entry.kind == .deleted {
                continue
            }
            if let stagedPath = entry.stagedPath {
                files.append(SnapshotFile(
                    relativePath: entry.relativePath,
                    file: appendRelative(stagedPath, to: stage.root)
                ))
                continue
            }

            guard entry.kind == .unchanged || entry.kind == .localModified else {
                throw Error.cloudSnapshotFailed([
                    "\(entry.relativePath): staged source missing for \(entry.kind.rawValue)"
                ])
            }
            let path = repoPath(syncRoot: cfg.syncRoot, relativePath: entry.relativePath)
            files.append(SnapshotFile(
                relativePath: entry.relativePath,
                blob: try await git.blobID(baseCommit, path: path)
            ))
        }
        let tree = try await createSnapshotTree(
            git: git,
            baseCommit: baseCommit,
            cfg: cfg,
            files: files
        )
        return try await git.commitTree(tree, parents: [baseCommit], message: message)
    }

    static func createSnapshotTree(
        git: Git,
        baseCommit: String,
        cfg: RepoConfig,
        files: [SnapshotFile]
    ) async throws -> String {
        let removed = try await syncedMarkdownPaths(git: git, commit: baseCommit, cfg: cfg)
        let added = files.map { file in
            Git.TreeAddition(
                path: repoPath(syncRoot: cfg.syncRoot, relativePath: file.relativePath),
                source: file.source
            )
        }
        return try await git.writeTree(baseCommit: baseCommit, removing: removed, adding: added)
    }

    static func materializeSyncTree(git: Git, commit: String, cfg: RepoConfig) async throws -> URL {
        let common = try await git.commonDir()
        let root = common
            .appendingPathComponent("rmsync-git", isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let paths = try await syncedMarkdownPaths(git: git, commit: commit, cfg: cfg)
        for path in paths {
            let rel = syncRelativePath(syncRoot: cfg.syncRoot, repoPath: path)
            let out = appendRelative(rel, to: root)
            let text = try await git.show(commit, path: path)
            try PathUtilities.atomicWriteText(text, to: out)
        }
        return root
    }

    static func syncedMarkdownPaths(git: Git, commit: String, cfg: RepoConfig) async throws -> [String] {
        let pathspec = cfg.syncRoot == "." ? nil : cfg.syncRoot
        return try await git.listTreePaths(commit, under: pathspec)
            .filter { isSyncedMarkdown(repoPath: $0, syncRoot: cfg.syncRoot) }
    }

    private static func forcePushRenames(
        git: Git,
        base: String,
        target: String,
        cfg: RepoConfig
    ) async throws -> [ExplicitSync.ForcePushRename] {
        let pathspec = cfg.syncRoot == "." ? nil : cfg.syncRoot
        return try await git.renamedPaths(from: base, to: target, under: pathspec)
            .filter {
                isSyncedMarkdown(repoPath: $0.oldPath, syncRoot: cfg.syncRoot)
                    && isSyncedMarkdown(repoPath: $0.newPath, syncRoot: cfg.syncRoot)
            }
            .map {
                ExplicitSync.ForcePushRename(
                    oldPath: syncRelativePath(syncRoot: cfg.syncRoot, repoPath: $0.oldPath),
                    newPath: syncRelativePath(syncRoot: cfg.syncRoot, repoPath: $0.newPath)
                )
            }
    }

    // MARK: - cloud staging

    private static func stageCurrentCloud(
        git: Git,
        cfg: RepoConfig,
        baseCommit: String,
        cloud: any CloudClient
    ) async throws -> (syncDir: URL, stage: ExplicitSync.StageResult) {
        let syncDir = try await materializeSyncTree(git: git, commit: baseCommit, cfg: cfg)
        let explicitCfg = Config(syncDir: syncDir, remoteFolder: cfg.remoteFolder)
        let common = try await git.commonDir()
        let state = try State(path: stateDBURL(common: common))
        let stage = try await ExplicitSync.stagePull(
            cfg: explicitCfg,
            state: state,
            cloud: cloud,
            stagingDir: stagingDir(common: common)
        )
        let errors = stage.entries.compactMap { entry in
            entry.kind == .error ? "\(entry.relativePath): \(entry.error ?? "unknown error")" : nil
        }
        if !errors.isEmpty { throw Error.cloudSnapshotFailed(errors) }
        return (syncDir, stage)
    }

    private static func ensureRemoteFolderIsNew(cfg: RepoConfig, cloud: any CloudWriteClient) async throws {
        do {
            try await cloud.mkdir("/\(cfg.remoteRoot)")
        } catch {
            // rmapi mkdir is not idempotent; an existing remote root is fine.
        }
        if try await cloud.stat("/\(cfg.remoteFolder)") != nil {
            throw Error.remoteFolderExists("/\(cfg.remoteFolder)")
        }
        try await cloud.mkdir("/\(cfg.remoteFolder)")
    }

    // MARK: - config and paths

    private static func load(git: Git) async throws -> (cfg: RepoConfig, common: URL, configURL: URL) {
        let common = try await git.commonDir()
        let url = configURL(common: common)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Error.notInitialized(url)
        }
        let data = try Data(contentsOf: url)
        return (try JSONDecoder().decode(RepoConfig.self, from: data), common, url)
    }

    private static func writeConfig(_ cfg: RepoConfig, common: URL) throws {
        let url = configURL(common: common)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(cfg).write(to: url)
    }

    private static func writePushManifest(
        common: URL,
        target: String,
        remoteSnapshot: String,
        plan: [ExplicitSync.ForcePushPlanItem],
        refusals: [String]
    ) throws -> URL {
        let id = "\(timestamp())-\(UUID().uuidString.prefix(8).lowercased())"
        let dir = stateRoot(common: common)
            .appendingPathComponent("pushes", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = PushManifest(
            id: id,
            target: target,
            remoteSnapshot: remoteSnapshot,
            createdAt: ISO8601.now(),
            items: plan.map {
                ManifestItem(
                    path: $0.relativePath,
                    action: $0.action.rawValue,
                    status: $0.action == .unchanged ? "verified" : "pending"
                )
            },
            refusals: refusals
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let out = dir.appendingPathComponent("manifest.json")
        try encoder.encode(manifest).write(to: out)
        return out
    }

    static func stateRoot(common: URL) -> URL {
        common.appendingPathComponent("rmsync-git", isDirectory: true)
    }

    static func configURL(common: URL) -> URL {
        stateRoot(common: common).appendingPathComponent("config.json")
    }

    static func configuredRepository(containing url: URL) async -> (root: URL, configURL: URL)? {
        do {
            let git = try await Git.open(at: url)
            let common = try await git.commonDir()
            let config = configURL(common: common)
            guard FileManager.default.fileExists(atPath: config.path) else { return nil }
            return (git.root, config)
        } catch {
            return nil
        }
    }

    static func stateDBURL(common: URL) -> URL {
        stateRoot(common: common)
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("state.db")
    }

    static func stagingDir(common: URL) -> URL {
        stateRoot(common: common).appendingPathComponent("staging", isDirectory: true)
    }

    static func normalizedSyncRoot(_ raw: String, git: Git) throws -> String {
        let expanded = NSString(string: raw).expandingTildeInPath
        let url = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded, isDirectory: true)
            : git.root.appendingPathComponent(expanded, isDirectory: true)
        let root = git.root.standardizedFileURL.resolvingSymlinksInPath()
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        if target.path == root.path { return "." }
        guard let rel = PathUtilities.resolvedRelativePath(from: root, to: target) else {
            throw Error.invalidSyncRoot(raw)
        }
        return rel.joined(separator: "/")
    }

    static func validateName(_ name: String) throws {
        if name.isEmpty || name.contains("/") || name == "." || name == ".." {
            throw Error.invalidName(name)
        }
    }

    static func normalizeRemoteRoot(_ raw: String) -> String {
        raw.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
    }

    static func repoPath(syncRoot: String, relativePath: String) -> String {
        if syncRoot == "." { return normalizeRelative(relativePath) }
        return "\(syncRoot)/\(normalizeRelative(relativePath))"
    }

    static func syncRelativePath(syncRoot: String, repoPath: String) -> String {
        if syncRoot == "." { return normalizeRelative(repoPath) }
        let prefix = syncRoot + "/"
        if repoPath.hasPrefix(prefix) {
            return String(repoPath.dropFirst(prefix.count))
        }
        return normalizeRelative(repoPath)
    }

    static func isSyncedMarkdown(repoPath: String, syncRoot: String) -> Bool {
        let rel = syncRelativePath(syncRoot: syncRoot, repoPath: repoPath)
        guard rel.hasSuffix(".md") else { return false }
        for component in rel.split(separator: "/") {
            if component.hasPrefix(".") { return false }
        }
        return true
    }

    static func uniqueBranchName(git: Git, name: String) async throws -> String {
        let base = "rmsync/cloud/\(name)/\(timestamp())"
        var candidate = "\(base)-\(UUID().uuidString.prefix(8).lowercased())"
        while try await git.refExists("refs/heads/\(candidate)") {
            candidate = "\(base)-\(UUID().uuidString.prefix(8).lowercased())"
        }
        return candidate
    }

    private static func normalizeRelative(_ path: String) -> String {
        var p = path
        while p.hasPrefix("./") { p.removeFirst(2) }
        while p.hasPrefix("/") { p.removeFirst() }
        return p
    }

    private static func appendRelative(_ rel: String, to root: URL) -> URL {
        var url = root
        for part in rel.split(separator: "/", omittingEmptySubsequences: true) {
            url.appendPathComponent(String(part))
        }
        return url
    }

    private static func timestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }
}
