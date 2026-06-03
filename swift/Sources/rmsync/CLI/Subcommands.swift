import ArgumentParser
import Foundation

// MARK: - daemon

struct Daemon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run the long-running daemon (invoked by launchd)."
    )
    @Flag(name: .customLong("check"), help: "Run a startup preflight and exit.")
    var checkOnly: Bool = false

    func run() async throws {
        if checkOnly {
            let cfg = try Config.load()
            print("config: OK (sync_dir=\(cfg.syncDir.path))")
            let state = try State(path: Paths.stateDBPath)
            _ = try await state.allDocuments()
            print("state DB: OK")
            return
        }
        // Real daemon loop arrives in Weeks 4–6. For now this runs the
        // IPC server + state bus so the menu bar and CLI can connect.
        try await DaemonScaffold.run()
    }
}

// MARK: - status

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print daemon health + outstanding work."
    )
    func run() async throws {
        let cfg: Config?
        let cfgError: Error?
        do {
            cfg = try Config.load()
            cfgError = nil
        } catch {
            cfg = nil
            cfgError = error
        }

        if let live = IPCClientSync.getStatus() {
            print("sync dir:       \(live.syncDir)")
            print("remote folder:  \(PathUtilities.remoteFolderPath(live.remoteFolder))")
            print("state:          \(live.state)")
            print("paused:         \(live.paused)")
            print("tracked docs:   \(live.trackedDocs)")
            print("conflicts:      \(live.conflicts)")
            // v0.2.30: when parked errors > 0, point at the
            // ``rmsync errors`` subcommand inline so the user
            // doesn't have to remember it. The count alone tells
            // them something's wrong but not which docs or why.
            if live.errors > 0 {
                print("parked errors:  \(live.errors)   (run `rmsync errors` to list)")
            } else {
                print("parked errors:  \(live.errors)")
            }
            print("queue depth:    \(live.queueDepth)")
            print("last pull:      \(live.lastPullAt ?? "(never)")")
            print("last push:      \(live.lastPushAt ?? "(never)")")
            print("auto-push:      \(Self.autoPushLine(live))")
            print("pull probe:     \(Self.pullProbeLine(live))")
            // v0.2.25 — cloud-health probe diagnostic. Empty
            // means no probe has run yet (daemon healthy from
            // its perspective). Anything else surfaces the
            // upstream cause so the user knows whether to wait,
            // re-auth, or reinstall rmapi.
            if !live.cloudHealth.isEmpty, live.cloudHealth != "ok" {
                print("cloud health:   \(live.cloudHealth)")
                if let detail = live.cloudHealthDetail, !detail.isEmpty {
                    print("                \(detail)")
                }
            }
            await Self.printSyncTopology(cfg: cfg, cfgError: cfgError, live: live)
            // Version line shows BOTH the running daemon's version
            // (from IPC) and this CLI binary's version. Divergence
            // means the on-disk binary was upgraded but the daemon
            // process is still running the old one in memory — classic
            // post-brew-upgrade state. Also flags when you've built a
            // new binary in-tree but forgot to kickstart.
            let daemonVersion = live.version.isEmpty ? "unknown" : live.version
            if daemonVersion == Version.current {
                print("version:        \(daemonVersion)")
            } else {
                print("version:        cli \(Version.current) · daemon \(daemonVersion)")
                print("                ⚠ mismatch — daemon is running an older binary;")
                print("                  restart to pick up the new one:")
                print("                    launchctl kickstart -k gui/$(id -u)/com.user.rmsync")
            }
            return
        }

        // Fallback path.
        if let cfg {
            print("sync dir:       \(cfg.syncDir.path)")
            print("remote folder:  \(PathUtilities.remoteFolderPath(cfg.remoteFolder))")
        }
        print("daemon:         not running (reading state DB directly)")
        if FileManager.default.fileExists(atPath: Paths.stateDBPath.path) {
            let state = try State(path: Paths.stateDBPath)
            let docs = try await state.allDocuments()
            let dtCount = docs.filter { $0.docType == "DocumentType" }.count
            let conflicts = docs.filter { $0.conflictState == "unresolved" }.count
            let errors = docs.filter { $0.errorState != nil }.count
            print("tracked docs:   \(dtCount)")
            print("conflicts:      \(conflicts)")
            print("parked errors:  \(errors)")
        }
        await Self.printSyncTopology(cfg: cfg, cfgError: cfgError, live: nil)
    }

    static func ordinarySyncTopologyLines(
        cfg: Config?,
        cfgError: Error?,
        live: IPC.Status?
    ) -> [String] {
        let syncDir = nonEmpty(live?.syncDir) ?? cfg?.syncDir.path
        let remoteFolder = nonEmpty(live?.remoteFolder) ?? cfg?.remoteFolder
            ?? Config.defaultRemoteFolder

        var lines = ["ordinary sync:"]
        lines.append("  local files:   \(syncDir ?? "(config unavailable)")")
        lines.append("  cloud folder:  \(PathUtilities.remoteFolderPath(remoteFolder))")
        lines.append("  method:        rmsync pull / rmsync diff / rmsync accept / rmsync push")
        lines.append("  daemon role:   status, menu bar, dashboard; no background pull/reconcile")

        if let live {
            lines.append("  push mode:     \(autoPushLine(live)); rmsync-git uses manual push")
        } else if let cfg {
            let mode = cfg.autoPush.enabled
                ? "auto-push configured for ordinary sync"
                : "manual push mode"
            lines.append("  push mode:     \(mode); rmsync-git uses manual push")
        } else {
            lines.append("  push mode:     unknown; config could not be read")
        }

        if let cfgError {
            lines.append("  config file:   \(Paths.configPath.path) (unreadable: \(oneLine(cfgError)))")
        } else {
            lines.append("  config file:   \(Paths.configPath.path)")
        }
        lines.append("  state db:      \(Paths.stateDBPath.path)")
        lines.append("  staging dir:   \(Paths.stagingDir.path)")
        lines.append("  scratch dir:   \(Paths.scratchDir.path)")
        return lines
    }

    static func gitSyncTopologyLines(
        containing cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) async -> [String] {
        var lines = ["rmsync-git:"]
        lines.append("  current dir:   \(cwd.path)")

        let git: Git
        do {
            git = try await Git.open(at: cwd)
        } catch Git.GitError.notRepository {
            lines.append("  status:        not inside a git repository")
            lines.append("  cloud root:    /sync/git/<name> per initialized repo")
            lines.append("  method:        run rmsync git init inside a git repo, then pull/push")
            return lines
        } catch {
            lines.append("  status:        unavailable: \(oneLine(error))")
            return lines
        }

        do {
            let common = try await git.commonDir()
            let configURL = GitSync.configURL(common: common)
            lines.append("  current repo:  \(git.root.path)")

            guard FileManager.default.fileExists(atPath: configURL.path) else {
                lines.append("  status:        not initialized for this repo")
                lines.append("  config file:   \(configURL.path)")
                lines.append("  cloud root:    /sync/git/<name> per initialized repo")
                lines.append("  method:        run rmsync git init, then rmsync git pull / push")
                return lines
            }

            let data = try Data(contentsOf: configURL)
            if let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               raw["remoteRoot"] != nil {
                lines.append("  status:        unsupported old config")
                lines.append("  config file:   \(configURL.path)")
                lines.append("  detail:        contains remoteRoot; rerun rmsync git init")
                return lines
            }

            let cfg = try JSONDecoder().decode(GitSync.RepoConfig.self, from: data)
            lines.append("  status:        initialized")
            lines.append("  local files:   \(repoPath(cfg.syncRoot, in: git.root).path)")
            lines.append("  cloud folder:  \(PathUtilities.remoteFolderPath(cfg.remoteFolder))")
            lines.append("  metadata:      \(GitSync.stateRoot(common: common).path)")
            lines.append("  state db:      \(GitSync.stateDBURL(common: common).path)")
            lines.append("  cloud ref:     \(cfg.cloudRef) @ \(await shortRef(cfg.cloudRef, git: git))")
            lines.append("  last snapshot: \(cfg.lastRemoteSnapshotRef) @ \(await shortRef(cfg.lastRemoteSnapshotRef, git: git))")
            lines.append("  method:        rmsync git pull, normal git merge/rebase, rmsync git push")
            lines.append("  separation:    independent from ordinary \(PathUtilities.remoteFolderPath(Config.defaultRemoteFolder))")
            return lines
        } catch {
            lines.append("  status:        unavailable: \(oneLine(error))")
            return lines
        }
    }

    private static func printSyncTopology(
        cfg: Config?,
        cfgError: Error?,
        live: IPC.Status?
    ) async {
        print("")
        print("sync topology:")
        for line in ordinarySyncTopologyLines(cfg: cfg, cfgError: cfgError, live: live) {
            print(line)
        }
        for line in await gitSyncTopologyLines() {
            print(line)
        }
    }

    private static func autoPushLine(_ live: IPC.Status) -> String {
        guard live.autoPushEnabled else { return "off (manual push mode)" }
        let active = live.autoPushQueued + live.autoPushUploading
        if active > 0 {
            return "on (\(active) queued/uploading)"
        }
        if live.autoPushFailed > 0 || live.autoPushRefused > 0 {
            return "on (\(live.autoPushFailed) failed, \(live.autoPushRefused) refused)"
        }
        if let last = live.autoPushLastSucceededAt {
            return "on (last success \(last))"
        }
        return "on (waiting for changes)"
    }

    private static func pullProbeLine(_ live: IPC.Status) -> String {
        switch live.pullState {
        case "available":
            let plural = live.pullChanges == 1 ? "" : "s"
            return "\(live.pullChanges) cloud change\(plural) available"
        case "clean":
            return "no cloud changes" + checkedSuffix(live.pullCheckedAt)
        case "checking":
            return "checking cloud"
        case "error":
            return "error" + (live.pullError.map { ": \($0)" } ?? "")
        default:
            return "not checked yet"
        }
    }

    private static func checkedSuffix(_ checkedAt: String?) -> String {
        checkedAt.map { " (checked \($0))" } ?? ""
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return value
    }

    private static func oneLine(_ value: Any) -> String {
        "\(value)"
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func repoPath(_ relativePath: String, in root: URL) -> URL {
        guard relativePath != "." else { return root }
        var url = root
        for segment in relativePath.split(separator: "/", omittingEmptySubsequences: true) {
            url.appendPathComponent(String(segment), isDirectory: true)
        }
        return url
    }

    private static func shortRef(_ ref: String, git: Git) async -> String {
        do {
            let result = try await git.runResult([
                "rev-parse", "--verify", "--short=12", ref,
            ])
            let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return result.exitCode == 0 && !value.isEmpty ? value : "missing"
        } catch {
            return "unknown: \(oneLine(error))"
        }
    }
}

