// POSIX socket primitives — same shape as IPCTests.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
@testable import rmsync

/// Unit + light integration tests for the web dashboard. The
/// integration tests bind to ``127.0.0.1:0`` so the OS assigns a
/// free port and parallel test runs don't collide. Everything
/// runs locally — no rmapi cloud required.
@Suite("Web dashboard HTTP")
struct HTTPDashboardTests {

    // MARK: - HTTPRequest parser

    @Test("parses a basic GET request")
    func parsesGet() {
        let raw = "GET /api/status?token=abc HTTP/1.1\r\n" +
                  "Host: localhost:7878\r\n" +
                  "User-Agent: curl/8.0\r\n" +
                  "\r\n"
        let req = parseFromBytes(raw)
        #expect(req?.method == "GET")
        #expect(req?.path == "/api/status?token=abc")
        #expect(req?.headers["host"] == "localhost:7878")
        #expect(req?.headers["user-agent"] == "curl/8.0")
    }

    @Test("recognizes Authorization header token")
    func bearerHeaderAuth() {
        let raw = "GET /api/status HTTP/1.1\r\n" +
                  "Authorization: Bearer secret-token\r\n" +
                  "\r\n"
        let req = parseFromBytes(raw)
        #expect(req?.authorized(token: "secret-token") == true)
        #expect(req?.authorized(token: "wrong") == false)
    }

    @Test("recognizes ?token= query param auth")
    func queryStringAuth() {
        let raw = "GET /api/status?token=secret-token HTTP/1.1\r\n\r\n"
        let req = parseFromBytes(raw)
        #expect(req?.authorized(token: "secret-token") == true)
        #expect(req?.authorized(token: "wrong") == false)
    }

    @Test("rejects request with neither header nor query token")
    func noAuth() {
        let raw = "GET /api/status HTTP/1.1\r\n\r\n"
        let req = parseFromBytes(raw)
        #expect(req?.authorized(token: "secret-token") == false)
    }

    @Test("rejects malformed request")
    func malformed() {
        // No \r\n\r\n at all → can't find head end → nil.
        let req = parseFromBytes("GET nonsense")
        #expect(req == nil)
    }

    // MARK: - server bind + serve

    @Test("server binds, serves /, requires auth on /api")
    func endToEndServe() async throws {
        let bus = StateBus()
        let queue = JobQueue()
        let stateDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmsync-web-test-\(UUID().uuidString).db")
        let state = try State(path: stateDB)
        defer { try? FileManager.default.removeItem(at: stateDB) }

        // OS-picks-a-port via 0; we'd need to wrap to expose the
        // assigned port. For simplicity use a high port unlikely
        // to collide. If it does, test fails on bind — easy to
        // diagnose.
        let port = 47800 + Int.random(in: 0..<200)
        let server = HTTPServer(
            bindAddr: "127.0.0.1", port: port, authToken: "token-abc",
            bus: bus, queue: queue, state: state
        )
        try await server.start()
        defer { Task { await server.stop() } }
        // Brief settle for the listener.
        try await Task.sleep(for: .milliseconds(100))

        // GET / always serves HTML, no auth required.
        let homeRsp = try await get(port: port, path: "/")
        #expect(homeRsp.status == 200)
        #expect(homeRsp.body.contains("rmsync"))
        #expect(homeRsp.headers["content-type"]?.contains("text/html") == true)

        // GET /api/status without auth → 401.
        let unauthRsp = try await get(port: port, path: "/api/status")
        #expect(unauthRsp.status == 401)

        // With Authorization: Bearer header → 200 + JSON.
        let okRsp = try await get(
            port: port, path: "/api/status",
            extraHeaders: ["Authorization": "Bearer token-abc"]
        )
        #expect(okRsp.status == 200)
        #expect(okRsp.headers["content-type"]?.contains("application/json") == true)
        // Status JSON should at minimum contain ``state`` and
        // ``tracked_docs`` keys (they always exist on a fresh bus).
        #expect(okRsp.body.contains("\"state\""))
        #expect(okRsp.body.contains("\"tracked_docs\""))

        // ?token= query param also authorizes.
        let okQRsp = try await get(port: port, path: "/api/status?token=token-abc")
        #expect(okQRsp.status == 200)
    }

