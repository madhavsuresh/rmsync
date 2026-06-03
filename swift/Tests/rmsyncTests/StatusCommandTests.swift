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

    private func makeRepo() async throws -> URL {
        let root = try scratchRoot()
            .appendingPathComponent("status-command-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await runGit(["init", "-q", "-b", "main"], cwd: root)
        return root
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

    enum TestGitError: Error {
        case commandFailed([String], String)
    }
}
