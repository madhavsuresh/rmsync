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
        do { cfg = try Config.load() } catch { cfg = nil }

        if let live = IPCClientSync.getStatus() {
            print("sync dir:       \(live.syncDir)")
            print("remote folder:  /\(live.remoteFolder)")
            if let cfg { print("push strategy:  \(cfg.pushStrategy.rawValue)") }
            print("state:          \(live.state)")
            print("paused:         \(live.paused)")
            print("tracked docs:   \(live.trackedDocs)")
            print("conflicts:      \(live.conflicts)")
            print("parked errors:  \(live.errors)")
            print("queue depth:    \(live.queueDepth)")
            print("last pull:      \(live.lastPullAt ?? "(never)")")
            print("last push:      \(live.lastPushAt ?? "(never)")")
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
            print("remote folder:  /\(cfg.remoteFolder)")
            print("push strategy:  \(cfg.pushStrategy.rawValue)")
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

// MARK: - pause / resume / sync-now

struct Pause: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Tell the daemon to stop syncing.")
    func run() async throws { try await togglePaused(true, verb: "paused") }
}

struct Resume: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Resume syncing.")
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

struct SyncNow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync-now",
        abstract: "Trigger an immediate poll cycle."
    )
    func run() async throws {
        do {
            _ = try IPCClientSync.request("sync_now")
            print("sync requested")
        } catch {
            print("daemon not running; start it with `rmsync start`.")
            throw ExitCode(1)
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
        let path = Paths.logDir.appendingPathComponent("stdout.log")
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
        let logFiles = ["stdout.log", "stderr.log", "menubar.log"]
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
        let stdoutEmpty = (try? Data(contentsOf: Paths.logDir.appendingPathComponent("stdout.log")).isEmpty) ?? true
        let stderrEmpty = (try? Data(contentsOf: Paths.logDir.appendingPathComponent("stderr.log")).isEmpty) ?? true
        if stdoutEmpty && stderrEmpty {
            print("Interpretation: BOTH logs empty.")
            print("  This means the daemon never wrote anything — most likely it never ran")
            print("  (launchd plist missing, binary path wrong, or pre-execution crash).")
            print("  Fix: rmsync-install-agents, then 'rmsync logs --diagnose' again.")
        } else if stdoutEmpty && !stderrEmpty {
            print("Interpretation: stdout empty, stderr has content.")
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

struct Init: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "One-time setup wizard.")
    func run() throws {
        print("Run ./install.sh from the repo root.")
        print("After that, edit ~/.config/rmsync/config.toml and run `rmsync doctor`.")
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
    /// into ``sync_dir``. The daemon (if running) picks them up
    /// on the next watcher tick and re-pushes to the cloud as if
    /// they were freshly created.
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
                print("\(restored) file(s) restored. The daemon will re-push them on the next watcher tick.")
            }
        }
    }

    /// ``rmsync trash prune`` — explicitly drop trash entries
    /// older than ``trash_retention_days``. The daemon does this
    /// automatically at startup; the manual command exists so a
    /// user can free disk on demand without restarting.
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
