import Foundation
import Testing
@testable import rmsync

@Suite("rmsync-git synthetic merge workflow")
struct GitSyncSyntheticTests {
    @Test("git merge-tree handles clean edits, conflicts, deletes, and partial retry")
    func mergeScenarios() async throws {
        try await cleanIndependentEdits()
        try await sameLineConflict()
        try await cleanDelete()
        try await deleteModifyConflict()
        try await partialRetry()
        try await ambiguousAlreadyMatchesHead()
    }

    @Test("materializing a git tree preserves source bytes")
    func materializePreservesSourceBytes() async throws {
        let repo = try await makeRepo("source-preserve")
        let source = "heading  \n\nbody without final newline"
        try write(source, to: repo.appendingPathComponent("note.md"))
        try await commitAll(repo, "base")

        let git = try await Git.open(at: repo)
        let head = try await git.headCommit()
        let cfg = GitSync.RepoConfig(name: "source-preserve", syncRoot: ".", remoteRoot: "sync")
        let sync = try await GitSync.materializeSyncTree(git: git, commit: head, cfg: cfg)
        let out = try String(contentsOf: sync.appendingPathComponent("note.md"), encoding: .utf8)
        #expect(out == source)
    }

    @Test("git rename detection reports synced markdown moves")
    func gitRenameDetectionReportsMarkdownMove() async throws {
        let repo = try await makeRepo("rename-detection")
        try write("same\n", to: repo.appendingPathComponent("old.md"))
        try await commitAll(repo, "base")

        let git = try await Git.open(at: repo)
        let base = try await git.headCommit()
        try FileManager.default.moveItem(
            at: repo.appendingPathComponent("old.md"),
            to: repo.appendingPathComponent("new.md")
        )
        try await commitAll(repo, "move")
        let target = try await git.headCommit()

        let renames = try await git.renamedPaths(from: base, to: target)
        #expect(renames == [Git.Rename(oldPath: "old.md", newPath: "new.md")])
    }

    @Test("cloud snapshots replace only synced markdown paths")
    func cloudSnapshotTreeScopesMarkdownReplacement() async throws {
        let repo = try await makeRepo("snapshot-tree")
        try write("keep\n", to: repo.appendingPathComponent("keep.txt"))
        try write("old root\n", to: repo.appendingPathComponent("docs/old.md"))
        try write("old nested\n", to: repo.appendingPathComponent("docs/nested/old.md"))
        try await commitAll(repo, "base")

        let cloud = try scratchRoot()
            .appendingPathComponent("rmsync-git-cloud-\(UUID().uuidString)", isDirectory: true)
        try write("new root\n", to: cloud.appendingPathComponent("new.md"))
        try write("new nested\n", to: cloud.appendingPathComponent("nested/new.md"))

        let git = try await Git.open(at: repo)
        let head = try await git.headCommit()
        let cfg = GitSync.RepoConfig(name: "snapshot-tree", syncRoot: "docs", remoteRoot: "sync")
        let tree = try await GitSync.createSnapshotTree(
            git: git,
            baseCommit: head,
            cfg: cfg,
            files: [
                GitSync.SnapshotFile(relativePath: "new.md", file: cloud.appendingPathComponent("new.md")),
                GitSync.SnapshotFile(relativePath: "nested/new.md", file: cloud.appendingPathComponent("nested/new.md")),
            ]
        )

        #expect(try await git.show(tree, path: "keep.txt") == "keep\n")
        #expect(try await git.show(tree, path: "docs/new.md") == "new root\n")
        #expect(try await git.show(tree, path: "docs/nested/new.md") == "new nested\n")
        #expect(try await pathExists(git: git, tree: tree, path: "docs/old.md") == false)
        #expect(try await pathExists(git: git, tree: tree, path: "docs/nested/old.md") == false)
    }

