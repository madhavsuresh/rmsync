import Foundation
import Testing
@testable import rmsync

@Suite("rmsync status topology")
struct StatusCommandTests {
    @Test("ordinary sync topology describes local, cloud, and state paths")
    func ordinarySyncTopology() {
        let cfg = Config(syncDir: URL(fileURLWithPath: "/Users/example/rmsync-notes"))

        let lines = Status.ordinarySyncTopologyLines(
            cfg: cfg,
            cfgError: nil,
            live: nil
        )
        let output = lines.joined(separator: "\n")

        #expect(output.contains("ordinary sync:"))
        #expect(output.contains("local files:   /Users/example/rmsync-notes"))
        #expect(output.contains("cloud folder:  /sync/notes"))
        #expect(output.contains("method:        rmsync pull / rmsync diff / rmsync accept / rmsync push"))
        #expect(output.contains("rmsync-git uses manual push"))
        #expect(output.contains("state db:"))
        #expect(output.contains("staging dir:"))
        #expect(output.contains("scratch dir:"))
    }

    @Test("ordinary sync direction reports cloud ahead")
    func ordinarySyncDirectionCloudAhead() async throws {
        let dir = try scratchRoot()
            .appendingPathComponent("ordinary-cloud-ahead-\(UUID().uuidString)", isDirectory: true)
        let syncDir = dir.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: syncDir, withIntermediateDirectories: true)
        let statePath = dir.appendingPathComponent("state.db")
        let state = try State(path: statePath)
        let md = syncDir.appendingPathComponent("same.md")
        try write("same\n", to: md)
        try await state.upsert(Document(
            docID: "same",
            remotePath: "/sync/notes/same",
            localPath: md.path,
            lastSyncedMDHash: PathUtilities.sha256("same\n")
        ))
        var live = IPC.Status.empty
        live.pullState = "available"
        live.pullChanges = 2

        let line = await Status.ordinarySyncDirectionLine(
            cfg: Config(syncDir: syncDir),
            live: live,
            stateDBPath: statePath
        )

