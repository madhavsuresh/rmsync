import Foundation

/// Minimal async wrapper around Foundation's ``Process`` + ``Pipe``.
///
/// Runs a subprocess to completion, capturing stdout and stderr as strings.
/// Optionally feeds a stdin payload. Matches the subset of
/// ``asyncio.create_subprocess_exec`` our Python code used — full stream,
/// not line-by-line.
enum Subprocess {
    struct Result: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Run the given executable with the args. ``env`` values are merged
    /// on top of the process's current environment; pass an empty dict
    /// to inherit as-is.
    static func run(
        executablePath: String,
        args: [String],
        cwd: URL? = nil,
        env: [String: String] = [:],
        stdin: Data? = nil
    ) async throws -> Result {
        // If the caller passed a bare name like "rmapi", resolve via PATH
        // so /bin/launchctl-style absolute paths and `rmapi` both work.
        let execURL: URL
        if executablePath.hasPrefix("/") {
            execURL = URL(fileURLWithPath: executablePath)
        } else if let resolved = Self.resolveInPath(executablePath, env: env) {
            execURL = resolved
        } else {
            execURL = URL(fileURLWithPath: executablePath)
        }

        return try await withCheckedThrowingContinuation { cont in
            let task = Process()
            task.executableURL = execURL
            task.arguments = args
            if let cwd { task.currentDirectoryURL = cwd }

            if !env.isEmpty {
                var merged = ProcessInfo.processInfo.environment
                for (k, v) in env { merged[k] = v }
                task.environment = merged
            }

            let outPipe = Pipe()
            let errPipe = Pipe()
            task.standardOutput = outPipe
            task.standardError = errPipe

            let inPipe: Pipe?
            if let stdin {
                let p = Pipe()
                task.standardInput = p
                inPipe = p
                _ = stdin  // captured below
            } else {
                inPipe = nil
            }

            // Drain stdout/stderr off separate queues so neither pipe
            // blocks the other.
            let outQueue = DispatchQueue(label: "subprocess.stdout")
            let errQueue = DispatchQueue(label: "subprocess.stderr")
            let collected = Collected()

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    outQueue.sync { collected.appendStdout(chunk) }
                }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    errQueue.sync { collected.appendStderr(chunk) }
                }
            }

            task.terminationHandler = { finished in
                // Drain anything still sitting in the pipes.
                let tailOut = outPipe.fileHandleForReading.readDataToEndOfFile()
                let tailErr = errPipe.fileHandleForReading.readDataToEndOfFile()
                if !tailOut.isEmpty { outQueue.sync { collected.appendStdout(tailOut) } }
                if !tailErr.isEmpty { errQueue.sync { collected.appendStderr(tailErr) } }
                outQueue.sync { _ = collected }
                errQueue.sync { _ = collected }
                let result = Result(
                    exitCode: finished.terminationStatus,
                    stdout: collected.stdoutText(),
                    stderr: collected.stderrText()
                )
                cont.resume(returning: result)
            }

            do {
                try task.run()
            } catch {
                cont.resume(throwing: error)
                return
            }

            if let stdin, let inPipe {
                try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
                try? inPipe.fileHandleForWriting.close()
            }
        }
    }

    private static func resolveInPath(_ name: String, env: [String: String]) -> URL? {
        let pathEnv = env["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in pathEnv.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir))
                .appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

/// Mutable collector used by the readability handlers. Keeping it in a
/// reference type lets the @Sendable closures mutate it while we
/// serialize via the accompanying queues.
private final class Collected: @unchecked Sendable {
    private var stdout = Data()
    private var stderr = Data()

    func appendStdout(_ d: Data) { stdout.append(d) }
    func appendStderr(_ d: Data) { stderr.append(d) }
    func stdoutText() -> String { String(data: stdout, encoding: .utf8) ?? "" }
    func stderrText() -> String { String(data: stderr, encoding: .utf8) ?? "" }
}