    @Test("cloud snapshot commit preserves unchanged entries without staged files")
    func cloudSnapshotCommitPreservesUnstagedUnchangedEntries() async throws {
        let repo = try await makeRepo("snapshot-commit")
        try write("base a\n", to: repo.appendingPathComponent("a.md"))
        try write("base b\n", to: repo.appendingPathComponent("b.md"))
        try await commitAll(repo, "base")

        let git = try await Git.open(at: repo)
        let base = try await git.headCommit()
        let stageRoot = try scratchRoot()
            .appendingPathComponent("rmsync-git-stage-\(UUID().uuidString)", isDirectory: true)
        try write("cloud b\n", to: stageRoot.appendingPathComponent("files/b.md"))
        let stage = ExplicitSync.StageResult(
            id: "stage",
            root: stageRoot,
            entries: [
                stageEntry(kind: .unchanged, relativePath: "a.md", stagedPath: nil, repo: repo),
                stageEntry(kind: .modified, relativePath: "b.md", stagedPath: "files/b.md", repo: repo),
            ]
        )
        let cfg = GitSync.RepoConfig(name: "snapshot-commit", syncRoot: ".", remoteRoot: "sync")

        let commit = try await GitSync.createSnapshotCommit(
            git: git,
            baseCommit: base,
            cfg: cfg,
            stage: stage,
            message: "snapshot\n"
        )

        #expect(try await git.show(commit, path: "a.md") == "base a\n")
        #expect(try await git.show(commit, path: "b.md") == "cloud b\n")
    }

