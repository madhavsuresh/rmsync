import ArgumentParser
import Foundation

/// `rmsync doctor` — health checks for the daemon environment.
///
/// Port of ``src/rm_sync/doctor.py``. Same ten checks (minus the dropped
/// subscription heuristic, which the Python port removed), same three
/// status levels, same exit semantics: 0 when nothing fails, 1 otherwise.
struct DoctorRun {
    enum Status: String, Sendable { case ok, warn, fail }

    struct CheckResult: Sendable {
        let name: String
        let status: Status
        let message: String
    }

    static func runAll() async -> [CheckResult] {
        var results: [CheckResult] = []

        // Config load is used by several subsequent checks.
        let cfg: Config?
        var configError: String?
        do {
            cfg = try Config.load()
        } catch {
            cfg = nil
            configError = "\(error)"
        }

        results.append(await rmapiPresent())
        results.append(await rmapiVersion())
        results.append(await rmapiAuthed())
        results.append(staleIO41Tap())
        results.append(await writingFolder(cfg: cfg, configError: configError))
        results.append(syncDir(cfg: cfg, configError: configError))
        results.append(cloudProviderSyncDir(cfg: cfg))
        results.append(await stateDB())
        results.append(launchdLoaded())
        results.append(diskSpace(cfg: cfg))
        results.append(logDir())
        results.append(clockSkew())
        return results
    }

    static func printAndExit(_ results: [CheckResult]) -> Int32 {
        var hasFail = false
        for r in results {
            let marker: String
            switch r.status {
            case .ok: marker = "✓"
            case .warn: marker = "!"
            case .fail: marker = "✗"
            }
            let nameField = r.name.padding(toLength: 24, withPad: " ", startingAt: 0)
            print("  \(marker) \(nameField) \(r.message)")
            if r.status == .fail { hasFail = true }
        }
        return hasFail ? 1 : 0
    }

    // MARK: - individual checks

    private static func rmapiPresent() async -> CheckResult {
        if let path = which("rmapi") {
            return CheckResult(name: "rmapi on PATH", status: .ok, message: path)
        }
        return CheckResult(name: "rmapi on PATH", status: .fail, message: "rmapi not found")
    }

    private static func rmapiVersion() async -> CheckResult {
        do {
            let cloud = Cloud()
            let v = try await cloud.version()
            let tuple = (v.0, v.1, v.2)
            if Cloud.tupleLE(Cloud.rmapiMin, tuple)
                && Cloud.tupleLT(tuple, Cloud.rmapiMaxExclusive) {
                return CheckResult(
                    name: "rmapi version",
                    status: .ok,
                    message: "\(v.0).\(v.1).\(v.2)"
                )
            }
            // Below the minimum is now a hard fail (was warn).
            // The cloud's schema-v4 rollout in late April 2026
            // means rmapi <0.0.32 returns HTTP 400 on every put;
            // users who see "warn" are tempted to ignore it,
            // but uploads silently break. Fail makes
            // ``rmsync doctor`` exit non-zero so the issue
            // surfaces in any automated install / health probe.
            let isTooOld = Cloud.tupleLT(tuple, Cloud.rmapiMin)
            return CheckResult(
                name: "rmapi version",
                status: isTooOld ? .fail : .warn,
                message: isTooOld
                    ? "\(v.0).\(v.1).\(v.2) too old — uploads WILL fail with HTTP 400. "
                      + "Upgrade: `brew install madhavsuresh/rmsync/rmapi` "
                      + "(uninstall io41/tap/rmapi first), or download from "
                      + "https://github.com/ddvk/rmapi/releases"
                    : "\(v.0).\(v.1).\(v.2) newer than tested range"
            )
        } catch {
            return CheckResult(name: "rmapi version", status: .fail, message: "\(error)")
        }
    }

    private static func rmapiAuthed() async -> CheckResult {
        // We probe via ``rmapi account`` rather than ``rmapi find /``.
        // ``find`` runs in interactive-shell mode (exit code is always 0,
        // so we scan stdout for throttle keywords); names of the user's
        // own documents have triggered false positives there. ``account``
        // is a normal subcommand: rc=0 + email on auth, rc!=0 + clear
        // error otherwise. Reported as a doctor false-positive on
        // 2026-04-27 — the user's `rmapi find /` worked when invoked
        // directly, but doctor's wrapper flagged it as throttled.
        let cloud = Cloud()
        do {
            _ = try await cloud.account()
            return CheckResult(name: "rmapi authenticated", status: .ok, message: "")
        } catch {
            return CheckResult(
                name: "rmapi authenticated",
                status: .fail,
                message: "`rmapi account` failed: \(error). Run `rmapi` once to authenticate."
            )
        }
    }