        #expect(line.contains("sync state:    cloud ahead"))
        #expect(line.contains("local clean"))
        #expect(line.contains("2 cloud changes available"))
    }

    @Test("ordinary sync direction reports cloud behind")
    func ordinarySyncDirectionCloudBehind() async throws {
        let dir = try scratchRoot()
            .appendingPathComponent("ordinary-cloud-behind-\(UUID().uuidString)", isDirectory: true)
        let syncDir = dir.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: syncDir, withIntermediateDirectories: true)
        let statePath = dir.appendingPathComponent("state.db")
        let state = try State(path: statePath)
        let md = syncDir.appendingPathComponent("changed.md")
        try write("local\n", to: md)
        try await state.upsert(Document(
            docID: "changed",
            remotePath: "/sync/notes/changed",
            localPath: md.path,
            lastSyncedMDHash: PathUtilities.sha256("base\n")
        ))
        var live = IPC.Status.empty
        live.pullState = "clean"
        live.pullCheckedAt = "2026-06-03T15:00:00Z"

        let line = await Status.ordinarySyncDirectionLine(
            cfg: Config(syncDir: syncDir),
            live: live,
            stateDBPath: statePath
        )

        #expect(line.contains("sync state:    cloud behind"))
        #expect(line.contains("1 local change"))
        #expect(line.contains("cloud clean"))
    }

    @Test("rmsync-git topology describes initialized repository")
    func gitSyncTopologyInitialized() async throws {
        let repo = try await makeRepo()
        let docs = repo.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)

        let git = try await Git.open(at: repo)
        let common = try await git.commonDir()
        let gitDocs = git.root.appendingPathComponent("docs", isDirectory: true)
        let configURL = GitSync.configURL(common: common)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let cfg = GitSync.RepoConfig(name: "drafts", syncRoot: "docs")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(cfg).write(to: configURL)

        let lines = await Status.gitSyncTopologyLines(containing: docs)
        let output = lines.joined(separator: "\n")

        #expect(output.contains("rmsync-git:"))
        #expect(output.contains("status:        initialized"))
        #expect(output.contains("current repo:  \(git.root.path)"))
        #expect(output.contains("local files:   \(gitDocs.path)"))
        #expect(output.contains("cloud folder:  /sync/git/drafts"))
        #expect(output.contains("metadata:      \(GitSync.stateRoot(common: common).path)"))
        #expect(output.contains("state db:      \(GitSync.stateDBURL(common: common).path)"))
        #expect(output.contains("cloud ref:     refs/rmsync-git/drafts/cloud @ missing"))
        #expect(output.contains("last snapshot: refs/rmsync-git/drafts/last-remote-snapshot @ missing"))
        #expect(output.contains("separation:    independent from ordinary /sync/notes"))
    }

    @Test("rmsync-git direction reports cloud behind")
    func gitSyncDirectionCloudBehind() async throws {
        let repo = try await makeRepo()
        let docs = repo.appendingPathComponent("docs", isDirectory: true)
        try write("base\n", to: docs.appendingPathComponent("note.md"))
        try await commitAll(repo, "base")
        let git = try await Git.open(at: repo)
        let cfg = GitSync.RepoConfig(name: "drafts", syncRoot: "docs")
        let base = try await git.headCommit()
        try await git.updateRef(cfg.cloudRef, to: base)
        try await git.updateRef(cfg.lastRemoteSnapshotRef, to: base)

        try write("local\n", to: docs.appendingPathComponent("note.md"))
        try await commitAll(repo, "local")

        let line = await Status.gitSyncDirectionLine(cfg: cfg, git: git)

        #expect(line.contains("sync state:    cloud behind"))
        #expect(line.contains("1 local path change"))
        #expect(line.contains("cloud matches cloud ref"))
    }

    @Test("rmsync-git direction reports cloud ahead")
    func gitSyncDirectionCloudAhead() async throws {
        let repo = try await makeRepo()
        let docs = repo.appendingPathComponent("docs", isDirectory: true)
        try write("base\n", to: docs.appendingPathComponent("note.md"))
        try await commitAll(repo, "base")
        let git = try await Git.open(at: repo)
        let cfg = GitSync.RepoConfig(name: "drafts", syncRoot: "docs")
        let base = try await git.headCommit()
        try await git.updateRef(cfg.cloudRef, to: base)

        try write("cloud\n", to: docs.appendingPathComponent("note.md"))
        try await commitAll(repo, "cloud")
        let cloud = try await git.headCommit()
        try await git.updateRef(cfg.lastRemoteSnapshotRef, to: cloud)
        try await git.resetHard(base)

        let line = await Status.gitSyncDirectionLine(cfg: cfg, git: git)

        #expect(line.contains("sync state:    cloud ahead"))
        #expect(line.contains("local matches cloud ref"))
        #expect(line.contains("1 cloud path change"))
    }

    private func makeRepo() async throws -> URL {
        let root = try scratchRoot()
            .appendingPathComponent("status-command-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await runGit(["init", "-q", "-b", "main"], cwd: root)
        try await runGit(["config", "user.name", "rmsync status tests"], cwd: root)
        try await runGit(["config", "user.email", "rmsync-status@example.invalid"], cwd: root)
        return root
    }

    private func commitAll(_ repo: URL, _ message: String) async throws {
        try await runGit(["add", "-A"], cwd: repo)
        try await runGit(["commit", "-q", "-m", message], cwd: repo)
    }

    private func scratchRoot() throws -> URL {
        let raw = ProcessInfo.processInfo.environment["RMSYNC_TEST_TMP"]
            ?? FileManager.default.temporaryDirectory.path
        let url = URL(fileURLWithPath: raw, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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

    enum TestGitError: Error {
        case commandFailed([String], String)
    }
}