    @Test("git init defaults to sync git namespace")
    func gitInitDefaultsToSyncGitNamespace() async throws {
        let repo = try await makeRepo("default-remote")
        try write("base\n", to: repo.appendingPathComponent("base.md"))
        try await commitAll(repo, "base")
        let cloud = RecordingGitInitCloud()

        let result = try await GitSync.initialize(
            cwd: repo,
            name: nil,
            syncRoot: ".",
            remoteRoot: GitSync.defaultRemoteRoot,
            ordinaryRemoteFolder: Config.defaultRemoteFolder,
            cloud: cloud
        )

        #expect(result.name == "default-remote")
        #expect(result.remotePath == "/sync/git/default-remote")
        #expect(await cloud.createdPaths() == [
            "/sync", "/sync/git", "/sync/git/default-remote",
        ])
    }

    @Test("git init refuses target nested below ordinary sync namespace")
    func gitInitRefusesOrdinarySyncRootOverlap() async throws {
        let repo = try await makeRepo("overlap")
        try write("base\n", to: repo.appendingPathComponent("base.md"))
        try await commitAll(repo, "base")

        do {
            _ = try await GitSync.initialize(
                cwd: repo,
                name: "draft",
                syncRoot: ".",
                remoteRoot: GitSync.defaultRemoteRoot,
                ordinaryRemoteFolder: "sync",
                cloud: RecordingGitInitCloud()
            )
            Issue.record("git init succeeded even though ordinary sync owns /sync")
        } catch let error as GitSync.Error {
            switch error {
            case .remoteNamespaceConflict(let target, let ordinary):
                #expect(target == "sync/git/draft")
                #expect(ordinary == "sync")
            default:
                Issue.record("unexpected GitSync error: \(error)")
            }
        }
    }

    @Test("git init allows sync notes and sync git sibling namespaces")
    func gitInitAllowsSiblingNamespaces() async throws {
        let repo = try await makeRepo("sibling")
        try write("base\n", to: repo.appendingPathComponent("base.md"))
        try await commitAll(repo, "base")

        let result = try await GitSync.initialize(
            cwd: repo,
            name: "draft",
            syncRoot: ".",
            remoteRoot: GitSync.defaultRemoteRoot,
            ordinaryRemoteFolder: Config.defaultRemoteFolder,
            cloud: RecordingGitInitCloud()
        )

        #expect(result.remotePath == "/sync/git/draft")
    }

    private func cleanIndependentEdits() async throws {
        let repo = try await makeRepo("clean-independent")
        try write("base a\n", to: repo.appendingPathComponent("a.md"))
        try write("base b\n", to: repo.appendingPathComponent("b.md"))
        try await commitAll(repo, "base")
        let git = try await Git.open(at: repo)
        let base = try await git.headCommit()

        _ = try await git.run(["branch", "cloud-current", base])
        try write("local a\n", to: repo.appendingPathComponent("a.md"))
        try await commitAll(repo, "local-a")
        let local = try await git.headCommit()

        _ = try await git.run(["switch", "-q", "cloud-current"])
        try write("cloud b\n", to: repo.appendingPathComponent("b.md"))
        try await commitAll(repo, "cloud-b")
        let remote = try await git.headCommit()
        _ = try await git.run(["switch", "-q", "main"])

        let merged = try await git.mergeTree(base: base, local: local, remote: remote)
        #expect(try await git.show(merged.tree, path: "a.md") == "local a\n")
        #expect(try await git.show(merged.tree, path: "b.md") == "cloud b\n")
    }

    private func sameLineConflict() async throws {
        let repo = try await makeRepo("same-line-conflict")
        try write("base\n", to: repo.appendingPathComponent("a.md"))
        try await commitAll(repo, "base")
        let git = try await Git.open(at: repo)
        let base = try await git.headCommit()
        _ = try await git.run(["branch", "cloud-current", base])

        try write("local\n", to: repo.appendingPathComponent("a.md"))
        try await commitAll(repo, "local")
        let local = try await git.headCommit()

        _ = try await git.run(["switch", "-q", "cloud-current"])
        try write("cloud\n", to: repo.appendingPathComponent("a.md"))
        try await commitAll(repo, "cloud")
        let remote = try await git.headCommit()

        do {
            _ = try await git.mergeTree(base: base, local: local, remote: remote)
            Issue.record("same-line conflict merged cleanly")
        } catch Git.GitError.mergeConflict(_) {
            // expected
        }
    }

    private func cleanDelete() async throws {
        let repo = try await makeRepo("delete-clean")
        try write("base a\n", to: repo.appendingPathComponent("a.md"))
        try write("base b\n", to: repo.appendingPathComponent("b.md"))
        try await commitAll(repo, "base")
        let git = try await Git.open(at: repo)
        let base = try await git.headCommit()
        _ = try await git.run(["branch", "cloud-current", base])

        try FileManager.default.removeItem(at: repo.appendingPathComponent("a.md"))
        try await commitAll(repo, "delete-a")
        let local = try await git.headCommit()

        _ = try await git.run(["switch", "-q", "cloud-current"])
        try write("cloud b\n", to: repo.appendingPathComponent("b.md"))
        try await commitAll(repo, "cloud-b")
        let remote = try await git.headCommit()

        let merged = try await git.mergeTree(base: base, local: local, remote: remote)
        #expect(try await git.show(merged.tree, path: "b.md") == "cloud b\n")
        #expect(try await pathExists(git: git, tree: merged.tree, path: "a.md") == false)
    }

    private func deleteModifyConflict() async throws {
        let repo = try await makeRepo("delete-modify-conflict")
        try write("base a\n", to: repo.appendingPathComponent("a.md"))
        try await commitAll(repo, "base")
        let git = try await Git.open(at: repo)
        let base = try await git.headCommit()
        _ = try await git.run(["branch", "cloud-current", base])

        try FileManager.default.removeItem(at: repo.appendingPathComponent("a.md"))
        try await commitAll(repo, "delete-a")
        let local = try await git.headCommit()

        _ = try await git.run(["switch", "-q", "cloud-current"])
        try write("cloud a\n", to: repo.appendingPathComponent("a.md"))
        try await commitAll(repo, "cloud-a")
        let remote = try await git.headCommit()

        do {
            _ = try await git.mergeTree(base: base, local: local, remote: remote)
            Issue.record("delete/modify conflict merged cleanly")
        } catch Git.GitError.mergeConflict(_) {
            // expected
        }
    }

    private func partialRetry() async throws {
        let repo = try await makeRepo("partial-retry")
        try write("base a\n", to: repo.appendingPathComponent("a.md"))
        try write("base b\n", to: repo.appendingPathComponent("b.md"))
        try await commitAll(repo, "base")
        let git = try await Git.open(at: repo)
        let base = try await git.headCommit()
        _ = try await git.run(["branch", "cloud-current", base])

        try write("local a\n", to: repo.appendingPathComponent("a.md"))
        try write("local b\n", to: repo.appendingPathComponent("b.md"))
        try await commitAll(repo, "local-both")
        let local = try await git.headCommit()

        _ = try await git.run(["switch", "-q", "cloud-current"])
        try write("local a\n", to: repo.appendingPathComponent("a.md"))
        try await commitAll(repo, "partial-a-uploaded")
        let remote = try await git.headCommit()

        let merged = try await git.mergeTree(base: base, local: local, remote: remote)
        #expect(try await git.show(merged.tree, path: "a.md") == "local a\n")
        #expect(try await git.show(merged.tree, path: "b.md") == "local b\n")
    }

    private func ambiguousAlreadyMatchesHead() async throws {
        let repo = try await makeRepo("already-matches")
        try write("base a\n", to: repo.appendingPathComponent("a.md"))
        try await commitAll(repo, "base")
        let git = try await Git.open(at: repo)
        let base = try await git.headCommit()
        _ = try await git.run(["branch", "cloud-current", base])

        try write("local a\n", to: repo.appendingPathComponent("a.md"))
        try await commitAll(repo, "local-a")
        let local = try await git.headCommit()

        _ = try await git.run(["switch", "-q", "cloud-current"])
        try write("local a\n", to: repo.appendingPathComponent("a.md"))
        try await commitAll(repo, "cloud-already-local")
        let remote = try await git.headCommit()

        let localTree = try await git.tree(local)
        let remoteTree = try await git.tree(remote)
        #expect(localTree == remoteTree)
    }

    private func makeRepo(_ name: String) async throws -> URL {
        let root = try scratchRoot()
            .appendingPathComponent("rmsync-git-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await runGit(["init", "-q", "-b", "main"], cwd: root)
        try await runGit(["config", "user.name", "rmsync-git synthetic"], cwd: root)
        try await runGit(["config", "user.email", "rmsync-git@example.invalid"], cwd: root)
        return root
    }

    private func commitAll(_ repo: URL, _ message: String) async throws {
        try await runGit(["add", "-A"], cwd: repo)
        try await runGit(["commit", "-q", "-m", message], cwd: repo)
    }

    private func pathExists(git: Git, tree: String, path: String) async throws -> Bool {
        let result = try await git.runResult(["cat-file", "-e", "\(tree):\(path)"])
        return result.exitCode == 0
    }

    private func stageEntry(
        kind: ExplicitSync.ChangeKind,
        relativePath: String,
        stagedPath: String?,
        repo: URL
    ) -> ExplicitSync.Entry {
        ExplicitSync.Entry(
            kind: kind,
            docID: relativePath,
            remotePath: "/sync/snapshot-commit/\(relativePath)",
            localPath: repo.appendingPathComponent(relativePath).path,
            relativePath: relativePath,
            stagedPath: stagedPath,
            remoteModified: nil,
            remoteVersion: 1,
            remoteHash: nil,
            remoteTabletHash: nil,
            localHashAtPull: nil,
            baselineHash: nil,
            pageIDs: [],
            error: nil
        )
    }

    private func runGit(_ args: [String], cwd: URL) async throws {
        let result = try await Subprocess.run(executablePath: "git", args: args, cwd: cwd)
        #expect(result.exitCode == 0, "git \(args.joined(separator: " ")) failed: \(result.stderr)")
        if result.exitCode != 0 {
            throw TestGitError.commandFailed(args, result.stderr)
        }
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    private func scratchRoot() throws -> URL {
        let raw = ProcessInfo.processInfo.environment["RMSYNC_TEST_TMP"]
            ?? FileManager.default.temporaryDirectory.path
        let url = URL(fileURLWithPath: raw, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    enum TestGitError: Error {
        case commandFailed([String], String)
    }
}

private actor RecordingGitInitCloud: CloudWriteClient {
    private var existing: Set<String> = []
    private var created: [String] = []

    func createdPaths() -> [String] { created }

    func tree(_ root: String) async throws -> [Node] { [] }

    func get(_ remotePath: String, dest: URL) async throws -> URL {
        throw RecordingGitInitCloudError.unsupported
    }

    func stat(_ remotePath: String) async throws -> StatResult? {
        guard existing.contains(remotePath) else { return nil }
        return StatResult(
            id: remotePath,
            name: URL(fileURLWithPath: remotePath).lastPathComponent,
            version: 1,
            modifiedClient: "2026-06-03T00:00:00Z",
            type: "CollectionType",
            currentPage: 0,
            parent: ""
        )
    }

    func put(local: URL, remoteParent: String, update: Bool) async throws {
        throw RecordingGitInitCloudError.unsupported
    }

    func putRaw(localPath: URL, remoteFolder: String) async throws {
        _ = localPath
        _ = remoteFolder
        throw RecordingGitInitCloudError.unsupported
    }

    func mkdir(_ remotePath: String) async throws {
        existing.insert(remotePath)
        created.append(remotePath)
    }

    func mv(from src: String, to dst: String) async throws {
        throw RecordingGitInitCloudError.unsupported
    }

    func rm(_ remotePath: String) async throws {
        throw RecordingGitInitCloudError.unsupported
    }
}

private enum RecordingGitInitCloudError: Error {
    case unsupported
}
