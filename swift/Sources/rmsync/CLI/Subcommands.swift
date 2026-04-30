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
        // The Swift daemon writes structured JSON to stderr (see
        // ``Logger.emit`` → ``FileHandle.standardError.write``).
        // launchd routes that to ``stderr.log``. ``stdout.log``
        // exists for parity with the launchd plist but is always
        // empty under the Swift daemon — it was the Python
        // implementation's primary log. Read stderr.log here so
        // ``rmsync logs`` shows the actual daemon activity, and
        // fall back to stdout.log if some future caller restores
        // a stdout-writing logger.
        let stderrPath = Paths.logDir.appendingPathComponent("stderr.log")
        let stdoutPath = Paths.logDir.appendingPathComponent("stdout.log")
        let path: URL = {
            let fm = FileManager.default
            if fm.fileExists(atPath: stderrPath.path),
               (try? Data(contentsOf: stderrPath))?.isEmpty == false {
                return stderrPath
            }
            if fm.fileExists(atPath: stdoutPath.path) { return stdoutPath }
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

// MARK: - history

/// Browse, diff, and revert per-doc snapshot history.
///
/// Snapshots are written by ``SyncWorker`` on every push (about-
/// to-go-up bytes) and every cloud-pull-overwrite (about-to-be-
/// clobbered bytes). Storage at
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
    /// trash for safety, then asks the running daemon to push the
    /// reverted version immediately.
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
            //    Atomic-write so a watcher doesn't observe a
            //    half-written file (though we don't seed the
            //    echo fence — restore is a deliberate user
            //    write that SHOULD reach the daemon).
            let snapshotText = try Snapshots.read(entry)
            try PathUtilities.atomicWriteText(snapshotText, to: target)
            print("restored to snapshot \(formatDisplayStamp(entry.stamp)) (\(entry.wordCount) words)")

            // 3. Tell the daemon to push immediately. Falls
            //    through quietly if the daemon's down — the
            //    watcher will pick it up at next start.
            if IPCClientSync.pushPath(target.path) {
                print("daemon notified; push enqueued")
            } else {
                print("(daemon not running — start it and the file will push)")
            }
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

// MARK: - retry-parked

/// Force a push retry for every doc currently parked with
/// ``error_state = "push_failed"``. v0.2.26+.
///
/// Background: when ``rmapi put`` fails, the worker writes a
/// ``state.db`` row marking the doc as ``push_failed`` and
/// stamps its ``last_synced_md_hash`` with the bytes that *would
/// have* been uploaded. This stops the daemon from retry-looping
/// on every reconcile pass, but it also means subsequent
/// retry-attempts hit the worker's "skip if hash unchanged"
/// no-op short-circuit — the file's current content matches the
/// stored hash, so nothing happens.
///
/// This command sends a ``push_path`` IPC frame with ``force =
/// true`` for each parked doc, bypassing the no-op check. The
/// worker uses ``--force`` mode against rmapi (replace-existing
/// rather than create-new), which both handles the
/// already-tracked case and gives rmapi the explicit signal.
/// Successful retry → ``markPushed`` clears ``error_state``
/// → parked count drops. Failed retry → ``error_state`` re-set;
/// the cloud-health probe (v0.2.25) classifies the failure
/// (rmapi/cloud incompatibility vs auth vs per-doc).
///
/// Other ``error_state`` values (``parse_failed``,
/// ``bulk_delete_refused``) are NOT retried — those represent
/// failure modes where retrying without other action wouldn't
/// help. Targets ``push_failed`` only by design.
struct RetryParked: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "retry-parked",
        abstract: "Force a push retry for docs parked with error_state = push_failed."
    )

    @Flag(name: .long, help: "Show what would be retried without enqueuing.")
    var dryRun: Bool = false

    func run() async throws {
        _ = try Config.load()
        let state = try State(path: Paths.stateDBPath)
        let allDocs = try await state.allDocuments()
        let parked = allDocs.filter { $0.errorState == "push_failed" }

        if parked.isEmpty {
            print("No push-failed parked errors. Other error_state values "
                  + "(parse_failed, bulk_delete_refused) need different "
                  + "handling and aren't touched by this command.")
            return
        }

        print("Retrying \(parked.count) parked push(es):")
        for doc in parked {
            print("  - \(doc.localPath)")
        }
        if dryRun {
            print("")
            print("(dry-run; no IPC sent)")
            return
        }

        if !IPCClientSync.daemonIsUp() {
            print("")
            print("daemon not running — start it (`rmsync start`) and re-run.")
            throw ExitCode(1)
        }

        var enqueued = 0
        for doc in parked {
            // ``force = true`` bypasses the worker's
            // hash-unchanged no-op short-circuit. Without it the
            // retry would silently skip — see RetryParked
            // doc-comment for why.
            if IPCClientSync.pushPath(doc.localPath, force: true) {
                enqueued += 1
            } else {
                print("  ! IPC push_path failed for \(doc.localPath)")
            }
        }

        print("")
        print("Enqueued \(enqueued)/\(parked.count) push(es). Watch progress:")
        print("    rmsync status              # parked count drops as pushes succeed")
        print("    rmsync logs --tail         # see per-doc push results")
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
/// And tails with class-specific next-action hints (``rmsync
/// retry-parked`` for ``push_failed``, ``rmapi rm`` + repull
/// for ``parse_failed``, etc.). The ``cloud_health`` IPC field
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

        // Per-class next-action hints. The user shouldn't have to
        // remember which command to run for which failure mode —
        // print the right one inline.
        let classes = Set(parked.compactMap(\.errorState))
        if classes.contains("push_failed") {
            print("To retry push_failed docs (no SQL, no file edits):")
            print("    rmsync retry-parked")
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
            print("bulk_delete_refused means the bulk-delete brake")
            print("(`[deletion].bulk_delete_threshold`) tripped. Either:")
            print("  • Run `rmsync retry-parked` to re-attempt — the brake's")
            print("    rolling window will have aged out.")
            print("  • Restore the file(s) you didn't mean to delete via")
            print("    `rmsync trash list / restore`.")
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
