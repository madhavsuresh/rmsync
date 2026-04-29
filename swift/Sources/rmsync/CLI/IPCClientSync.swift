// POSIX socket primitives — see IPCServer.swift for the rationale.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Synchronous IPC client used by the CLI. One-shot connect / send /
/// read-until-ack / disconnect. Mirrors the Python ``ipc_client.request``.
enum IPCClientSync {
    enum CallError: Error {
        case daemonUnavailable(String)
        case commandFailed(String)
        case malformedResponse
    }

    /// Send one command and block until the matching ack arrives. Skips
    /// unrelated ``status`` broadcasts.
    static func request(
        _ command: String,
        extra: [String: Any] = [:],
        timeout: TimeInterval = 2.0,
        socketPath: URL = Paths.ipcSocketPath
    ) throws -> [String: Any] {
        let fd = try openSocket(path: socketPath, timeout: timeout)
        defer { close(fd) }

        // Set read timeout so a wedged daemon doesn't hang us forever.
        // ``tv_usec`` is ``Int32`` on Darwin's timeval but ``Int``
        // (``__suseconds_t`` typedef) on Glibc. ``suseconds_t`` is
        // declared on both, so we cast the fractional microseconds
        // through it for portability.
        var tv = timeval(
            tv_sec: Int(timeout),
            tv_usec: suseconds_t((timeout - floor(timeout)) * 1_000_000)
        )
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Consume the hello frame.
        _ = try readLine(fd: fd)

        let id = "c" + UUID().uuidString.prefix(8)
        var frame: [String: Any] = ["id": id, "type": command]
        for (k, v) in extra { frame[k] = v }
        let data = try JSONSerialization.data(withJSONObject: frame)
        var withNL = data
        withNL.append(0x0A)
        try writeAll(fd: fd, data: withNL)

        while true {
            let line = try readLine(fd: fd)
            guard let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw CallError.malformedResponse
            }
            let type = obj["type"] as? String
            let ackID = obj["id"] as? String
            if type == "ack" && ackID == id {
                if (obj["ok"] as? Bool) != true {
                    throw CallError.commandFailed(
                        (obj["error"] as? String) ?? "command failed"
                    )
                }
                return obj
            }
            // Otherwise it's an unrelated status broadcast; loop.
        }
    }

    /// Go get the current daemon status. Returns nil if the daemon isn't
    /// running or the IPC request fails.
    ///
    /// We avoid ``JSONDecoder`` here because the ``JSONSerialization``
    /// step represents small integers as ``NSNumber`` with ambiguous
    /// type tags; decoding back into the strongly-typed ``IPC.Status``
    /// trips Swift 6's strict int/bool separation on the ``conflicts``
    /// / ``errors`` fields. Reading via ``[String: Any]`` keeps things
    /// simple and the status dict is small enough that the manual
    /// mapping is cheap.
    static func getStatus(timeout: TimeInterval = 2.0) -> IPC.Status? {
        guard let resp = try? request("get_status", timeout: timeout),
              let raw = resp["status"] as? [String: Any]
        else { return nil }

        func intValue(_ k: String) -> Int {
            if let n = raw[k] as? Int { return n }
            if let n = raw[k] as? NSNumber { return n.intValue }
            return 0
        }
        func boolValue(_ k: String) -> Bool {
            if let b = raw[k] as? Bool { return b }
            if let n = raw[k] as? NSNumber { return n.boolValue }
            return false
        }
        func stringValue(_ k: String) -> String {
            raw[k] as? String ?? ""
        }
        func optionalString(_ k: String) -> String? {
            if raw[k] is NSNull { return nil }
            return raw[k] as? String
        }

        return IPC.Status(
            state: stringValue("state"),
            syncDir: stringValue("sync_dir"),
            remoteFolder: stringValue("remote_folder"),
            trackedDocs: intValue("tracked_docs"),
            conflicts: intValue("conflicts"),
            errors: intValue("errors"),
            queueDepth: intValue("queue_depth"),
            lastPullAt: optionalString("last_pull_at"),
            lastPushAt: optionalString("last_push_at"),
            lastError: optionalString("last_error"),
            paused: boolValue("paused"),
            updatedAt: stringValue("updated_at"),
            pid: intValue("pid"),
            version: stringValue("version")
        )
    }

    static func daemonIsUp(timeout: TimeInterval = 0.2) -> Bool {
        guard let fd = try? openSocket(path: Paths.ipcSocketPath, timeout: timeout) else { return false }
        close(fd)
        return true
    }

    // MARK: - internals

    /// Opens an AF_UNIX socket and connects it to ``path``. Renamed from
    /// ``connect`` to ``openSocket`` so the libc ``connect(2)`` call at
    /// the bottom of this function (which is now unqualified after
    /// dropping the ``Darwin.`` prefix for cross-platform builds) doesn't
    /// resolve to *this* method recursively. Same problem as
    /// IPCClient.swift's instance-method shadowing.
    private static func openSocket(path: URL, timeout: TimeInterval) throws -> Int32 {
        // ``SOCK_STREAM_I32`` (defined in IPC/PosixCompat.swift)
        // normalises the Darwin/Glibc type difference for the
        // ``socket(2)`` type parameter.
        let fd = socket(AF_UNIX, SOCK_STREAM_I32, 0)
        guard fd >= 0 else { throw CallError.daemonUnavailable("socket() failed") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathCStr = path.path.utf8CString
        guard pathCStr.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw CallError.daemonUnavailable("socket path too long")
        }
        // See IPCServer.swift for why this uses ``withUnsafeMutableBytes``
        // instead of ``withUnsafeMutablePointer`` — the sun_path tuple
        // shape differs between Darwin and Glibc, breaking type
        // inference of the pointer closure.
        // See IPCServer.swift for why memcpy needs the non-optional
        // pointer guard on Linux.
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            pathCStr.withUnsafeBufferPointer { src in
                guard let d = dst.baseAddress, let s = src.baseAddress else { return }
                _ = memcpy(d, s, pathCStr.count)
            }
        }

        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPtr in
                connect(fd, addrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            close(fd)
            throw CallError.daemonUnavailable("connect() failed: errno=\(errno)")
        }
        _ = timeout
        return fd
    }

    private static func readLine(fd: Int32) throws -> Data {
        // Read up to 4 KiB at a time so we don't round-trip per byte;
        // split on the first newline and keep any tail in the buffer
        // for the next call via a per-fd buffer.
        var accumulated = lineBuffer(for: fd)
        while !accumulated.contains(0x0A) {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = chunk.withUnsafeMutableBufferPointer {
                read(fd, $0.baseAddress, $0.count)
            }
            if n > 0 {
                accumulated.append(contentsOf: chunk[0..<n])
                continue
            }
            // ``SO_RCVTIMEO`` returns -1 with errno=EAGAIN on timeout,
            // and 0 on a clean close. Treat timeout as "give up", close
            // as "daemon gone".
            if n == 0 {
                setLineBuffer(fd: fd, to: accumulated)
                throw CallError.daemonUnavailable("daemon closed connection")
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                setLineBuffer(fd: fd, to: accumulated)
                throw CallError.daemonUnavailable("read timed out")
            }
            setLineBuffer(fd: fd, to: accumulated)
            throw CallError.daemonUnavailable("read failed: errno=\(errno)")
        }
        // Split on the first newline.
        let nlIndex = accumulated.firstIndex(of: 0x0A)!
        let line = Data(accumulated[0..<nlIndex])
        let tail = accumulated[(nlIndex + 1)...]
        setLineBuffer(fd: fd, to: Array(tail))
        return line
    }

    // Per-fd read buffer so multi-frame reads (hello + ack) don't drop
    // bytes that arrived together.
    nonisolated(unsafe) private static var lineBuffers: [Int32: [UInt8]] = [:]
    private static let lineBufferLock = NSLock()

    private static func lineBuffer(for fd: Int32) -> [UInt8] {
        lineBufferLock.lock(); defer { lineBufferLock.unlock() }
        return lineBuffers[fd] ?? []
    }

    private static func setLineBuffer(fd: Int32, to bytes: [UInt8]) {
        lineBufferLock.lock(); defer { lineBufferLock.unlock() }
        if bytes.isEmpty {
            lineBuffers.removeValue(forKey: fd)
        } else {
            lineBuffers[fd] = bytes
        }
    }

    private static func writeAll(fd: Int32, data: Data) throws {
        var sent = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                throw CallError.daemonUnavailable("empty buffer")
            }
            while sent < raw.count {
                let n = write(fd, base.advanced(by: sent), raw.count - sent)
                if n < 0 { throw CallError.daemonUnavailable("write failed") }
                sent += n
            }
        }
    }
}