// MARK: - start / stop / restart

/// On Linux, ``rmsync start/stop/restart`` are meaningless — the
/// daemon's lifecycle belongs to the container runtime (Docker
/// restart policies, systemd, a shell wrapper). We surface a clear
/// error pointing the user at the right tool. Same for all three
/// subcommands; central helper to avoid copy-paste drift.
#if os(Linux)
private func linuxLifecycleErrorAndExit() throws -> Never {
    FileHandle.standardError.write(Data((
        "rmsync start/stop/restart are not applicable in Docker / systemd mode.\n" +
        "Use the container or service supervisor instead — for example:\n" +
        "    docker restart rmsync\n" +
        "    systemctl --user restart rmsync\n"
    ).utf8))
    throw ExitCode(2)
}
#endif

struct StartCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Start the launchd agent.")
    func run() throws {
        #if os(Linux)
        try linuxLifecycleErrorAndExit()
        #else
        if Launchd.isRunning() { print("already running"); return }
        let r = Launchd.start()
        if r.ok { print("started") }
        else {
            print("failed to start: \(r.error ?? "unknown")")
            throw ExitCode(1)
        }
        #endif
    }
}

struct StopCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop the launchd agent.")
    func run() throws {
        #if os(Linux)
        try linuxLifecycleErrorAndExit()
        #else
        print(Launchd.stop() ? "stopped" : "was not running")
        #endif
    }
}

struct RestartCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart",
        abstract: "Kick the launchd agent (use after code changes)."
    )
    func run() throws {
        #if os(Linux)
        try linuxLifecycleErrorAndExit()
        #else
        let r = Launchd.restart()
        if r.ok { print("restarted") } else {
            print("restart failed: \(r.error ?? "unknown")")
            throw ExitCode(1)
        }
        #endif
    }
}

// MARK: - pause / resume

struct Pause: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Set the paused status flag.")
    func run() async throws { try await togglePaused(true, verb: "paused") }
}

struct Resume: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Clear the paused status flag.")
    func run() async throws { try await togglePaused(false, verb: "resumed") }
}

