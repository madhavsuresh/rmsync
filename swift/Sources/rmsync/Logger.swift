import Foundation

// ``os.Logger`` is macOS / iOS / tvOS / watchOS only — it's the
// Apple unified logging system, not available in Linux Foundation.
// The cross-platform path (every line below the ``#if`` block) is
// stderr-only, which is exactly what Docker captures via
// ``docker logs`` and what launchd's ``StandardErrorPath`` writes
// to ``~/Library/Logs/rmsync/stderr.log`` on macOS.
#if canImport(os)
import os
#endif

/// Structured-ish JSON logger that writes to stderr. Matches the shape of
/// the Python daemon's structlog output so existing log-tailing scripts
/// keep working. It also appends every event to ``events.log`` so CLI-run
/// explicit sync operations and daemon-run operations share one audit trail.
/// On macOS, also surfaces stderr-backed events via ``os.Logger`` so they
/// appear in Console.app.
final class Logger: Sendable {
    static let shared = Logger()

    #if canImport(os)
    private let system = os.Logger(subsystem: "com.user.rmsync", category: "daemon")
    #endif

    private init() {}

    func info(_ event: String, meta: [String: String] = [:]) {
        emit(level: "info", event: event, meta: meta)
    }

    func warn(_ event: String, meta: [String: String] = [:]) {
        emit(level: "warning", event: event, meta: meta)
    }

    func error(_ event: String, meta: [String: String] = [:]) {
        emit(level: "error", event: event, meta: meta)
    }

    func debug(_ event: String, meta: [String: String] = [:]) {
        emit(level: "debug", event: event, meta: meta)
    }

    /// Append a structured event to the shared event log without making
    /// normal CLI output noisy. If the install is configured for stdout-only
    /// logging, this falls back to stderr so the event is still observable.
    func audit(_ event: String, meta: [String: String] = [:], level: String = "info") {
        emit(level: level, event: event, meta: meta, writeStandardError: false)
    }

    // MARK: - internals

    private func emit(
        level: String,
        event: String,
        meta: [String: String],
        writeStandardError: Bool = true
    ) {
        var payload: [String: Any] = [
            "level": level,
            "event": event,
            "timestamp": ISO8601.now(),
        ]
        for (k, v) in meta { payload[k] = v }

        // stderr: one JSON line per event, matches structlog's JSONRenderer.
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let line = String(data: data, encoding: .utf8) {
            let lineData = Data((line + "\n").utf8)
            let stdoutOnly = ProcessInfo.processInfo.environment["RM_SYNC_LOG_STDOUT"] == "1"
            if writeStandardError || stdoutOnly {
                FileHandle.standardError.write(lineData)
            }
            if !stdoutOnly {
                appendEventLog(lineData)
            }
        }

        // Also surface via os.Logger so Console.app sees it. On Linux,
        // there is no analogue — the JSON stderr write above is the
        // single sink, and Docker / journald / a redirected file
        // captures it for the user.
        #if canImport(os)
        switch level {
        case "error": system.error("\(event, privacy: .public)")
        case "warning": system.warning("\(event, privacy: .public)")
        case "debug": system.debug("\(event, privacy: .public)")
        default: system.info("\(event, privacy: .public)")
        }
        #endif
    }

    private func appendEventLog(_ data: Data) {
        let url = Paths.logDir.appendingPathComponent("events.log")
        do {
            try FileManager.default.createDirectory(
                at: Paths.logDir,
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } catch {
            // Logging must never become the reason sync work fails.
        }
    }
}
