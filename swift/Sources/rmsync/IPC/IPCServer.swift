import Darwin
import Dispatch
import Foundation

/// POSIX-socket IPC server.
///
/// Uses ``socket``/``listen``/``accept`` directly. Matches the Python
/// daemon's protocol byte-for-byte so the existing menu bar and CLI work
/// unchanged.
actor IPCServer {
    typealias CommandHandler = @Sendable (SendableJSON) async -> SendableJSON

    private let socketPath: URL
    private let bus: StateBus
    private var handlers: [String: CommandHandler] = [:]
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.user.rmsync.ipc.accept")

    init(socketPath: URL, bus: StateBus) {
        self.socketPath = socketPath
        self.bus = bus
    }

    func register(_ command: String, handler: @escaping CommandHandler) {
        handlers[command] = handler
    }

    func start() throws {
        try? FileManager.default.removeItem(at: socketPath)
        try FileManager.default.createDirectory(
            at: socketPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.socketCreateFailed(errno: errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath.path
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            throw IPCError.pathTooLong(path)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                _ = memcpy(dst, pathBytes.withUnsafeBufferPointer { $0.baseAddress }, pathBytes.count)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPtr in
                Darwin.bind(fd, addrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            Darwin.close(fd)
            throw IPCError.bindFailed(errno: err)
        }

        _ = chmod(path, 0o600)

        guard Darwin.listen(fd, 16) == 0 else {
            let err = errno
            Darwin.close(fd)
            throw IPCError.listenFailed(errno: err)
        }

        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let listenFDCopy = fd
        let handlersCopy = self.handlers
        let busCopy = self.bus
        src.setEventHandler {
            Self.acceptLoop(listenFD: listenFDCopy, bus: busCopy, handlers: handlersCopy)
        }
        src.setCancelHandler { [weak self] in
            Task { await self?.closeListenFD() }
        }
        src.resume()
        acceptSource = src
    }

    private func closeListenFD() {
        if listenFD >= 0 {
            Darwin.close(listenFD)
            listenFD = -1
        }
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        try? FileManager.default.removeItem(at: socketPath)
    }

    // MARK: - accept + handler

    private static func acceptLoop(
        listenFD: Int32, bus: StateBus, handlers: [String: CommandHandler]
    ) {
        while true {
            var peer = sockaddr_un()
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let client = withUnsafeMutablePointer(to: &peer) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPtr in
                    Darwin.accept(listenFD, addrPtr, &len)
                }
            }
            if client < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            Task.detached {
                await Self.runClient(fd: client, bus: bus, handlers: handlers)
            }
        }
    }

    private static func runClient(
        fd: Int32, bus: StateBus, handlers: [String: CommandHandler]
    ) async {
        defer { Darwin.close(fd) }

        let hello = await StateBus.helloFrame(for: bus.snapshot())
        guard writeFrame(fd: fd, payload: hello) else { return }

        let (stream, subID) = await bus.subscribe()
        let writerTask = Task.detached { [stream] in
            for await frame in stream {
                if !writeFrame(fd: fd, payload: frame) { break }
            }
        }
        defer {
            writerTask.cancel()
            Task { await bus.unsubscribe(id: subID) }
        }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBufferPointer {
                Darwin.read(fd, $0.baseAddress, $0.count)
            }
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<Int(n)])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: 0..<nl)
                buffer.removeSubrange(0...nl)
                guard !line.isEmpty else { continue }
                await handleFrame(line: line, fd: fd, handlers: handlers)
            }
        }
    }

    private static func handleFrame(
        line: Data, fd: Int32, handlers: [String: CommandHandler]
    ) async {
        guard let raw = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            _ = writeFrame(fd: fd, payload: SendableJSON.dict([
                "type": "ack", "ok": false, "error": "invalid json"
            ]))
            return
        }
        guard let cmd = raw["type"] as? String else { return }
        if cmd == "ack" || cmd == "hello" || cmd == "status" { return }

        var ackPayload: [String: SendableValue] = ["type": "ack"]
        if let id = raw["id"] as? String { ackPayload["id"] = .string(id) }

        if let handler = handlers[cmd] {
            let request = (try? SendableJSON(raw)) ?? SendableJSON.dict([:])
            let result = await handler(request)
            if let dict = result.decodeDict() {
                for (k, v) in dict {
                    ackPayload[k] = Self.convert(v)
                }
            }
            if ackPayload["ok"] == nil { ackPayload["ok"] = .bool(true) }
        } else {
            ackPayload["ok"] = .bool(false)
            ackPayload["error"] = .string("unknown command: \(cmd)")
        }
        _ = writeFrame(fd: fd, payload: SendableJSON.dict(ackPayload))
    }

    /// Best-effort ``Any`` → ``SendableValue`` conversion for handler
    /// responses. Unknown types become null.
    private static func convert(_ v: Any) -> SendableValue {
        if v is NSNull { return .null }
        if let s = v as? String { return .string(s) }
        if let b = v as? Bool { return .bool(b) }
        if let i = v as? Int { return .int(i) }
        if let d = v as? Double { return .double(d) }
        if let arr = v as? [Any] { return .array(arr.map(Self.convert)) }
        if let dict = v as? [String: Any] {
            return .object(Dictionary(uniqueKeysWithValues: dict.map { ($0.key, Self.convert($0.value)) }))
        }
        return .null
    }

    private static func writeFrame(fd: Int32, payload: SendableJSON) -> Bool {
        var withNewline = payload.data
        withNewline.append(0x0A)
        var sent = 0
        return withNewline.withUnsafeBytes { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            while sent < buf.count {
                let n = Darwin.write(fd, base.advanced(by: sent), buf.count - sent)
                if n < 0 { return false }
                sent += n
            }
            return true
        }
    }
}

enum IPCError: Error, CustomStringConvertible {
    case socketCreateFailed(errno: Int32)
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)
    case pathTooLong(String)

    var description: String {
        switch self {
        case .socketCreateFailed(let e): return "socket() failed: errno=\(e)"
        case .bindFailed(let e): return "bind() failed: errno=\(e)"
        case .listenFailed(let e): return "listen() failed: errno=\(e)"
        case .pathTooLong(let p): return "socket path too long for AF_UNIX: \(p)"
        }
    }
}