private func togglePaused(_ paused: Bool, verb: String) async throws {
    do {
        _ = try IPCClientSync.request(paused ? "pause" : "resume")
        print(verb)
    } catch IPCClientSync.CallError.daemonUnavailable {
        guard FileManager.default.fileExists(atPath: Paths.stateDBPath.path) else {
            print("daemon not running and no state DB yet; start the daemon first.")
            throw ExitCode(1)
        }
        let state = try State(path: Paths.stateDBPath)
        try await state.setPaused(paused)
        print("\(verb) (daemon not running; will apply on next start)")
    }
}

// MARK: - explicit sync

struct PullCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pull",
        abstract: "Fetch cloud changes into a staging area without touching local files."
    )

    @Flag(name: .long, help: "Bypass the remote snapshot cache and download every cloud document.")
    var full: Bool = false

    func run() async throws {
        do {
            let cfg = try Config.load()
            let state = try State(path: Paths.stateDBPath)
            let result = try await ExplicitSync.stagePull(cfg: cfg, state: state, full: full)
            print("staged pull:    \(result.id)")
            print("stage dir:      \(result.root.path)")
            printSummary(result.entries)
            print("review with:    rmsync diff")
            print("apply with:     rmsync accept <path>  or  rmsync accept --all")
        } catch let error as ExplicitSync.SyncError {
            print(error.description)
            throw ExitCode(1)
        }
    }
}

struct DiffCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diff",
        abstract: "Show the currently staged cloud changes."
    )

    @Argument(help: "Optional relative or absolute path from the sync dir to show as a unified diff.")
    var path: String?

    func run() throws {
        do {
            let (root, manifest) = try ExplicitSync.loadCurrentStage()
            print("staged pull: \(manifest.id)")
            if let path {
                try ExplicitSync.printDiff(manifest, root: root, path: path)
            } else {
                ExplicitSync.printDiff(manifest)
            }
        } catch let error as ExplicitSync.SyncError {
            print(error.description)
            throw ExitCode(1)
        }
    }
}

struct AcceptCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "accept",
        abstract: "Apply selected staged cloud changes to the local tree."
    )

    @Flag(name: .long, help: "Apply every non-unchanged staged change.")
    var all: Bool = false

    @Flag(name: .long, help: "Allow staged cloud deletes to move local files to .rmsync-trash.")
    var includeDeletes: Bool = false

    @Flag(name: .long, help: "Overwrite local conflicts or files changed since the pull was staged.")
    var force: Bool = false

    @Argument(help: "Relative paths from the sync dir to accept.")
    var paths: [String] = []

    func run() async throws {
        do {
            let cfg = try Config.load()
            let state = try State(path: Paths.stateDBPath)
            let result = try await ExplicitSync.accept(
                cfg: cfg,
                state: state,
                paths: paths,
                all: all,
                includeDeletes: includeDeletes,
                force: force
            )
            for refusal in result.refused {
                print("refused: \(refusal)")
            }
            print("applied: \(result.applied)")
            print("deleted: \(result.deleted)")
            print("skipped: \(result.skipped)")
            if !result.refused.isEmpty { throw ExitCode(1) }
        } catch let error as ExplicitSync.SyncError {
            print(error.description)
            throw ExitCode(1)
        }
    }
}

struct PushCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "push",
        abstract: "Push local Markdown changes to the cloud explicitly."
    )

    @Flag(name: .long, help: "Propagate local deletions for tracked docs missing on disk.")
    var includeDeletes: Bool = false

    @Flag(name: .long, help: "Bypass remote baseline checks.")
    var force: Bool = false

    @Argument(help: "Optional relative paths from the sync dir to push.")
    var paths: [String] = []

    func run() async throws {
        do {
            let cfg = try Config.load()
            let state = try State(path: Paths.stateDBPath)
            let result = try await ExplicitSync.push(
                cfg: cfg,
                state: state,
                paths: paths,
                includeDeletes: includeDeletes,
                force: force
            )
            for refusal in result.refused {
                print("refused: \(refusal)")
            }
            print("pushed:  \(result.pushed)")
            print("skipped: \(result.skipped)")
            if !result.refused.isEmpty { throw ExitCode(1) }
        } catch let error as ExplicitSync.SyncError {
            print(error.description)
            throw ExitCode(1)
        }
    }
}

struct ForcePushCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "force-push",
        abstract: "Overwrite the remote cloud folder with the local Markdown tree."
    )

    @Flag(name: .long, help: "Apply the force push. Without this flag, only stage and preview.")
    var apply: Bool = false

    func run() async throws {
        do {
            let cfg = try Config.load()
            let state = try State(path: Paths.stateDBPath)
            let plan = try await ExplicitSync.planForcePush(cfg: cfg, state: state)

            print("staged remote snapshot: \(plan.stage.id)")
            print("stage dir:              \(plan.stage.root.path)")
            ExplicitSync.printForcePushPlan(plan.items)

            let destructive = plan.items.filter {
                $0.action == .overwriteRemote || $0.action == .deleteRemote
            }.count
            if !apply {
                print("")
                print("preview only; no cloud changes made")
                print("rerun with: rmsync force-push --apply")
                if destructive > 0 {
                    print("warning: --apply will overwrite/delete \(destructive) remote doc(s)")
                }
                return
            }

            print("")
            print("applying force push from local tree...")
            let result = try await ExplicitSync.applyForcePush(
                plan,
                cfg: cfg,
                state: state
            )
            for refusal in result.refused {
                print("refused: \(refusal)")
            }
            print("created:     \(result.created)")
            print("moved:       \(result.moved)")
            print("overwritten: \(result.overwritten)")
            print("deleted:     \(result.deleted)")
            print("unchanged:   \(result.unchanged)")
            if !result.refused.isEmpty { throw ExitCode(1) }
        } catch let error as ExplicitSync.SyncError {
            print(error.description)
            throw ExitCode(1)
        }
    }
}

// MARK: - auto-push

