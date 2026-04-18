import Darwin
import Foundation

/// Small wrapper around ``launchctl`` for start / stop / restart. Matches
/// the Python implementation's retry-with-backoff behaviour so
/// stop-then-start in quick succession is reliable.
enum Launchd {
    static let label = "com.user.rmsync"
    static let menubarLabel = "com.user.rmsync.menubar"

    static func plistPath(label: String = Launchd.label) -> URL {
        Paths.home.appendingPathComponent(
            "Library/LaunchAgents/\(label).plist"
        )
    }

    static func isRunning(label: String = Launchd.label) -> Bool {
        let out = runLaunchctl(["print", "gui/\(getuid())/\(label)"])
        guard out.exit == 0 else { return false }
        return out.stdout.contains("state = running") || out.stdout.contains("state = waiting")
    }

    static func stop(label: String = Launchd.label) -> Bool {
        guard isRunning(label: label) else { return false }
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
        // Wait briefly for the process to actually exit.
        for _ in 0..<20 {
            if !isRunning(label: label) { return true }
            usleep(100_000)
        }
        return true
    }

    @discardableResult
    static func start(label: String = Launchd.label) -> (ok: Bool, error: String?) {
        let plist = plistPath(label: label)
        guard FileManager.default.fileExists(atPath: plist.path) else {
            return (false, "plist missing at \(plist.path)")
        }
        if isRunning(label: label) { return (true, nil) }

        var backoffMs = 250
        var lastError = ""
        for _ in 0..<4 {
            let r = runLaunchctl(["bootstrap", "gui/\(getuid())", plist.path])
            if r.exit == 0 || isRunning(label: label) { return (true, nil) }
            lastError = r.stderr.isEmpty ? r.stdout : r.stderr
            usleep(UInt32(backoffMs * 1000))
            backoffMs = min(backoffMs * 2, 5000)
        }
        return (false, lastError)
    }

    @discardableResult
    static func restart(label: String = Launchd.label) -> (ok: Bool, error: String?) {
        if !isRunning(label: label) {
            return start(label: label)
        }
        let r = runLaunchctl(["kickstart", "-k", "gui/\(getuid())/\(label)"])
        if r.exit == 0 { return (true, nil) }
        return (false, r.stderr.isEmpty ? r.stdout : r.stderr)
    }

    // MARK: - private

    private struct Result: Sendable {
        let exit: Int32
        let stdout: String
        let stderr: String
    }

    private static func runLaunchctl(_ args: [String]) -> Result {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = args
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        do { try task.run() } catch {
            return Result(exit: -1, stdout: "", stderr: "\(error)")
        }
        task.waitUntilExit()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        return Result(
            exit: task.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