    /// Detect a stale ``io41/tap/rmapi`` install lingering after a
    /// pre-v0.2.24 → current upgrade. Two failure modes show up here:
    ///
    /// 1. The user did `brew upgrade rmsync` and it errored cryptically
    ///    on the rmapi conflict (``conflicts_with`` in the new formula).
    ///    rmsync itself is then NOT actually upgraded — they get the
    ///    half-broken state we're trying to flag.
    /// 2. The user uninstalled `madhavsuresh/rmsync/rmapi` somehow but
    ///    left io41/tap/rmapi as the rmapi-on-PATH. Doctor's existing
    ///    `rmapi version` check will already fail loudly if io41's pin
    ///    is too old; this check just gives the migration commands.
    ///
    /// Linux: brew is rare and io41 doesn't ship a Linux bottle, so the
    /// check no-ops cleanly.
    private static func staleIO41Tap() -> CheckResult {
        let name = "io41/tap migration"
        #if !os(macOS)
        return CheckResult(name: name, status: .ok, message: "n/a (non-macOS)")
        #else
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // ``brew list --formula io41/tap/rmapi`` exits 0 iff the
        // formula is currently installed. We don't care about stdout;
        // the exit code is the signal. Redirect both streams so a
        // chatty brew doesn't leak into doctor's tidy table.
        task.arguments = ["brew", "list", "--formula", "io41/tap/rmapi"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do { try task.run() } catch {
            // brew not installed at all — nothing to migrate from.
            return CheckResult(name: name, status: .ok, message: "brew not on PATH")
        }
        task.waitUntilExit()
        if task.terminationStatus == 0 {
            return CheckResult(
                name: name,
                status: .warn,
                message: "io41/tap/rmapi still installed; run "
                       + "`brew uninstall --ignore-dependencies io41/tap/rmapi "
                       + "&& brew untap io41/tap && brew upgrade rmsync` "
                       + "to finish the v0.2.24+ migration"
            )
        }
        return CheckResult(name: name, status: .ok, message: "no stale install")
        #endif
    }

    private static func writingFolder(cfg: Config?, configError: String?) async -> CheckResult {
        guard let cfg else {
            return CheckResult(
                name: "Writing folder",
                status: .fail,
                message: "config load failed: \(configError ?? "unknown")"
            )
        }
        let cloud = Cloud()
        do {
            _ = try await cloud.find("/\(cfg.remoteFolder)")
            return CheckResult(
                name: "Writing folder",
                status: .ok,
                message: cfg.remoteFolder
            )
        } catch {
            return CheckResult(
                name: "Writing folder",
                status: .fail,
                message: "`rmapi find /\(cfg.remoteFolder)` failed: \(error)"
            )
        }
    }

    private static func syncDir(cfg: Config?, configError: String?) -> CheckResult {
        guard let cfg else {
            return CheckResult(
                name: "sync_dir",
                status: .fail,
                message: configError ?? "config load failed"
            )
        }
        let fm = FileManager.default
        let path = cfg.syncDir.path
        if !fm.fileExists(atPath: path) {
            return CheckResult(
                name: "sync_dir",
                status: .warn,
                message: "\(path) doesn't exist (will be created)"
            )
        }
        if !fm.isWritableFile(atPath: path) {
            return CheckResult(name: "sync_dir", status: .fail, message: "\(path) not writable")
        }
        if let attrs = try? fm.attributesOfItem(atPath: path),
           let type = attrs[.type] as? FileAttributeType,
           type == .typeSymbolicLink {
            let target = (try? fm.destinationOfSymbolicLink(atPath: path)) ?? ""
            return CheckResult(name: "sync_dir", status: .warn, message: "symlink → \(target)")
        }
        return CheckResult(name: "sync_dir", status: .ok, message: path)
    }

    /// Warn when ``sync_dir`` lives inside a macOS File Provider cloud
    /// folder (Dropbox, iCloud, OneDrive, Google Drive, Box). Those
    /// providers can demote a "fully local" file to a dataless
    /// placeholder at any time to reclaim disk space — and when
    /// rmsync reads a dataless file it gets zero bytes, which the
    /// push path would happily propagate to reMarkable as "doc
    /// emptied". The push-side guard in ``SyncWorker.doPush`` catches
    /// this as a conflict, but the better fix is to prevent the
    /// eviction in the first place. This check just flags the
    /// situation so the user knows to pin the folder offline.
    private static func cloudProviderSyncDir(cfg: Config?) -> CheckResult {
        guard let cfg else {
            return CheckResult(
                name: "cloud-provider folder",
                status: .ok,
                message: "skipped (no config)"
            )
        }
        let path = cfg.syncDir.path
        // Each pattern maps to a provider-specific remediation hint.
        // Matching is substring-based against the absolute path, which
        // picks up both ``/Users/me/Library/CloudStorage/Dropbox``
        // and the ``~/Dropbox`` legacy layout that Dropbox still offers.
        let matches: [(pattern: String, provider: String)] = [
            ("/Library/CloudStorage/Dropbox", "Dropbox"),
            ("/Dropbox/", "Dropbox"),
            ("/Library/Mobile Documents/", "iCloud Drive"),
            ("/Library/CloudStorage/OneDrive", "OneDrive"),
            ("/Library/CloudStorage/GoogleDrive", "Google Drive"),
            ("/Library/CloudStorage/Box-Box", "Box"),
        ]
        for (pattern, provider) in matches where path.contains(pattern) {
            return CheckResult(
                name: "cloud-provider folder",
                status: .warn,
                message: "sync_dir is inside \(provider); " +
                         "right-click the rmsync folder in Finder → " +
                         "'Always keep on this device' to prevent eviction"
            )
        }
        return CheckResult(
            name: "cloud-provider folder",
            status: .ok,
            message: "not inside a known cloud provider"
        )
    }

    private static func stateDB() async -> CheckResult {
        let path = Paths.stateDBPath
        if !FileManager.default.fileExists(atPath: path.path) {
            return CheckResult(name: "state DB", status: .warn, message: "no state DB yet (first run)")
        }
        do {
            let state = try State(path: path)
            _ = try await state.allDocuments()
            return CheckResult(name: "state DB", status: .ok, message: path.path)
        } catch {
            return CheckResult(name: "state DB", status: .fail, message: "\(error)")
        }
    }

    private static func launchdLoaded() -> CheckResult {
        // Linux has no launchctl. Daemon supervision is Docker / systemd
        // / shell — none of which we can probe portably from inside the
        // daemon. Emit an informational ``ok`` so the doctor still
        // exits cleanly, with a label that's honest about the
        // platform difference.
        #if os(Linux)
        return CheckResult(
            name: "supervisor",
            status: .ok,
            message: "external (Docker / systemd / shell)"
        )
        #else
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["print", "gui/\(getuid())/\(Launchd.label)"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do { try task.run() } catch {
            return CheckResult(name: "launchd plist loaded", status: .warn, message: "launchctl not runnable")
        }
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            return CheckResult(
                name: "launchd plist loaded",
                status: .fail,
                message: "agent not loaded; run install.sh"
            )
        }
        return CheckResult(name: "launchd plist loaded", status: .ok, message: "")
        #endif
    }

    private static func diskSpace(cfg: Config?) -> CheckResult {
        guard let cfg else {
            return CheckResult(name: "disk space", status: .warn, message: "config unknown")
        }
        let target = FileManager.default.fileExists(atPath: cfg.syncDir.path)
            ? cfg.syncDir
            : cfg.syncDir.deletingLastPathComponent()
        do {
            // ``volumeAvailableCapacityForImportantUsageKey`` is a
            // Darwin Foundation extension — Linux Foundation has only
            // ``volumeAvailableCapacityKey``. The "important usage"
            // variant is the macOS-recommended call because it
            // accounts for purgeable cache that the OS will reclaim
            // under pressure; on Linux we just use the raw available
            // capacity.
            #if os(macOS)
            let values = try target.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            let bytes = values.volumeAvailableCapacityForImportantUsage ?? 0
            #else
            let values = try target.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            let bytes = Int64(values.volumeAvailableCapacity ?? 0)
            #endif
            let gb = Double(bytes) / 1073741824.0
            if gb < 1 {
                return CheckResult(name: "disk space", status: .fail, message: String(format: "%.2f GB free", gb))
            }
            return CheckResult(name: "disk space", status: .ok, message: String(format: "%.1f GB free", gb))
        } catch {
            return CheckResult(name: "disk space", status: .warn, message: "\(error)")
        }
    }

    private static func logDir() -> CheckResult {
        let path = Paths.logDir
        let fm = FileManager.default
        if !fm.fileExists(atPath: path.path) {
            return CheckResult(name: "log dir", status: .warn, message: "\(path.path) doesn't exist")
        }
        if !fm.isWritableFile(atPath: path.path) {
            return CheckResult(name: "log dir", status: .fail, message: "\(path.path) not writable")
        }
        return CheckResult(name: "log dir", status: .ok, message: path.path)
    }

    private static func clockSkew() -> CheckResult {
        // Same placeholder as the Python version — we rely on the OS to
        // keep the clock aligned and only surface this if sync15 starts
        // returning skew errors.
        CheckResult(name: "clock", status: .ok, message: "skipped (relying on macOS time sync)")
    }

    // MARK: - helpers

    private static func which(_ name: String) -> String? {
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in pathEnv.split(separator: ":") {
            let candidate = String(dir) + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