struct AutoPushCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auto-push",
        abstract: "Inspect opt-in safe auto-push state.",
        subcommands: [Status.self],
        defaultSubcommand: Status.self
    )

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Show auto-push configuration and recent operations."
        )

        @Option(name: .long, help: "Number of recent operations to print.")
        var limit: Int = 10

        func run() async throws {
            let cfg = try Config.load()
            let state = try State(path: Paths.stateDBPath)
            let summary = try await state.autoPushSummary()
            let recent = try await state.recentAutoPushOperations(limit: max(1, limit))

            print("enabled:        \(cfg.autoPush.enabled)")
            print("new files:      \(cfg.autoPush.newFiles)")
            print("debounce:       \(cfg.autoPush.debounceSeconds)s")
            print("stable samples: \(cfg.autoPush.stableSampleCount)")
            print("scan interval:  \(cfg.autoPush.scanIntervalSeconds)s")
            print("rate limit:     \(cfg.autoPush.maxPushesPerMinute)/min")
            print("")
            print("queued:         \(summary.queued)")
            print("uploading:      \(summary.uploading)")
            print("succeeded:      \(summary.succeeded)")
            print("skipped:        \(summary.skipped)")
            print("refused:        \(summary.refused)")
            print("failed:         \(summary.failed)")
            print("last success:   \(summary.lastSucceededAt ?? "(never)")")

            guard !recent.isEmpty else { return }
            print("")
            print("recent:")
            for op in recent {
                let rel = relativeDisplay(op.path, syncDir: cfg.syncDir)
                let reason = op.reason.map { "  \($0)" } ?? ""
                print("#\(op.id) \(op.state.padding(toLength: 9, withPad: " ", startingAt: 0)) \(rel)\(reason)")
            }
        }

        private func relativeDisplay(_ path: String, syncDir: URL) -> String {
            guard let rel = PathUtilities.resolvedRelativePath(
                from: syncDir,
                to: URL(fileURLWithPath: path)
            ) else { return path }
            return rel.joined(separator: "/")
        }
    }
}

private func printSummary(_ entries: [ExplicitSync.Entry]) {
    let grouped = Dictionary(grouping: entries, by: \.kind)
    for kind in [
        ExplicitSync.ChangeKind.added,
        .modified,
        .deleted,
        .conflict,
        .localModified,
        .error,
        .unchanged,
    ] {
        if let count = grouped[kind]?.count, count > 0 {
            let label = kind.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)
            print("\(label) \(count)")
        }
    }
}

// MARK: - misc

struct Logs: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Tail the daemon's log.")
    @Flag(name: .shortAndLong) var follow: Bool = false
    @Flag(name: .long, help: "Print log paths, sizes, last-modified, and a tail of each log file. Useful when 'logs is empty' is the actual user-facing complaint and you need to figure out whether the daemon ran at all.")
    var diagnose: Bool = false

    func run() throws {
        if diagnose {
            try runDiagnose()
            return
        }
        // ``events.log`` is the shared audit stream for daemon events
        // and explicit CLI sync operations. Older installs only have
        // launchd's stderr/stdout files, so keep those as fallbacks.
        let eventsPath = Paths.logDir.appendingPathComponent("events.log")
        let stderrPath = Paths.logDir.appendingPathComponent("stderr.log")
        let stdoutPath = Paths.logDir.appendingPathComponent("stdout.log")
        let path: URL = {
            let fm = FileManager.default
            let candidates = [eventsPath, stderrPath, stdoutPath].filter { url in
                fm.fileExists(atPath: url.path)
                    && ((try? Data(contentsOf: url))?.isEmpty == false)
            }
            if let newest = candidates.max(by: { lhs, rhs in
                let lhsDate = (try? fm.attributesOfItem(atPath: lhs.path)[.modificationDate] as? Date)
                    ?? .distantPast
                let rhsDate = (try? fm.attributesOfItem(atPath: rhs.path)[.modificationDate] as? Date)
                    ?? .distantPast
                return lhsDate < rhsDate
            }) {
                return newest
            }
            for fallback in [eventsPath, stderrPath, stdoutPath] where fm.fileExists(atPath: fallback.path) {
                return fallback
            }
            return stderrPath
        }()
        guard FileManager.default.fileExists(atPath: path.path) else {
            print("no log file at \(path.path)")
            print("(run `rmsync logs --diagnose` if you expect this file to exist)")
            throw ExitCode(1)
        }
        if !follow {
            print(try String(contentsOf: path, encoding: .utf8))
            return
        }
        // tail -f emulation via Process.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        task.arguments = ["-f", path.path]
        try task.run()
        task.waitUntilExit()
    }

    /// Diagnostic mode: print everything we know about logging state.
    /// Designed for users reporting "the logs are blank" — the output
    /// distinguishes "daemon never wrote a log" from "daemon wrote a
    /// log but the menu bar's Open Logs button is opening the wrong
    /// file" from "daemon is running but the IPC bus is wedged".
    private func runDiagnose() throws {
        print("=== rmsync logs --diagnose ===")
        print("")

        // 1. Log paths and sizes.
        print("Log files:")
        let logFiles = ["events.log", "stdout.log", "stderr.log", "menubar.log"]
        let fm = FileManager.default
        for name in logFiles {
            let url = Paths.logDir.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
                let size = (attrs[.size] as? Int) ?? 0
                let mod = (attrs[.modificationDate] as? Date)?.description ?? "?"
                print("  \(url.path)")
                print("    size: \(size) bytes, modified: \(mod)")
            } else {
                print("  \(url.path)  (DOES NOT EXIST)")
            }
        }
        print("")

        // 2. Daemon process state via launchctl.
        print("Daemon launchd state:")
        let uid = String(getuid())
        let domain = "gui/\(uid)/com.user.rmsync"
        let lc = Process()
        lc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        lc.arguments = ["print", domain]
        let pipe = Pipe()
        lc.standardOutput = pipe
        lc.standardError = pipe
        try? lc.run()
        lc.waitUntilExit()
        let lcOut = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if lc.terminationStatus != 0 {
            print("  ✗ launchctl print \(domain) failed — agent is NOT bootstrapped")
            print("    fix: rmsync-install-agents")
        } else {
            // Pull just the interesting fields rather than dumping everything.
            for needle in ["state =", "last exit reason", "last exit code", "program ="] {
                if let line = lcOut.split(separator: "\n").first(where: { $0.contains(needle) }) {
                    print("  \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        print("")

        // 3. Tail of each log file.
        print("Tail of each log (last 20 lines):")
        for name in logFiles {
            let url = Paths.logDir.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            print("--- \(name) ---")
            let tail = Process()
            tail.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
            tail.arguments = ["-n", "20", url.path]
            try? tail.run()
            tail.waitUntilExit()
            print("")
        }

        // 4. Quick interpretation.
        let eventsEmpty = (try? Data(contentsOf: Paths.logDir.appendingPathComponent("events.log")).isEmpty) ?? true
        let stdoutEmpty = (try? Data(contentsOf: Paths.logDir.appendingPathComponent("stdout.log")).isEmpty) ?? true
        let stderrEmpty = (try? Data(contentsOf: Paths.logDir.appendingPathComponent("stderr.log")).isEmpty) ?? true
        if eventsEmpty && stdoutEmpty && stderrEmpty {
            print("Interpretation: all structured logs are empty.")
            print("  This means neither the daemon nor an explicit CLI sync command wrote anything.")
            print("  If you expected daemon activity, it most likely never ran")
            print("  (launchd plist missing, binary path wrong, or pre-execution crash).")
            print("  Fix: rmsync-install-agents, then 'rmsync logs --diagnose' again.")
        } else if eventsEmpty && stdoutEmpty && !stderrEmpty {
            print("Interpretation: events/stdout empty, stderr has content.")
            print("  The daemon crashed before its first Logger.shared.info call.")
            print("  Read stderr.log above for the crash trace.")
        }
    }
}

struct Conflicts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List unresolved conflicts.")

    @Flag(name: .long, help: "Clear conflict_state on every doc whose .conflict file no longer exists. Use this when the menubar shows a conflict count but you've already deleted the .conflict files. The daemon's periodic refresh does the same self-heal every 5s; this lets you do it now and see what changed.")
    var resolveStale: Bool = false

    func run() async throws {
        guard FileManager.default.fileExists(atPath: Paths.stateDBPath.path) else {
            print("no state DB")
            return
        }
        let state = try State(path: Paths.stateDBPath)
        let docs = try await state.allDocuments()
        let conflicts = docs.filter { $0.conflictState == "unresolved" }
        if conflicts.isEmpty { print("no unresolved conflicts"); return }

        if resolveStale {
            // Walk every doc the DB thinks has an unresolved conflict;
            // if the .conflict marker file is gone from disk, clear it.
            // Identical logic to DaemonScaffold.refreshBus's auto-heal,
            // exposed here as an explicit user-callable command for
            // when the user wants immediate feedback (vs waiting for
            // the next 5s tick) or when the daemon isn't running.
            var cleared = 0
            for d in conflicts {
                let md = URL(fileURLWithPath: d.localPath)
                let cp = md.appendingPathExtension("conflict")
                if !FileManager.default.fileExists(atPath: cp.path) {
                    try await state.setConflict(docID: d.docID, state: nil)
                    print("cleared \(d.docID)  (\(md.lastPathComponent))")
                    cleared += 1
                }
            }
            if cleared == 0 {
                print("no stale conflict states — every doc with conflict_state=unresolved")
                print("still has its .conflict file on disk.")
            } else {
                print("\(cleared) cleared. Restart rmsync or wait 5s for the menubar to refresh.")
            }
            return
        }

        for d in conflicts {
            let md = URL(fileURLWithPath: d.localPath)
            let cp = md.appendingPathExtension("conflict")
            print(d.docID)
            print("  live:     \(md.path)")
            let present = FileManager.default.fileExists(atPath: cp.path)
            print("  conflict: \(cp.path) \(present ? "(present)" : "(MISSING — run with --resolve-stale to clear)")")
        }
    }
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run all self-checks."
    )
    func run() async throws {
        let results = await DoctorRun.runAll()
        let exit = DoctorRun.printAndExit(results)
        if exit != 0 { throw ExitCode(exit) }
    }
}