    // MARK: - helpers

    /// Wrap ``HTTPRequest.parse(from:)`` over an in-memory pipe
    /// instead of a real socket. Lets us unit-test the parser
    /// without binding.
    private func parseFromBytes(_ raw: String) -> HTTPRequest? {
        var fds: [Int32] = [-1, -1]
        let rc = fds.withUnsafeMutableBufferPointer { buf -> Int32 in
            pipe(buf.baseAddress)
        }
        guard rc == 0 else { return nil }
        let readEnd = fds[0]
        var writeEnd = fds[1]
        defer {
            close(readEnd)
            if writeEnd >= 0 { close(writeEnd) }
        }
        let bytes = Array(raw.utf8)
        _ = bytes.withUnsafeBufferPointer { bp in
            write(writeEnd, bp.baseAddress, bp.count)
        }
        // Close the write end so read() returns 0 (EOF) once
        // the bytes are drained, preventing the parser from
        // blocking past the head.
        close(writeEnd)
        writeEnd = -1
        return HTTPRequest.parse(from: readEnd)
    }

    private struct HTTPResponse {
        let status: Int
        let headers: [String: String]
        let body: String
    }

    private func get(
        port: Int, path: String, extraHeaders: [String: String] = [:]
    ) async throws -> HTTPResponse {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<HTTPResponse, Error>) in
            DispatchQueue.global().async {
                do {
                    let rsp = try Self.simpleHTTPGet(
                        host: "127.0.0.1", port: port,
                        path: path, extraHeaders: extraHeaders
                    )
                    cont.resume(returning: rsp)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Synchronous one-shot HTTP/1.1 GET. ~30 lines is enough
    /// to test the dashboard without pulling in a third-party
    /// HTTP client.
    private static func simpleHTTPGet(
        host: String, port: Int, path: String,
        extraHeaders: [String: String]
    ) throws -> HTTPResponse {
        let fd = socket(AF_INET, SOCK_STREAM_I32, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }

        var addr = sockaddr_in()
        #if os(macOS)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        var inAddr = in_addr()
        host.withCString { _ = inet_pton(AF_INET, $0, &inAddr) }
        addr.sin_addr = inAddr

        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPtr in
                connect(fd, addrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { throw POSIXError(.ECONNREFUSED) }

        var head = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n"
        for (k, v) in extraHeaders {
            head += "\(k): \(v)\r\n"
        }
        head += "\r\n"
        let bytes = Array(head.utf8)
        _ = bytes.withUnsafeBufferPointer { bp in
            write(fd, bp.baseAddress, bp.count)
        }

        var buf = [UInt8](repeating: 0, count: 65536)
        var total = 0
        while total < buf.count {
            let n = buf.withUnsafeMutableBufferPointer { bp -> Int in
                read(fd, bp.baseAddress!.advanced(by: total), bp.count - total)
            }
            if n <= 0 { break }
            total += n
        }
        let raw = String(decoding: buf[0..<total], as: UTF8.self)
        guard let headEnd = raw.range(of: "\r\n\r\n") else {
            throw POSIXError(.EPROTO)
        }
        let head2 = String(raw[..<headEnd.lowerBound])
        let body = String(raw[headEnd.upperBound...])
        let lines = head2.split(separator: "\r\n").map(String.init)
        guard let first = lines.first else { throw POSIXError(.EPROTO) }
        let parts = first.split(separator: " ", maxSplits: 2).map(String.init)
        let status = Int(parts.count >= 2 ? parts[1] : "0") ?? 0
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let k = line[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
                let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
        }
        return HTTPResponse(status: status, headers: headers, body: body)
    }
}
