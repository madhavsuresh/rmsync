// Optional HTTP dashboard. Embed-only — listens on a TCP port,
// serves a single HTML page plus a small JSON API, talks to the
// existing ``StateBus`` and auto-push queue. Useful for Docker users
// who don't have the macOS menubar.
//
// Built directly on POSIX sockets (same recipe as IPCServer). No
// third-party HTTP library — the surface is tiny (5 endpoints,
// Bearer-token auth, no streaming) and a hand-rolled parser is
// ~150 lines of Swift, vs. taking on swift-nio or similar as a
// dependency for a single feature.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

/// Embedded HTTP dashboard. Lifecycle parallels ``IPCServer``: the
/// daemon constructs one, registers the bus + handlers, calls
/// ``start()``; ``stop()`` closes the listen fd via the
/// DispatchSource cancel handler.
actor HTTPServer {
    typealias Action = @Sendable () async -> Void

    private let bindAddr: String
    private let port: Int
    /// Required ``Authorization: Bearer`` token. Always non-nil when
    /// the server runs — DaemonScaffold generates a random token if
    /// the user didn't set one in config so the dashboard is never
    /// unauthenticated.
    private let authToken: String
    private let bus: StateBus
    private let queue: AutoPushEventQueue
    private let state: State

    /// Action handlers registered by the daemon. Each one is invoked
    /// on the matching ``POST /api/<name>`` endpoint.
    private var actions: [String: Action] = [:]
    private var acceptSource: DispatchSourceRead?
    private let dispatchQ = DispatchQueue(label: "com.user.rmsync.web.accept")

    init(
        bindAddr: String,
        port: Int,
        authToken: String,
        bus: StateBus,
        queue: AutoPushEventQueue,
        state: State
    ) {
        self.bindAddr = bindAddr
        self.port = port
        self.authToken = authToken
        self.bus = bus
        self.queue = queue
        self.state = state
    }

    func register(_ name: String, action: @escaping Action) {
        actions[name] = action
    }

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM_I32, 0)
        guard fd >= 0 else {
            throw HTTPServerError.socketCreateFailed(errno: errno)
        }

        // SO_REUSEADDR so a daemon restart doesn't spend 60s in
        // TIME_WAIT before the new listener can bind. Standard for
        // long-running services.
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        #if os(macOS)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = htons(UInt16(port))

        // Parse ``bindAddr`` (e.g. ``127.0.0.1``, ``0.0.0.0``) into
        // an ``in_addr`` via ``inet_pton``. Reject malformed input.
        var inAddr = in_addr()
        let parseRC = bindAddr.withCString { cstr in
            inet_pton(AF_INET, cstr, &inAddr)
        }
        guard parseRC == 1 else {
            close(fd)
            throw HTTPServerError.invalidBindAddr(bindAddr)
        }
        addr.sin_addr = inAddr

        let bindRC = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPtr in
                bind(fd, addrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRC == 0 else {
            let err = errno
            close(fd)
            throw HTTPServerError.bindFailed(addr: bindAddr, port: port, errno: err)
        }

        guard listen(fd, 16) == 0 else {
            let err = errno
            close(fd)
            throw HTTPServerError.listenFailed(errno: err)
        }

        let listenFD = fd
        let actionsCopy = self.actions
        let token = self.authToken
        let busCopy = self.bus
        let queueCopy = self.queue
        let stateCopy = self.state
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: dispatchQ)
        src.setEventHandler {
            Self.acceptLoop(
                listenFD: listenFD,
                authToken: token,
                actions: actionsCopy,
                bus: busCopy,
                queue: queueCopy,
                state: stateCopy
            )
        }
        // Same pattern as IPCServer's cancel handler — close the fd
        // directly without bouncing through the actor (Swift 6
        // strict concurrency rejects the actor-self capture in a
        // sending closure).
        src.setCancelHandler {
            if listenFD >= 0 {
                close(listenFD)
            }
        }
        src.resume()
        self.acceptSource = src

        Logger.shared.info(
            "web dashboard listening",
            meta: [
                "addr": bindAddr,
                "port": "\(port)",
                "url": "http://\(bindAddr == "0.0.0.0" ? "<host>" : bindAddr):\(port)/?token=...",
            ]
        )
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        Logger.shared.info("web dashboard stopped")
    }

    // MARK: - accept loop + per-connection handler

    private static func acceptLoop(
        listenFD: Int32,
        authToken: String,
        actions: [String: Action],
        bus: StateBus,
        queue: AutoPushEventQueue,
        state: State
    ) {
        while true {
            var peer = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &peer) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPtr in
                    accept(listenFD, addrPtr, &len)
                }
            }
            if client < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            // Each connection on its own task — the dispatch queue
            // already serializes accept(), but request handling can
            // (in principle) run in parallel.
            Task.detached {
                await Self.handleConnection(
                    fd: client,
                    authToken: authToken,
                    actions: actions,
                    bus: bus,
                    queue: queue,
                    state: state
                )
            }
        }
    }

    private static func handleConnection(
        fd: Int32,
        authToken: String,
        actions: [String: Action],
        bus: StateBus,
        queue: AutoPushEventQueue,
        state: State
    ) async {
        defer { close(fd) }
        guard let req = HTTPRequest.parse(from: fd) else {
            writeResponse(fd: fd, status: 400, body: "bad request")
            return
        }

        // For routing, compare against the path without query string.
        // ``req.path`` keeps the full path (including ``?token=...``)
        // for the auth check; ``routePath`` is the trimmed version.
        let routePath = String(req.path.split(separator: "?", maxSplits: 1).first ?? "")

        // ``GET /`` (the dashboard page itself) always serves the HTML
        // unauthenticated — the page reads the token from a query
        // string or localStorage and includes it on subsequent API
        // calls. This lets the user open ``http://host:port/?token=...``
        // once and not get prompted again.
        if req.method == "GET" && routePath == "/" {
            writeResponse(
                fd: fd,
                status: 200,
                contentType: "text/html; charset=utf-8",
                body: WebDashboard.html
            )
            return
        }

        // Everything else requires auth.
        if !req.authorized(token: authToken) {
            writeResponse(fd: fd, status: 401, body: "unauthorized")
            return
        }

        switch (req.method, routePath) {
        case ("GET", "/api/status"):
            let status = await bus.snapshot()
            let queueDepth = await queue.size()
            let payload = await statusJSON(
                status: status, queueDepth: queueDepth, state: state
            )
            writeResponse(
                fd: fd, status: 200,
                contentType: "application/json", body: payload
            )

        case ("POST", let path) where path.hasPrefix("/api/"):
            let name = String(path.dropFirst("/api/".count))
            guard let action = actions[name] else {
                writeResponse(fd: fd, status: 404, body: "no such action: \(name)")
                return
            }
            await action()
            writeResponse(
                fd: fd, status: 200,
                contentType: "application/json", body: #"{"ok":true}"#
            )

        default:
            writeResponse(fd: fd, status: 404, body: "not found")
        }
    }

    /// Build the JSON status payload. Mirrors the ``rmsync status``
    /// CLI output but adds tracked-doc + conflict listings so the
    /// dashboard can render them inline.
    private static func statusJSON(
        status: IPC.Status, queueDepth: Int, state: State
    ) async -> String {
        let docs = (try? await state.allDocuments()) ?? []
        let conflicts = docs.filter { $0.conflictState == "unresolved" }

        var obj: [String: Any] = [
            "state": status.state,
            "sync_dir": status.syncDir,
            "remote_folder": status.remoteFolder,
            "tracked_docs": status.trackedDocs,
            "conflicts": status.conflicts,
            "errors": status.errors,
            "queue_depth": queueDepth,
            "paused": status.paused,
            "version": status.version,
            "pid": status.pid,
            "updated_at": status.updatedAt,
            "auto_push_enabled": status.autoPushEnabled,
            "auto_push_queued": status.autoPushQueued,
            "auto_push_uploading": status.autoPushUploading,
            "auto_push_succeeded": status.autoPushSucceeded,
            "auto_push_skipped": status.autoPushSkipped,
            "auto_push_refused": status.autoPushRefused,
            "auto_push_failed": status.autoPushFailed,
            "pull_state": status.pullState,
            "pull_changes": status.pullChanges,
        ]
        if let lp = status.lastPullAt { obj["last_pull_at"] = lp }
        if let lp = status.lastPushAt { obj["last_push_at"] = lp }
        if let ap = status.autoPushLastSucceededAt { obj["auto_push_last_succeeded_at"] = ap }
        if let pc = status.pullCheckedAt { obj["pull_checked_at"] = pc }
        if let pe = status.pullError { obj["pull_error"] = pe }

        // Top 10 most-recently-pushed docs for the dashboard table.
        let recent = docs
            .sorted { ($0.lastPushAt ?? "") > ($1.lastPushAt ?? "") }
            .prefix(10)
            .map { d -> [String: Any] in
                [
                    "doc_id": d.docID,
                    "local_path": d.localPath,
                    "remote_path": d.remotePath,
                    "last_pull_at": d.lastPullAt as Any,
                    "last_push_at": d.lastPushAt as Any,
                    "conflict": d.conflictState ?? NSNull(),
                    "error": d.errorState ?? NSNull(),
                ]
            }
        obj["recent_docs"] = Array(recent)
        obj["conflict_docs"] = conflicts.map { ["doc_id": $0.docID, "local_path": $0.localPath] }

        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return #"{"error":"json encode failed"}"#
    }

    private static func writeResponse(
        fd: Int32,
        status: Int,
        contentType: String = "text/plain; charset=utf-8",
        body: String
    ) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 500: reason = "Internal Server Error"
        default:  reason = "Status"
        }
        let bytes = Array(body.utf8)
        let head =
            "HTTP/1.1 \(status) \(reason)\r\n" +
            "Content-Type: \(contentType)\r\n" +
            "Content-Length: \(bytes.count)\r\n" +
            "Connection: close\r\n" +
            "Cache-Control: no-store\r\n" +
            "\r\n"
        let headBytes = Array(head.utf8)
        _ = headBytes.withUnsafeBufferPointer { bp in
            write(fd, bp.baseAddress, bp.count)
        }
        _ = bytes.withUnsafeBufferPointer { bp in
            write(fd, bp.baseAddress, bp.count)
        }
    }
}