struct Relocate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Move the sync dir + rewrite state + update config."
    )
    @Argument(help: "Target directory.") var target: String
    @Flag(help: "Allow merging into a non-empty target directory.")
    var force: Bool = false
    @Flag(
        name: .customLong("keep-stopped"),
        help: "Leave the launchd agent stopped after relocating."
    )
    var keepStopped: Bool = false

    func run() async throws {
        let newDir = URL(fileURLWithPath:
            (target as NSString).expandingTildeInPath
        )
        do {
            _ = try await RelocateImpl.run(
                newSyncDir: newDir,
                force: force,
                keepStopped: keepStopped
            )
        } catch {
            print("ERROR: \(error)")
            throw ExitCode(1)
        }
    }
}

struct Init: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "One-time setup wizard.")
    func run() async throws {
        do {
            let (cfg, seeded) = try loadOrSeedConfig()
            try FileManager.default.createDirectory(
                at: cfg.syncDir,
                withIntermediateDirectories: true
            )

            let remotePath = PathUtilities.remoteFolderPath(cfg.remoteFolder)
            print("config:       \(Paths.configPath.path)\(seeded ? " (created)" : "")")
            print("sync dir:     \(cfg.syncDir.path)")
            print("cloud folder: \(remotePath)")

            let cloud = Cloud()
            do {
                _ = try await cloud.account()
            } catch {
                print("")
                print("local setup is complete, but rmapi is not authenticated.")
                print("next:         rmapi")
                print("then:         rmsync init")
                print("detail:       `rmapi account` failed: \(error)")
                throw ExitCode(1)
            }

            for path in PathUtilities.remoteFolderMkdirChain(cfg.remoteFolder) {
                do {
                    try await cloud.mkdir(path)
                } catch {
                    // rmapi mkdir is not idempotent; existing folders are fine.
                }
            }
            do {
                _ = try await cloud.find(remotePath)
            } catch {
                print("")
                print("cloud folder could not be verified after mkdir attempts.")
                print("retry:        rmsync init")
                print("detail:       `rmapi find \(remotePath)` failed: \(error)")
                throw ExitCode(1)
            }

            print("ready:        edit Markdown in sync dir, then run `rmsync push`")
        } catch let exit as ExitCode {
            throw exit
        } catch {
            print("ERROR: \(error)")
            throw ExitCode(1)
        }
    }

    private func loadOrSeedConfig() throws -> (Config, Bool) {
        if FileManager.default.fileExists(atPath: Paths.configPath.path) {
            return (try Config.load(), false)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let syncDir = home.appendingPathComponent(Config.defaultSyncDirName, isDirectory: true)
        let cfg = Config(syncDir: syncDir)
        try FileManager.default.createDirectory(
            at: Paths.configPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let text = """
        # rmsync configuration. Restart the daemon after edits:
        #   rmsync restart

        sync_dir      = "\(syncDir.path)"
        remote_folder = "\(Config.defaultRemoteFolder)"

        [deletion]
        trash_retention_days = 30

        [log]
        level = "INFO"
        """
        try text.write(to: Paths.configPath, atomically: true, encoding: .utf8)
        return (cfg, true)
    }
}

struct Uninstall: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Remove the launchd agent.")
    func run() throws {
        print("Run ./uninstall.sh (or ./uninstall.sh --purge) from the repo root.")
    }
}

