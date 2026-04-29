// POSIX socket primitives. The menubar target only builds on macOS
// (gated in Package.swift), so Darwin is always available here — but
// match IPCServer/IPCClientSync's import shape for consistency.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

struct StatusSnapshot {
    let state: String
    let syncDir: String
    let remoteFolder: String
    let trackedDocs: Int
    let conflicts: Int
    let errors: Int
    let queueDepth: Int
    let lastPullAt: String?
    let lastPushAt: String?
    let lastError: String?
    let updatedAt: String
    let pid: Int?
    /// Version string reported by the daemon over IPC. Empty if the
    /// daemon is older than the field (pre-Swift-version-stamp) or
    /// didn't send it. Separate from this menubar binary's own
    /// ``Version.current`` — divergence between the two is actionable.
    let daemonVersion: String
}

/// Persistent Unix-socket client for the rmsync daemon.
///
/// Uses POSIX `socket(2)` + `DispatchSourceRead` directly. Network.framework's
/// `NWConnection` has quirks with Unix domain sockets that caused spurious
/// isComplete=true readings after the first hello frame, producing a
/// reconnect loop. Plain POSIX + Dispatch avoids that entirely.
final class IPCClient {
    typealias StatusCallback = (StatusSnapshot?) -> Void

    private let socketPath: String
    private let callback: StatusCallback
    private let queue = DispatchQueue(label: "com.user.rmsync.menubar.ipc")

    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var buffer = Data()
    private var backoffMs: Int = 250
    private var reconnectWorkItem: DispatchWorkItem?
    private var nextRequestId = 1
    private var shouldRun = false

    init(callback: @escaping StatusCallback) {
        self.socketPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/rmsync/ipc.sock")
            .path
        self.callback = callback
    }

    func start() {
        queue.async { [weak self] in
            self?.shouldRun = true
            self?.connect()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.shouldRun = false
            self?.reconnectWorkItem?.cancel()
            self?.tearDown()
        }
    }

    // MARK: - public commands

    func setPaused(_ paused: Bool) {
        send(["type": paused ? "pause" : "resume"])
    }

    func syncNow() {
        send(["type": "sync_now"])
    }

    func restartDaemon() {
        let uid = getuid()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["kickstart", "-k", "gui/\(uid)/com.user.rmsync"]
        try? task.run()
    }

    // MARK: - socket lifecycle

    private func connect() {
        guard shouldRun else { return }
        tearDown()

        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            scheduleReconnect()
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        // Copy socketPath into addr.sun_path (104 chars on macOS).
        let pathBytes = socketPath.utf8CString
        if pathBytes.count > MemoryLayout.size(ofValue: addr.sun_path) {
            close(sock)
            scheduleReconnect()
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                _ = memcpy(dst, pathBytes.withUnsafeBufferPointer { $0.baseAddress }, pathBytes.count)
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPtr in
                // Explicit Darwin. qualifier — the enclosing class
                // declares an instance method named ``connect`` that
                // would otherwise shadow the libc function. The
                // menubar target only builds on macOS, so Darwin is
                // always available.
                Darwin.connect(sock, addrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            close(sock)
            callback(nil)
            scheduleReconnect()
            return
        }

        fd = sock
        buffer.removeAll(keepingCapacity: true)
        backoffMs = 250  // reset on connect

        let src = DispatchSource.makeReadSource(fileDescriptor: sock, queue: queue)
        src.setEventHandler { [weak self] in
            self?.onReadable()
        }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fd >= 0 {
                close(self.fd)
                self.fd = -1
            }
        }
        src.resume()
        readSource = src
    }

    private func tearDown() {
        if let src = readSource {
            src.cancel()
            readSource = nil
        } else if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    private func scheduleReconnect() {
        guard shouldRun else { return }
        reconnectWorkItem?.cancel()

        let item = DispatchWorkItem { [weak self] in
            guard let self, self.shouldRun else { return }
            self.connect()
        }
        reconnectWorkItem = item
        queue.asyncAfter(deadline: .now() + .milliseconds(backoffMs), execute: item)
        backoffMs = min(backoffMs * 2, 5000)
    }

    // MARK: - reading

    private func onReadable() {
        guard fd >= 0 else { return }
        var chunk = [UInt8](repeating: 0, count: 8192)
        let n = chunk.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress, $0.count) }
        if n > 0 {
            buffer.append(contentsOf: chunk[0..<Int(n)])
            drainBuffer()
        } else if n == 0 {
            // EOF — daemon closed. Disconnect and reconnect.
            callback(nil)
            tearDown()
            scheduleReconnect()
        } else {
            // n < 0: error. EAGAIN means "try again"; others are fatal.
            let err = errno
            if err != EAGAIN && err != EWOULDBLOCK {
                callback(nil)
                tearDown()
                scheduleReconnect()
            }
        }
    }

    private func drainBuffer() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: 0..<newline)
            buffer.removeSubrange(0...newline)
            guard !line.isEmpty else { continue }
            handleFrame(line)
        }
    }

    private func handleFrame(_ line: Data) {
        guard let raw = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return }
        let type = raw["type"] as? String ?? ""

        switch type {
        case "hello":
            if let status = raw["status"] as? [String: Any] {
                callback(snapshot(from: status))
            }
        case "status":
            callback(snapshot(from: raw))
        case "ack":
            break
        default:
            break
        }
    }

    private func snapshot(from raw: [String: Any]) -> StatusSnapshot {
        StatusSnapshot(
            state: raw["state"] as? String ?? "unknown",
            syncDir: raw["sync_dir"] as? String ?? "",
            remoteFolder: raw["remote_folder"] as? String ?? "",
            trackedDocs: raw["tracked_docs"] as? Int ?? 0,
            conflicts: raw["conflicts"] as? Int ?? 0,
            errors: raw["errors"] as? Int ?? 0,
            queueDepth: raw["queue_depth"] as? Int ?? 0,
            lastPullAt: raw["last_pull_at"] as? String,
            lastPushAt: raw["last_push_at"] as? String,
            lastError: raw["last_error"] as? String,
            updatedAt: raw["updated_at"] as? String ?? "",
            pid: raw["pid"] as? Int,
            daemonVersion: raw["version"] as? String ?? ""
        )
    }

    // MARK: - writing

    private func send(_ frame: [String: Any]) {
        queue.async { [weak self] in
            guard let self, self.fd >= 0 else { return }
            var payload = frame
            payload["id"] = "m\(self.nextRequestId)"
            self.nextRequestId += 1

            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
            var withNewline = data
            withNewline.append(0x0A)
            _ = withNewline.withUnsafeBytes { buf -> Int in
                write(self.fd, buf.baseAddress, buf.count)
            }
        }
    }
}
