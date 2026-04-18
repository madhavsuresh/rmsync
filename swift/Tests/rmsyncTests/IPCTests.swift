import Darwin
import Foundation
import Testing
@testable import rmsync

@Suite("IPC server + client")
struct IPCTests {
    /// ``AF_UNIX`` paths are capped at 104 bytes on macOS, and pytest's
    /// tmpdir is longer — same constraint the Python port had. Use /tmp
    /// directly for the socket path.
    private func makeSocketPath() -> URL {
        URL(fileURLWithPath: "/tmp/rmipc-\(UUID().uuidString.prefix(8)).sock")
    }

    @Test("hello frame sent on connect")
    func helloOnConnect() async throws {
        let sock = makeSocketPath()
        defer { try? FileManager.default.removeItem(at: sock) }

        let bus = StateBus()
        await bus.update { s in
            s.state = "idle"
            s.trackedDocs = 3
        }
        let server = IPCServer(socketPath: sock, bus: bus)
        try await server.start()
        defer { Task { await server.stop() } }

        let line = try openAndReadLine(sock: sock)
        let obj = try JSONSerialization.jsonObject(with: line) as! [String: Any]
        #expect(obj["type"] as? String == "hello")
        let status = obj["status"] as! [String: Any]
        #expect(status["state"] as? String == "idle")
        #expect(status["tracked_docs"] as? Int == 3)
    }

    @Test("unknown command returns ok:false")
    func unknownCommand() async throws {
        let sock = makeSocketPath()
        defer { try? FileManager.default.removeItem(at: sock) }

        let bus = StateBus()
        let server = IPCServer(socketPath: sock, bus: bus)
        try await server.start()
        defer { Task { await server.stop() } }

        let fd = try connectSocket(sock)
        defer { Darwin.close(fd) }
        _ = try readLine(fd: fd) // hello

        try writeLine(fd: fd, "{\"id\":\"1\",\"type\":\"nope\"}\n")
        let ack = try JSONSerialization.jsonObject(
            with: try readLine(fd: fd)
        ) as! [String: Any]
        #expect(ack["type"] as? String == "ack")
        #expect(ack["ok"] as? Bool == false)
        #expect((ack["error"] as? String)?.contains("unknown command") == true)
    }

    @Test("bus update fans out to connected clients")
    func broadcastFanout() async throws {
        let sock = makeSocketPath()
        defer { try? FileManager.default.removeItem(at: sock) }

        let bus = StateBus()
        let server = IPCServer(socketPath: sock, bus: bus)
        try await server.start()
        defer { Task { await server.stop() } }

        let fd = try connectSocket(sock)
        defer { Darwin.close(fd) }
        _ = try readLine(fd: fd) // hello

        await bus.update { s in
            s.state = "syncing"
            s.queueDepth = 5
        }
        let bcast = try JSONSerialization.jsonObject(
            with: try readLine(fd: fd)
        ) as! [String: Any]
        #expect(bcast["type"] as? String == "status")
        #expect(bcast["state"] as? String == "syncing")
        #expect(bcast["queue_depth"] as? Int == 5)
    }

    @Test("registered command fires handler and returns ok")
    func commandDispatch() async throws {
        let sock = makeSocketPath()
        defer { try? FileManager.default.removeItem(at: sock) }

        let bus = StateBus()
        let server = IPCServer(socketPath: sock, bus: bus)
        await server.register("ping") { _ in
            return SendableJSON.dict(["pong": .bool(true)])
        }
        try await server.start()
        defer { Task { await server.stop() } }

        let fd = try connectSocket(sock)
        defer { Darwin.close(fd) }
        _ = try readLine(fd: fd) // hello

        try writeLine(fd: fd, "{\"id\":\"42\",\"type\":\"ping\"}\n")
        let ack = try JSONSerialization.jsonObject(
            with: try readLine(fd: fd)
        ) as! [String: Any]
        #expect(ack["id"] as? String == "42")
        #expect(ack["ok"] as? Bool == true)
        #expect(ack["pong"] as? Bool == true)
    }

    // MARK: - socket helpers

    private func openAndReadLine(sock: URL) throws -> Data {
        let fd = try connectSocket(sock)
        defer { Darwin.close(fd) }
        return try readLine(fd: fd)
    }

    private func connectSocket(_ sock: URL) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(fd >= 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathCStr = sock.path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: pathCStr.count) { dst in
                _ = memcpy(dst, pathCStr.withUnsafeBufferPointer { $0.baseAddress }, pathCStr.count)
            }
        }
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPtr in
                Darwin.connect(fd, addrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(rc == 0)
        return fd
    }

    private func readLine(fd: Int32) throws -> Data {
        var buf = Data()
        var one = [UInt8](repeating: 0, count: 1)
        while true {
            let n = one.withUnsafeMutableBufferPointer {
                Darwin.read(fd, $0.baseAddress, 1)
            }
            if n <= 0 { break }
            if one[0] == 0x0A { break }
            buf.append(one[0])
        }
        return buf
    }

    private func writeLine(fd: Int32, _ s: String) throws {
        var data = Data(s.utf8)
        try data.withUnsafeMutableBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n < 0 { return }
                sent += n
            }
        }
    }
}