// MARK: - trash

/// Inspects and recovers files parked under
/// ``<sync_dir>/.rmsync-trash`` by the rename / delete propagation
/// pipeline. The trash is filesystem-backed (no DB), so these
/// commands work whether or not the daemon is running.
///
/// Type name avoids the bare ``Trash`` collision with the
/// ``Trash`` enum in ``Trash.swift``; the user-facing command
/// is still ``rmsync trash`` via ``commandName``.
struct TrashCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trash",
        abstract: "Inspect and recover soft-deleted files.",
        subcommands: [List.self, Restore.self, Prune.self],
        defaultSubcommand: List.self
    )

    /// ``rmsync trash list`` — chronological dump of every file
    /// in the trash. Format: ``<stamp>  <relPath>``, two-column
    /// space-padded so it lines up under a fixed-width terminal.
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List files currently in the trash."
        )
        func run() async throws {
            let cfg = try Config.load()
            let entries = try rmsync.Trash.list(syncDir: cfg.syncDir)
            if entries.isEmpty {
                print("(trash is empty)")
                return
            }
            for e in entries {
                print("\(e.stamp)  \(e.relPath)")
            }
            print("")
            print("Restore a file with:  rmsync trash restore '<rel-path>'")
            print("Or restore all:       rmsync trash restore --all")
        }
    }

    /// ``rmsync trash restore`` — move file(s) back from the trash
    /// into ``sync_dir``. In explicit sync mode the user decides
    /// whether to push restored files with ``rmsync push``.
    struct Restore: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "restore",
            abstract: "Move a trashed file back into sync_dir."
        )
        @Argument(help: "Relative path inside the trash (or omit with --all).")
        var relPath: String?
        @Flag(name: .long, help: "Restore every file currently in the trash.")
        var all: Bool = false

        func run() async throws {
            let cfg = try Config.load()
            let entries = try rmsync.Trash.list(syncDir: cfg.syncDir)
            if entries.isEmpty {
                print("(trash is empty — nothing to restore)")
                return
            }

            let targets: [rmsync.Trash.Entry]
            if all {
                targets = entries
            } else if let rel = relPath {
                let matches = entries.filter { $0.relPath == rel }
                if matches.isEmpty {
                    print("no trash entry with rel-path '\(rel)' — try `rmsync trash list`.")
                    throw ExitCode(1)
                }
                // Multiple entries can share a rel-path if the file
                // was deleted, recreated, deleted again. Restore the
                // most recent (entries are ordered ascending).
                targets = [matches.last!]
            } else {
                print("usage: rmsync trash restore <rel-path>  |  rmsync trash restore --all")
                throw ExitCode(1)
            }

            var restored = 0
            for e in targets {
                do {
                    let dest = try rmsync.Trash.restore(e, syncDir: cfg.syncDir)
                    print("restored: \(dest.path)")
                    restored += 1
                } catch let err as TrashError {
                    print("skip: \(err)")
                }
            }
            if restored > 0 {
                print("")
                print("\(restored) file(s) restored. Run `rmsync push <path>` for any restored file you want on the cloud.")
            }
        }
    }

    /// ``rmsync trash prune`` — explicitly drop trash entries
    /// older than ``trash_retention_days``.
    struct Prune: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "prune",
            abstract: "Remove trash entries older than the retention window."
        )
        @Option(name: .customLong("days"), help: "Override trash_retention_days for this run.")
        var daysOverride: Int?

        func run() async throws {
            let cfg = try Config.load()
            let days = daysOverride ?? cfg.deletion.trashRetentionDays
            if days <= 0 {
                print("trash_retention_days is 0 — keeping forever; nothing to prune.")
                return
            }
            let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
            let n = try rmsync.Trash.prune(syncDir: cfg.syncDir, olderThan: cutoff)
            print("pruned \(n) trash stamp(s) older than \(days) day(s).")
        }
    }
}

// MARK: - history

