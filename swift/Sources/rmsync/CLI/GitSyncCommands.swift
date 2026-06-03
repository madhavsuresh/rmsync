import ArgumentParser
import Foundation

struct GitSyncCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "git",
        abstract: "Git-native reMarkable cloud sync.",
        discussion: """
        Treats /sync/<name> on the reMarkable cloud as a materialized git tree.
        Pulls create git branches; pushes merge with git and upload only verified
        resolved Markdown states.
        """,
        subcommands: [
            GitSyncInitCmd.self,
            GitSyncPullCmd.self,
            GitSyncPushCmd.self,
        ],
        defaultSubcommand: nil
    )
}

struct GitSyncInitCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Initialize /sync/<name> for the current git repository."
    )

    @Option(name: .long, help: "Cloud folder name under /sync. Defaults to the repository directory name.")
    var name: String?

    @Option(name: .long, help: "Repository subdirectory to sync. Defaults to the repo root.")
    var path: String = "."

    @Option(name: .long, help: "Cloud root folder. Defaults to sync.")
    var remoteRoot: String = "sync"

    func run() async throws {
        do {
            let result = try await GitSync.initialize(
                cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                name: name,
                syncRoot: path,
                remoteRoot: remoteRoot
            )
            print("initialized:  \(result.name)")
            print("remote:       \(result.remotePath)")
            print("cloud ref:    \(result.cloudBase)")
            print("next:         rmsync git push")
        } catch {
            print("ERROR: \(error)")
            throw ExitCode(1)
        }
    }
}

struct GitSyncPullCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pull",
        abstract: "Render cloud state into a new git branch."
    )

    func run() async throws {
        do {
            let result = try await GitSync.pull(
                cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            )
            print("cloud branch: \(result.branch)")
            print("snapshot:     \(result.snapshot)")
            print("stage:        \(result.stageID)")
            print("changes:      \(result.changed)")
            print("")
            print("merge with:   git merge \(result.branch)")
            print("or rebase:    git rebase \(result.branch)")
        } catch {
            print("ERROR: \(error)")
            throw ExitCode(1)
        }
    }
}

struct GitSyncPushCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "push",
        abstract: "Merge current cloud state with HEAD, then upload the verified git tree."
    )

    @Flag(name: .long, help: "Preview the merge/upload plan without changing git refs or cloud state.")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Allow pushing from a dirty worktree. By default, push requires HEAD to be the exact source of truth.")
    var allowDirty: Bool = false

    func run() async throws {
        do {
            let result = try await GitSync.push(
                cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                dryRun: dryRun,
                allowDirty: allowDirty
            )
            if let mergeCommit = result.mergeCommit {
                print("merge commit: \(mergeCommit)")
            }
            print("target:       \(result.target)")
            print("cloud base:   \(result.remoteSnapshot)")
            print("created:      \(result.created)")
            print("overwritten:  \(result.overwritten)")
            print("deleted:      \(result.deleted)")
            print("unchanged:    \(result.unchanged)")
            if result.dryRun {
                print("")
                print("dry run; no git refs or cloud documents changed")
            } else {
                print("verified:     cloud matches target git tree")
            }
        } catch {
            print("ERROR: \(error)")
            throw ExitCode(1)
        }
    }
}
