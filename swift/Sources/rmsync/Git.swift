import Foundation

struct Git: Sendable {
    struct MergeTreeResult: Sendable {
        var tree: String
    }

    enum TreeSource: Sendable {
        case file(URL)
        case blob(String)
    }

    struct TreeAddition: Sendable {
        var path: String
        var source: TreeSource
    }

    enum GitError: Error, CustomStringConvertible {
        case notRepository(String)
        case commandFailed(args: [String], exitCode: Int32, stdout: String, stderr: String)
        case missingOutput([String])
        case mergeConflict(String)
        case detachedHead
        case dirtyWorktree(String)

        var description: String {
            switch self {
            case .notRepository(let path):
                return "\(path) is not inside a git repository"
            case .commandFailed(let args, let exitCode, let stdout, let stderr):
                let detail = stderr.isEmpty ? stdout : stderr
                return "git \(args.joined(separator: " ")) failed with exit \(exitCode): \(detail.trimmingCharacters(in: .whitespacesAndNewlines))"
            case .missingOutput(let args):
                return "git \(args.joined(separator: " ")) did not produce output"
            case .mergeConflict(let output):
                return "git merge-tree reported conflicts:\n\(output)"
            case .detachedHead:
                return "current repository is in detached HEAD; cannot create an automatic merge commit"
            case .dirtyWorktree(let status):
                return "working tree has uncommitted changes:\n\(status)"
            }
        }
    }

    var root: URL

    static func open(at cwd: URL) async throws -> Git {
        let result = try await runRaw(["rev-parse", "--show-toplevel"], cwd: cwd)
        guard result.exitCode == 0 else {
            throw GitError.notRepository(cwd.path)
        }
        let rootPath = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rootPath.isEmpty else {
            throw GitError.notRepository(cwd.path)
        }
        return Git(root: URL(fileURLWithPath: rootPath, isDirectory: true))
    }