/// Browse, diff, and revert per-doc snapshot history.
///
/// Snapshots are written by explicit push (about-to-go-up bytes)
/// and explicit accept when overwriting local content
/// (about-to-be-clobbered bytes). Storage at
/// ``<stateDir>/backups/<doc-id>/<utc-stamp>.{md,json}``;
/// retention controlled by ``backup_snapshots_to_keep``.
///
/// All three subcommands run direct against state.db + the
/// filesystem (no IPC needed). The exception is ``restore``,
/// which optionally pings the daemon over IPC to enqueue an
/// immediate push of the reverted content.
struct History: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "Browse / diff / revert snapshot history of a tracked .md.",
        subcommands: [List.self, Diff.self, Restore.self],
        defaultSubcommand: List.self
    )

    /// ``rmsync history list <path>`` — chronological table of every
    /// snapshot for the given file. Newest at top so the most
    /// useful row is the first one the user sees.
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List snapshot history for a tracked file."
        )
        @Argument(help: "Path to a tracked .md inside sync_dir.")
        var path: String

        func run() async throws {
            let resolved = try await resolveTracked(path: path)
            let entries = try Snapshots.list(
                docID: resolved.doc.docID, in: Paths.stateDir
            )
            if entries.isEmpty {
                print("(no snapshots yet for this doc)")
                return
            }
            // Newest first — flip the chronological list.
            let ordered = Array(entries.reversed())
            print("doc: \(resolved.relativeOrAbsolute)  (id: \(resolved.doc.docID.prefix(8))…)")
            print("")
            // Compute deltas vs the immediately-newer snapshot.
            // entries[i] is older than entries[i+1] in original
            // (chronological) order; we reversed to print, so in
            // ``ordered`` the row at index N's delta is
            // (words at N) - (words at N+1). The oldest row has no
            // predecessor here; show its delta as a baseline +N.
            //
            // Hand-rolled column padding instead of String(format:).
            // ``%s`` in NSString-bridged format strings expects a C
            // ``char *`` and reads memory at the bridged Swift
            // string's pointer address — segfaults. Using ``%@`` is
            // safer but width modifiers behave subtly differently
            // across platforms; explicit padding is the
            // unambiguous choice.
            print(History.padR("ts", 26) + "  "
                + History.padR("cause", 16) + "  "
                + History.padL("words", 7) + "  "
                + History.padL("delta", 7) + "  "
                + History.padL("bytes", 9))
            for (i, e) in ordered.enumerated() {
                let prev: Int = (i + 1 < ordered.count)
                    ? ordered[i + 1].wordCount
                    : 0
                let delta = e.wordCount - prev
                let deltaStr: String
                if delta > 0 { deltaStr = "+\(delta)" }
                else if delta < 0 { deltaStr = "\(delta)" }
                else { deltaStr = "±0" }
                let display = formatDisplayStamp(e.stamp)
                print(History.padR(display, 26) + "  "
                    + History.padR(e.cause, 16) + "  "
                    + History.padL("\(e.wordCount)", 7) + "  "
                    + History.padL(deltaStr, 7) + "  "
                    + History.padL("\(e.byteCount)", 9))
            }
            print("")
            if let newest = ordered.first {
                let display = formatDisplayStamp(newest.stamp)
                print("Use:  rmsync history diff '\(path)' [--against \(display)]")
                print("      rmsync history restore '\(path)' --to \(display)")
            }
        }
    }

    /// ``rmsync history diff <path>`` — unified diff between
    /// current local content and a snapshot. Defaults to the
    /// most recent snapshot when ``--against`` is omitted.
    struct Diff: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "diff",
            abstract: "Diff current vs a historical snapshot."
        )
        @Argument(help: "Path to a tracked .md inside sync_dir.")
        var path: String
        @Option(name: .customLong("against"),
                help: "Snapshot timestamp (defaults to most recent).")
        var against: String?

        func run() async throws {
            let resolved = try await resolveTracked(path: path)
            let entries = try Snapshots.list(
                docID: resolved.doc.docID, in: Paths.stateDir
            )
            guard !entries.isEmpty else {
                print("(no snapshots yet for this doc)")
                throw ExitCode(1)
            }
            let entry: Snapshots.Entry
            if let target = against {
                guard let found = try Snapshots.find(
                    docID: resolved.doc.docID, stamp: target,
                    in: Paths.stateDir
                ) else {
                    print("no snapshot matches '\(target)' — try `rmsync history list`")
                    throw ExitCode(1)
                }
                entry = found
            } else {
                entry = entries.last!  // most recent
            }
            let diff = try Snapshots.unifiedDiff(
                entry, vs: URL(fileURLWithPath: resolved.absolute)
            )
            if diff.isEmpty {
                print("(no differences vs snapshot \(formatDisplayStamp(entry.stamp)))")
                return
            }
            print(diff, terminator: "")
        }
    }

    /// ``rmsync history restore <path> --to <ts>`` — revert local
    /// file to a previous snapshot, parking the current content in
    /// trash for safety. In explicit sync mode the user pushes that
    /// restored file deliberately with ``rmsync push``.
    struct Restore: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "restore",
            abstract: "Revert a tracked file to a historical snapshot."
        )
        @Argument(help: "Path to a tracked .md inside sync_dir.")
        var path: String
        @Option(name: .customLong("to"),
                help: "Snapshot timestamp to restore.")
        var to: String

        func run() async throws {
            let cfg = try Config.load()
            let resolved = try await resolveTracked(path: path)
            guard let entry = try Snapshots.find(
                docID: resolved.doc.docID, stamp: to, in: Paths.stateDir
            ) else {
                print("no snapshot matches '\(to)' — try `rmsync history list`")
                throw ExitCode(1)
            }

            let target = URL(fileURLWithPath: resolved.absolute)

            // 1. Park the current content in trash so the restore
            //    is itself recoverable. moveIn returns
            //    .sourceMissing if the current file is already
            //    gone — proceed regardless.
            do {
                let result = try Trash.moveIn(target, syncDir: cfg.syncDir)
                switch result {
                case .moved(let stamp, _):
                    print("current parked in trash (stamp \(stamp))")
                case .sourceMissing:
                    print("(no current file to park)")
                case .alreadyTrashed(let stamp, _):
                    print("(current already trashed at \(stamp))")
                }
            } catch {
                print("WARNING: trash move failed (\(error)) — restoring anyway")
            }

            // 2. Write the snapshot content into the live path.
            //    Atomic-write so the restored file is never
            //    half-written if the user inspects or pushes it.
            let snapshotText = try Snapshots.read(entry)
            try PathUtilities.atomicWriteText(snapshotText, to: target)
            print("restored to snapshot \(formatDisplayStamp(entry.stamp)) (\(entry.wordCount) words)")

            print("not pushed; run `rmsync push \(resolved.relativeOrAbsolute)` when ready")
        }
    }

    // MARK: - shared helpers

    /// Output of ``resolveTracked``.
    fileprivate struct Resolved {
        let doc: Document
        let absolute: String
        let relativeOrAbsolute: String
    }

    /// Resolve a user-supplied path argument to its tracked
    /// state.db row. Accepts absolute paths, relative paths from
    /// cwd, or paths relative to ``sync_dir``. Throws ExitCode(1)
    /// with a hint if the path isn't tracked.
    fileprivate static func resolveTracked(path: String) async throws -> Resolved {
        let cfg = try Config.load()
        let candidates: [URL] = {
            let raw = NSString(string: path).expandingTildeInPath
            let direct = URL(fileURLWithPath: raw).standardizedFileURL
            let underSync = cfg.syncDir.appendingPathComponent(raw).standardizedFileURL
            return [direct, underSync]
        }()
        let state = try State(path: Paths.stateDBPath)
        for url in candidates {
            if let doc = try await state.byLocalPath(url.path) {
                let rel = PathUtilities.resolvedRelativePath(
                    from: cfg.syncDir, to: url
                )?.joined(separator: "/")
                return Resolved(
                    doc: doc, absolute: url.path,
                    relativeOrAbsolute: rel ?? url.path
                )
            }
        }
        print("path not tracked: \(path)")
        print("hint: history is keyed on the doc's local_path in state.db.")
        print("      run `rmsync status` to see tracked docs.")
        throw ExitCode(1)
    }

    /// Right-pad ``s`` to exactly ``width`` characters with
    /// spaces. Used for left-aligned columns in the
    /// ``history list`` table. We avoid ``String(format:)`` here
    /// because ``%s`` reads the bridged NSString as a C
    /// ``char *`` and segfaults; ``%@`` works but width
    /// behaviour is subtle across platforms.
    ///
    /// Internal (rather than fileprivate) so the test suite can
    /// pin the no-segfault contract — the bug shipped in v0.2.20
    /// was discoverable only by running the binary against a
    /// real state.db with snapshots present, which the test suite
    /// doesn't do; a unit-level guard on the helpers themselves
    /// is the bisectable defence.
    static func padR(_ s: String, _ width: Int) -> String {
        s.count >= width ? s :
            s + String(repeating: " ", count: width - s.count)
    }

    /// Left-pad ``s`` to exactly ``width`` characters with
    /// spaces. Used for right-aligned numeric columns.
    static func padL(_ s: String, _ width: Int) -> String {
        s.count >= width ? s :
            String(repeating: " ", count: width - s.count) + s
    }

    /// Reformat a compact stamp (``20260429T221408000Z``) as the
    /// ISO form humans paste into ``--against`` /``--to``
    /// (``2026-04-29T22:14:08Z``). Falls back to the input on
    /// parse failure.
    fileprivate static func formatDisplayStamp(_ stamp: String) -> String {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        guard let date = f.date(from: stamp) else { return stamp }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso.string(from: date)
    }
}

