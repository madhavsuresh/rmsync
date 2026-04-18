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

struct StartCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Start the launchd agent.")
    func run() throws {
        if Launchd.isRunning() { print("already running"); return }
        let r = Launchd.start()
        if r.ok { print("started") }
        else {
            print("failed to start: \(r.error ?? "unknown")")
            throw ExitCode(1)
        }
    }
}

struct StopCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop the launchd agent.")
    func run() throws {
        print(Launchd.stop() ? "stopped" : "was not running")
    }
}

struct RestartCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart",
        abstract: "Kick the launchd agent (use after code changes)."
    )
    func run() throws {
        let r = Launchd.restart()
        if r.ok { print("restarted") } else {
            print("restart failed: \(r.error ?? "unknown")")
            throw ExitCode(1)
        }
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

    func run() throws {
        let path = Paths.logDir.appendingPathComponent("stdout.log")
        guard FileManager.default.fileExists(atPath: path.path) else {
            print("no log file at \(path.path)")
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
}

struct Conflicts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List unresolved conflicts.")
    func run() async throws {
        guard FileManager.default.fileExists(atPath: Paths.stateDBPath.path) else {
            print("no state DB")
            return
        }
        let state = try State(path: Paths.stateDBPath)
        let docs = try await state.allDocuments()
        let conflicts = docs.filter { $0.conflictState == "unresolved" }
        if conflicts.isEmpty { print("no unresolved conflicts"); return }
        for d in conflicts {
            let md = URL(fileURLWithPath: d.localPath)
            let cp = md.appendingPathExtension("conflict")
            print(d.docID)
            print("  live:     \(md.path)")
            let present = FileManager.default.fileExists(atPath: cp.path)
            print("  conflict: \(cp.path) \(present ? "(present)" : "(MISSING)")")
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