    func run(_ args: [String], env: [String: String] = [:]) async throws -> String {
        let result = try await runResult(args, env: env)
        guard result.exitCode == 0 else {
            throw GitError.commandFailed(
                args: args,
                exitCode: result.exitCode,
                stdout: result.stdout,
                stderr: result.stderr
            )
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func runResult(_ args: [String], env: [String: String] = [:]) async throws -> Subprocess.Result {
        try await Self.runRaw(args, cwd: root, env: env)
    }

    func commonDir() async throws -> URL {
        let raw = try await run(["rev-parse", "--git-common-dir"])
        let url = URL(fileURLWithPath: raw, isDirectory: true)
        if raw.hasPrefix("/") { return url }
        return root.appendingPathComponent(raw, isDirectory: true).standardizedFileURL
    }

    func headCommit() async throws -> String {
        try await run(["rev-parse", "HEAD"])
    }

    func tree(_ rev: String) async throws -> String {
        try await run(["rev-parse", "\(rev)^{tree}"])
    }

    func currentBranch() async throws -> String? {
        let result = try await runResult(["symbolic-ref", "--quiet", "--short", "HEAD"])
        if result.exitCode == 0 {
            let branch = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return branch.isEmpty ? nil : branch
        }
        return nil
    }

    func requireCleanWorktree() async throws {
        let status = try await run(["status", "--porcelain"])
        guard status.isEmpty else { throw GitError.dirtyWorktree(status) }
    }

    func refExists(_ ref: String) async throws -> Bool {
        let result = try await runResult(["rev-parse", "--verify", "--quiet", ref])
        return result.exitCode == 0
    }

    func updateRef(_ ref: String, to newValue: String, expectedOld: String? = nil) async throws {
        var args = ["update-ref", ref, newValue]
        if let expectedOld { args.append(expectedOld) }
        _ = try await run(args)
    }

    func createBranch(_ name: String, at commit: String) async throws {
        _ = try await run(["branch", name, commit])
    }

    func resetHard(_ commit: String) async throws {
        _ = try await run(["reset", "--hard", commit])
    }

    func listTreePaths(_ commit: String, under pathspec: String? = nil) async throws -> [String] {
        var args = ["ls-tree", "-r", "-z", "--name-only", commit]
        if let pathspec, pathspec != "." {
            args += ["--", pathspec]
        }
        let result = try await runResult(args)
        guard result.exitCode == 0 else {
            throw GitError.commandFailed(
                args: args,
                exitCode: result.exitCode,
                stdout: result.stdout,
                stderr: result.stderr
            )
        }
        return result.stdout
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
    }

    func show(_ commit: String, path: String) async throws -> String {
        let args = ["show", "\(commit):\(path)"]
        let result = try await runResult(args)
        guard result.exitCode == 0 else {
            throw GitError.commandFailed(
                args: args,
                exitCode: result.exitCode,
                stdout: result.stdout,
                stderr: result.stderr
            )
        }
        return result.stdout
    }

    func hashObject(_ file: URL) async throws -> String {
        try await run(["hash-object", "-w", file.path])
    }

    func blobID(_ commit: String, path: String) async throws -> String {
        try await run(["rev-parse", "\(commit):\(path)"])
    }

    func writeTree(
        baseCommit: String,
        removing removedPaths: [String],
        adding addedFiles: [(path: String, file: URL)]
    ) async throws -> String {
        let additions = addedFiles.map { file in
            Git.TreeAddition(path: file.path, source: .file(file.file))
        }
        return try await writeTree(baseCommit: baseCommit, removing: removedPaths, adding: additions)
    }

    func writeTree(
        baseCommit: String,
        removing removedPaths: [String],
        adding additions: [TreeAddition]
    ) async throws -> String {
        let common = try await commonDir()
        let index = common
            .appendingPathComponent("rmsync-git", isDirectory: true)
            .appendingPathComponent("indexes", isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: index.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: index) }

        let env = ["GIT_INDEX_FILE": index.path]
        _ = try await run(["read-tree", baseCommit], env: env)

        for path in removedPaths.sorted() {
            _ = try await run(["update-index", "--force-remove", "--", path], env: env)
        }

        for addition in additions.sorted(by: { $0.path < $1.path }) {
            let blob: String
            switch addition.source {
            case .file(let file):
                blob = try await hashObject(file)
            case .blob(let existing):
                blob = existing
            }
            _ = try await run(
                ["update-index", "--add", "--cacheinfo", "100644,\(blob),\(addition.path)"],
                env: env
            )
        }

        return try await run(["write-tree"], env: env)
    }

    func commitTree(_ tree: String, parents: [String], message: String) async throws -> String {
        var args = ["commit-tree", tree]
        for parent in parents { args += ["-p", parent] }
        let env = [
            "GIT_AUTHOR_NAME": "rmsync-git",
            "GIT_AUTHOR_EMAIL": "rmsync-git@example.invalid",
            "GIT_COMMITTER_NAME": "rmsync-git",
            "GIT_COMMITTER_EMAIL": "rmsync-git@example.invalid",
        ]
        let output = try await run(args, env: env, stdin: Data(message.utf8))
        guard !output.isEmpty else { throw GitError.missingOutput(args) }
        return output
    }

    func mergeTree(base: String, local: String, remote: String) async throws -> MergeTreeResult {
        let args = ["merge-tree", "--write-tree", "--merge-base=\(base)", local, remote]
        let result = try await runResult(args)
        guard result.exitCode == 0 else {
            throw GitError.mergeConflict(result.stdout + result.stderr)
        }
        let first = result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)
        guard let tree = first, !tree.isEmpty else {
            throw GitError.missingOutput(args)
        }
        return MergeTreeResult(tree: tree)
    }

    private func run(
        _ args: [String],
        env: [String: String],
        stdin: Data
    ) async throws -> String {
        let result = try await Self.runRaw(args, cwd: root, env: env, stdin: stdin)
        guard result.exitCode == 0 else {
            throw GitError.commandFailed(
                args: args,
                exitCode: result.exitCode,
                stdout: result.stdout,
                stderr: result.stderr
            )
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func runRaw(
        _ args: [String],
        cwd: URL,
        env: [String: String] = [:],
        stdin: Data? = nil
    ) async throws -> Subprocess.Result {
        try await Subprocess.run(
            executablePath: "git",
            args: args,
            cwd: cwd,
            env: env,
            stdin: stdin
        )
    }
}