// MARK: - error type

enum HTTPServerError: Error, CustomStringConvertible {
    case socketCreateFailed(errno: Int32)
    case invalidBindAddr(String)
    case bindFailed(addr: String, port: Int, errno: Int32)
    case listenFailed(errno: Int32)

    var description: String {
        switch self {
        case .socketCreateFailed(let e): return "socket() failed: errno=\(e)"
        case .invalidBindAddr(let a):    return "invalid bind addr: \(a) (use 127.0.0.1 or 0.0.0.0)"
        case .bindFailed(let a, let p, let e):
            return "bind \(a):\(p) failed: errno=\(e)" + (e == EADDRINUSE ? " (port in use)" : "")
        case .listenFailed(let e):       return "listen() failed: errno=\(e)"
        }
    }
}

// MARK: - tiny HTTP request parser

/// Minimal HTTP/1.1 request parser. Reads the head (until
/// \r\n\r\n), parses request line + headers; ignores body for now
/// (none of our endpoints need a request body).
struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]

    /// Parses an HTTP request head from ``fd``. Renamed from ``read``
    /// so the libc ``read(2)`` call inside doesn't resolve to *this*
    /// method recursively — same shadowing pattern that bit
    /// ``IPCClientSync.openSocket`` after the cross-platform refactor.
    static func parse(from fd: Int32) -> HTTPRequest? {
        // Read up to 8 KiB of head — generous for Bearer tokens
        // and a handful of headers, well below the kernel's per-fd
        // default. If we don't see \r\n\r\n in that window, the
        // request is malformed and we drop the connection.
        var buf = [UInt8](repeating: 0, count: 8192)
        var total = 0
        while total < buf.count {
            let n = buf.withUnsafeMutableBufferPointer { bp -> Int in
                read(fd, bp.baseAddress!.advanced(by: total), bp.count - total)
            }
            if n <= 0 { break }
            total += n
            if let _ = findHeadEnd(buf: buf, length: total) { break }
        }
        guard total > 0 else { return nil }
        guard let headEnd = findHeadEnd(buf: buf, length: total) else { return nil }

        let head = String(decoding: buf[0..<headEnd], as: UTF8.self)
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first else { return nil }

        let parts = first.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return nil }
        let method = parts[0]
        let rawPath = parts[1]

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            if let colon = line.firstIndex(of: ":") {
                let k = line[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
                let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
        }

        return HTTPRequest(method: method, path: rawPath, headers: headers)
    }

    /// Authenticated when:
    ///  - ``Authorization: Bearer <token>`` matches, OR
    ///  - the path contains ``?token=<token>`` query arg (so the
    ///    HTML page can fetch with a fetch() call from a stored
    ///    URL, without having to pre-set the header — simpler UX
    ///    for personal-use token sharing).
    func authorized(token expected: String) -> Bool {
        if let h = headers["authorization"], h == "Bearer \(expected)" {
            return true
        }
        if let q = path.split(separator: "?", maxSplits: 1).dropFirst().first {
            for pair in q.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2, kv[0] == "token", kv[1] == expected {
                    return true
                }
            }
        }
        return false
    }

    private static func findHeadEnd(buf: [UInt8], length: Int) -> Int? {
        let needle: [UInt8] = [0x0d, 0x0a, 0x0d, 0x0a]
        guard length >= needle.count else { return nil }
        for i in 0...(length - needle.count) {
            if buf[i] == 0x0d, buf[i+1] == 0x0a, buf[i+2] == 0x0d, buf[i+3] == 0x0a {
                return i + needle.count
            }
        }
        return nil
    }
}

// MARK: - tiny helpers

#if canImport(Darwin)
@inline(__always) private func htons(_ value: UInt16) -> UInt16 {
    return value.bigEndian
}
#endif

#if os(Linux)
// Glibc has htons as a macro that the Swift importer doesn't pick
// up. Implement it directly — same one-liner as the Darwin version.
@inline(__always) private func htons(_ value: UInt16) -> UInt16 {
    return value.bigEndian
}
#endif