// MARK: - errors

/// List every doc currently parked with a non-NULL ``error_state``,
/// grouped by error class. v0.2.30+.
///
/// Prior versions surfaced only the count (``parked errors: N``
/// in ``rmsync status``) and the most-recent diagnostic
/// (``cloud_health`` in ``rmsync status``); to actually see WHICH
/// docs were parked you had to ``sqlite3`` the state DB. This
/// command closes that gap.
///
/// Output groups by ``error_state`` value so the user sees the
/// failure shape at a glance:
///
/// ```
///   push_failed (3):
///     /Users/madhav/.../foo.md          (last push: 2026-04-30T11:38Z)
///     /Users/madhav/.../bar.md          (last push: never)
///     /Users/madhav/.../baz.md          (last push: 2026-04-29T22:14Z)
///
///   parse_failed (1):
///     /Users/madhav/.../old-notebook.md (last pull: 2026-04-18)
///
///   bulk_delete_refused (2): ...
/// ```
///
/// And tails with class-specific next-action hints. The ``cloud_health`` IPC field
/// (if non-empty + non-OK) gets shown above the table so the user
/// sees "this is rmapi's fault" before the per-doc detail.
struct Errors: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "errors",
        abstract: "List parked errors (docs with non-NULL error_state in state.db)."
    )

    func run() async throws {
        guard FileManager.default.fileExists(atPath: Paths.stateDBPath.path) else {
            print("no state DB at \(Paths.stateDBPath.path)")
            return
        }

        // Show daemon-level diagnostic FIRST if present — that's
        // the systemic cause when many docs are parked at once.
        // Read via IPC if the daemon's running, otherwise skip
        // (the per-doc list still surfaces).
        if let live = IPCClientSync.getStatus(),
           !live.cloudHealth.isEmpty, live.cloudHealth != "ok" {
            print("daemon diagnostic: \(live.cloudHealth)")
            if let detail = live.cloudHealthDetail, !detail.isEmpty {
                // Wrap detail at ~70 chars per line for terminal
                // readability. Keeps long messages from making
                // the per-doc table land off-screen.
                for line in Self.softWrap(detail, width: 70) {
                    print("  \(line)")
                }
            }
            print("")
        }

        let state = try State(path: Paths.stateDBPath)
        let docs = try await state.allDocuments()
        let parked = docs.filter { $0.errorState != nil }

        if parked.isEmpty {
            print("no parked errors.")
            print("")
            print("(``rmsync logs --tail`` shows recent daemon activity)")
            return
        }

        // Group by error_state value. Sort group keys
        // alphabetically so output is stable across runs.
        let grouped = Dictionary(grouping: parked, by: { $0.errorState ?? "" })
        let orderedKeys = grouped.keys.sorted()

        for key in orderedKeys {
            let group = grouped[key] ?? []
            print("\(key) (\(group.count)):")
            for d in group.sorted(by: { $0.localPath < $1.localPath }) {
                let lastPush = d.lastPushAt.map { "last push: \(Self.shortISO($0))" }
                    ?? "last push: never"
                print("  \(d.localPath)")
                print("    doc_id: \(d.docID)   \(lastPush)")
            }
            print("")
        }

        // Per-class next-action hints. Current rmsync has no hidden retry
        // worker, so every recovery path points back to explicit commands.
        let classes = Set(parked.compactMap(\.errorState))
        if classes.contains("push_failed") {
            print("push_failed came from an older state database. This version does")
            print("not have a hidden retry worker; inspect the file, then run:")
            print("    rmsync push <path>")
            print("")
        }
        if classes.contains("parse_failed") {
            print("parse_failed means a page's .rm bytes wouldn't decode")
            print("(handwriting-only page, or a decoder bug). Workarounds:")
            print("  • Edit the doc on the tablet to add typed text → re-pull")
            print("  • rmapi rm <remote_path> + edit locally + push fresh")
            print("")
        }
        if classes.contains("bulk_delete_refused") {
            print("bulk_delete_refused came from the removed background delete")
            print("pipeline. Restore anything you need from trash, then use")
            print("explicit `rmsync push` or `rmsync force-push` deliberately.")
            print("")
        }
        if classes.contains("missing_pre_upgrade") {
            print("missing_pre_upgrade came from the removed upgrade guard.")
            print("This version expects a fresh reinstall; move old state aside")
            print("or recover with `rmsync pull`, `rmsync diff`, and `rmsync accept`.")
            print("")
        }

        print("Inspect the daemon's recent attempts:")
        print("    rmsync logs --tail")
    }

    /// Soft-wrap a long string at ``width`` columns on whitespace
    /// boundaries. Greedy — doesn't try to be a paragraph
    /// formatter. Used to make the cloud-health detail readable
    /// without scrolling.
    static func softWrap(_ s: String, width: Int) -> [String] {
        var out: [String] = []
        var line = ""
        for word in s.split(whereSeparator: { $0.isWhitespace }) {
            if line.isEmpty {
                line = String(word)
            } else if line.count + 1 + word.count <= width {
                line += " " + word
            } else {
                out.append(line)
                line = String(word)
            }
        }
        if !line.isEmpty { out.append(line) }
        return out
    }

    /// Shorten an ISO-8601 timestamp by dropping the millisecond
    /// fraction. ``2026-04-30T11:38:07.998Z`` →
    /// ``2026-04-30T11:38:07Z``. Doesn't try to convert to local
    /// time — UTC is what the rest of the daemon log lines show
    /// so consistency wins over user-friendliness.
    static func shortISO(_ s: String) -> String {
        guard let dotIdx = s.firstIndex(of: ".") else { return s }
        let zIdx = s.lastIndex(of: "Z") ?? s.endIndex
        return String(s[..<dotIdx]) + (zIdx < s.endIndex ? "Z" : "")
    }
}
