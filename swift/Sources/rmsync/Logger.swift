import Foundation
import os

/// Structured-ish JSON logger that writes to stderr. Matches the shape of
/// the Python daemon's structlog output so existing log-tailing scripts
/// keep working. Backed by ``os.Logger`` for Console.app integration.
///
/// Full port of ``src/rm_sync/logging_setup.py`` arrives in a later week;
/// this is just enough to give every module something to call into.
final class Logger: Sendable {
    static let shared = Logger()

    private let system = os.Logger(subsystem: "com.user.rmsync", category: "daemon")

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

    // MARK: - internals

    private func emit(level: String, event: String, meta: [String: String]) {
        var payload: [String: Any] = [
            "level": level,
            "event": event,
            "timestamp": ISO8601.now(),
        ]
        for (k, v) in meta { payload[k] = v }

        // stderr: one JSON line per event, matches structlog's JSONRenderer.
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let line = String(data: data, encoding: .utf8) {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }

        // Also surface via os.Logger so Console.app sees it.
        switch level {
        case "error": system.error("\(event, privacy: .public)")
        case "warning": system.warning("\(event, privacy: .public)")
        case "debug": system.debug("\(event, privacy: .public)")
        default: system.info("\(event, privacy: .public)")
        }
    }
}
