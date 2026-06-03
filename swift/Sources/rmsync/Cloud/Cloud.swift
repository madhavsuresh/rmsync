import Foundation

protocol CloudClient: Sendable {
    func tree(_ root: String) async throws -> [Node]
    func get(_ remotePath: String, dest: URL) async throws -> URL
}

protocol CloudWriteClient: CloudClient {
    func stat(_ remotePath: String) async throws -> StatResult?
    func put(local: URL, remoteParent: String, update: Bool) async throws
    func mkdir(_ remotePath: String) async throws
    func mv(from src: String, to dst: String) async throws
    func rm(_ remotePath: String) async throws
}

/// reMarkable cloud access via the ``rmapi`` Go binary.
///
/// Ports ``src/rm_sync/cloud.py`` verbatim. The Python implementation
/// accumulated several hard-won corrections to the original spec — all of
/// them preserved here:
///
/// - ``find`` / ``ls`` have no ``--json`` flag; we parse plain ``[d]``/``[f]``
///   text output.
/// - ``stat`` is the only command that emits JSON, and only from rmapi's
///   interactive shell (not as a positional subcommand).
/// - ``put --force`` replaces a doc in place while keeping its UUID.
///   ``--content-only`` is PDF-only; don't use it for .rmdoc updates.
/// - Under sync15 the ``Version`` field is pinned to 0; use
///   ``ModifiedClient`` as the change signal.
actor Cloud: CloudWriteClient {
    /// rmapi versions we've validated against.
    ///
    /// Bumped from 0.0.29 → 0.0.32 in v0.2.23 after a cloud-side
    /// schema rollout (see ddvk/rmapi#58 filed 2026-04-29) broke
    /// every ``put`` against rmapi <0.0.32 with HTTP 400. v0.0.32
    /// adds "schema v4 with content-based hashing" and
    /// ``detect root.docSchema from server`` — both required by
    /// the new cloud API.
    ///
    /// The ``checkVersion`` warning is the only user-facing
    /// signal until the user upgrades rmapi; we surface it loud
    /// at startup and via ``rmsync doctor``.
    static let rmapiMin = (0, 0, 32)
    static let rmapiMaxExclusive = (0, 1, 0)

    private let rmapiPath: String
    private let concurrentOverride: Int?

    init(rmapiPath: String = "rmapi", concurrentOverride: Int? = nil) {
        self.rmapiPath = rmapiPath
        self.concurrentOverride = concurrentOverride
    }

    // MARK: - meta

    func version() async throws -> (Int, Int, Int) {
        let out = try await run(args: ["version"])
        guard let match = out.firstMatch(of: /(\d+)\.(\d+)\.(\d+)/),
              let major = Int(match.1),
              let minor = Int(match.2),
              let patch = Int(match.3)
        else {
            throw RmapiError.invalidOutput("version", out)
        }
        return (major, minor, patch)
    }

    func checkVersion() async throws {
        let v = try await version()
        let tuple = (v.0, v.1, v.2)
        if !(Self.tupleLE(Self.rmapiMin, tuple)
             && Self.tupleLT(tuple, Self.rmapiMaxExclusive)) {
            // Bumped from "warn" to a clearer "outdated" event
            // in v0.2.23: a cloud-side schema rollout means
            // rmapi < 0.0.32 will 400 on every put. Users who
            // see this in logs should know exactly what to do.
            Logger.shared.warn(
                "rmapi version outdated — uploads WILL fail with HTTP 400",
                meta: [
                    "found": "\(v.0).\(v.1).\(v.2)",
                    "minimum_required": "\(Self.rmapiMin.0).\(Self.rmapiMin.1).\(Self.rmapiMin.2)",
                    "fix_brew": "brew install madhavsuresh/rmsync/rmapi  (uninstall io41/tap/rmapi first if installed)",
                    "fix_manual": "https://github.com/ddvk/rmapi/releases",
                ]
            )
        }
    }

    /// Calls ``rmapi account`` and returns the cloud account email.
    /// Auth check: succeeds iff rmapi has a valid stored token. Used by
    /// ``rmsync doctor`` instead of ``find("/")`` because ``account``
    /// runs as a normal subcommand (proper exit code, no interactive
    /// shell), so it can't false-positive on the throttle-detection
    /// regex applied to listing output.
    func account() async throws -> String {
        let out = try await run(args: ["account"])
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - listing

    func ls(_ remotePath: String) async throws -> [(kind: String, name: String)] {
        let out = try await shell("ls \(try Self.escapeShellPath(remotePath))\n")
        return Self.parseListing(out)
    }

    func find(_ remotePath: String) async throws -> [String] {
        let out = try await shell("find \(try Self.escapeShellPath(remotePath))\n")
        var entries: [String] = []
        for raw in out.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("[d]") || line.hasPrefix("[f]") {
                entries.append(line.trimmingCharacters(in: .whitespaces))
            }
        }
        return entries
    }

    /// rmapi's ``stat`` returns a fixed-shape JSON object. We decode it
    /// into a Sendable struct rather than raw ``[String: Any]`` so
    /// callers can hand results across actor boundaries.
    func stat(_ remotePath: String) async throws -> StatResult? {
        let out = try await shell("stat \(try Self.escapeShellPath(remotePath))\n")
        guard let braceStart = out.firstIndex(of: "{"),
              let braceEnd = out.lastIndex(of: "}")
        else { return nil }
        let jsonText = String(out[braceStart...braceEnd])
        guard let data = jsonText.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(StatResult.self, from: data)
        else { return nil }
        return decoded
    }

    /// Walk the subtree at ``root`` and return a Node per entry (excluding
    /// the root itself).
    ///
    /// ``find`` prints paths prefixed with the root's LAST segment, not
    /// the full absolute path. We prepend the parent of ``root`` to
    /// reconstruct absolute remote paths.
    func tree(_ root: String) async throws -> [Node] {
        let entries = try await find(root)
        let rootSegs = root.split(separator: "/").map(String.init)
        let parentSegs = rootSegs.isEmpty ? [] : Array(rootSegs.dropLast())
        let rootLastAsSingleton = rootSegs.isEmpty ? [String]() : [rootSegs[rootSegs.count - 1]]

        var nodes: [Node] = []
        for line in entries {
            let kind: String = line.hasPrefix("[d]") ? "d" : "f"
            let printed = line.dropFirst(3)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let relSegs = printed.split(separator: "/").map(String.init)
            if relSegs.isEmpty { continue }
            // Root itself appears as a single segment equal to the last
            // segment of ``root``. Skip it.
            if relSegs == rootLastAsSingleton { continue }

            let pathSegs = parentSegs + relSegs
            let remote = "/" + pathSegs.joined(separator: "/")
            let meta: StatResult?
            do {
                meta = try await stat(remote)
            } catch {
                Logger.shared.warn(
                    "stat failed for tree entry",
                    meta: ["path": remote, "error": "\(error)"]
                )
                continue
            }
            guard let meta else {
                Logger.shared.warn("stat failed for tree entry", meta: ["path": remote])
                continue
            }
            let docType: Node.DocType = {
                if kind == "d" { return .collection }
                if meta.type == "CollectionType" { return .collection }
                return .document
            }()
            nodes.append(Node(
                id: meta.id,
                name: meta.name.isEmpty ? (relSegs.last ?? "") : meta.name,
                type: docType,
                parent: meta.parent,
                modifiedClient: meta.modifiedClient,
                version: meta.version,
                currentPage: meta.currentPage,
                path: pathSegs
            ))
        }
        return nodes
    }

    // MARK: - transfer

    /// Download a single document into ``dest`` directory. Returns the path
    /// of the ``.rmdoc`` rmapi produced. Matches the Python implementation
    /// exactly: rmapi writes ``<name>.rmdoc`` into its cwd, so we cd there.
    func get(_ remotePath: String, dest: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        _ = try await run(args: ["get", remotePath], cwd: dest)
        let archives = try FileManager.default.contentsOfDirectory(
            at: dest, includingPropertiesForKeys: [.contentModificationDateKey]
        )
        .filter { $0.pathExtension == "rmdoc" }
        .sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
        guard let newest = archives.first else {
            throw RmapiError.noArchiveProduced(remotePath)
        }
        return newest
    }

    /// Recursive incremental pull. Never uses ``-d`` — that would delete
    /// local work, same caveat as the Python implementation.
    func mget(_ remotePath: String, destDir: URL, incremental: Bool = true) async throws {
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        var args = ["mget"]
        if incremental { args.append("-i") }
        args += ["-o", destDir.path, remotePath]
        _ = try await run(args: args)
    }

    /// Upload ``local`` into ``remoteParent``. With ``update: true`` adds
    /// ``--force`` to replace an existing same-named doc in place while
    /// preserving its UUID — verified invariant from the Python port.
    func put(local: URL, remoteParent: String, update: Bool = false) async throws {
        var args = ["put"]
        if update { args.append("--force") }
        args += [local.path, remoteParent]
        _ = try await run(args: args)
    }

    func mkdir(_ remotePath: String) async throws {
        _ = try await run(args: ["mkdir", remotePath])
    }

    func mv(from src: String, to dst: String) async throws {
        _ = try await run(args: ["mv", src, dst])
    }

    /// Moves to cloud trash, not a hard delete.
    func rm(_ remotePath: String) async throws {
        _ = try await run(args: ["rm", remotePath])
    }

    // MARK: - internals

    private func run(args: [String], cwd: URL? = nil) async throws -> String {
        let result = try await Subprocess.run(
            executablePath: rmapiPath,
            args: args,
            cwd: cwd,
            env: extraEnv()
        )
        if result.exitCode != 0 {
            let haystack = result.stdout + "\n" + result.stderr
            if Self.isThrottled(haystack) {
                throw RmapiError.throttled(result.exitCode, result.stderr)
            }
            throw RmapiError.nonzeroExit(
                command: ([rmapiPath] + args).joined(separator: " "),
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
        return result.stdout
    }

    /// Drive rmapi's interactive shell via stdin for commands that only
    /// exist there (find/ls/stat).
    private func shell(_ commands: String) async throws -> String {
        let result = try await Subprocess.run(
            executablePath: rmapiPath,
            args: [],
            cwd: nil,
            env: extraEnv(),
            stdin: commands.data(using: .utf8) ?? Data()
        )
        // Shell mode returns 0 even when a command inside it fails — the
        // caller parses output. Throttle signals still need catching.
        let haystack = result.stdout + "\n" + result.stderr
        if Self.isThrottled(haystack) {
            throw RmapiError.throttled(result.exitCode, result.stderr)
        }
        return result.stdout
    }

    private func extraEnv() -> [String: String] {
        guard let n = concurrentOverride else { return [:] }
        return ["RMAPI_CONCURRENT": String(n)]
    }

    // MARK: - static helpers

    /// The interactive rmapi shell takes raw command text over stdin.
    /// Reject shell-significant characters we can't safely round-trip
    /// rather than letting a crafted remote name steer parsing.
    static func escapeShellPath(_ path: String) throws -> String {
        let unsafeScalars = CharacterSet(charactersIn: "\"\\`$").union(.controlCharacters)
        if path.rangeOfCharacter(from: unsafeScalars) != nil {
            throw RmapiError.invalidShellPath(path)
        }
        return "\"\(path)\""
    }

    static func parseListing(_ shellOutput: String) -> [(kind: String, name: String)] {
        // ``Regex`` literals aren't ``Sendable``; constructing on each
        // call is fine because ls output is small and we only call this
        // once per folder listing.
        let lsLineRegex = /^\[([df])\]\s*(.+)$/
        var items: [(String, String)] = []
        for raw in shellOutput.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let m = line.firstMatch(of: lsLineRegex) {
                let name = String(m.2).trimmingCharacters(in: .init(charactersIn: "\t "))
                items.append((String(m.1), name))
            }
        }
        return items
    }

    static func isThrottled(_ s: String) -> Bool {
        // Patterns are deliberately conservative: false positives surface
        // as "rmapi throttled" errors that block the user even though
        // nothing's wrong, which is much worse than missing a real
        // throttle (the daemon retries either way, and the next call
        // will catch a sustained throttle from a different signal).
        //
        // Why we don't match bare \b429\b / \b503\b anymore: those word
        // boundaries fire on UUID segments (``…-429-…``) and on doc
        // names containing those numbers, producing false positives in
        // shell-mode output where ``rmapi find /`` lists user content.
        // Reported by an external tester 2026-04-27.
        //
        // Per-call Regex construction keeps the function Sendable-clean.
        let patterns: [Regex<Substring>] = [
            // HTTP status codes only when they appear in HTTP-response
            // context — the literal "HTTP" prefix or "status" label is
            // what makes these patterns specific to error output. The
            // optional ``/<version>`` group accepts ``HTTP 429``,
            // ``HTTP/1.1 429``, and ``HTTP/2 429`` alike. The
            // ``#/.../#`` extended literal is required because the
            // pattern contains a literal ``/``.
            #/(?i)\bHTTP(?:\/\d(?:\.\d)?)?\s+(?:429|503)\b/#,
            /(?i)\bstatus[ :]+(?:429|503)\b/,
            // The literal HTTP reason phrase. Rare in user content.
            /(?i)\btoo many requests\b/,
            // "rate limit" / "rate-limit" / "rate-limited" / "rate
            // limiting", but NOT "rate" or "limit" alone or "rate of
            // X has limits Y" — the previous /(?i)rate.{0,5}limit/
            // matched the latter, breaking on plain English doc text.
            /(?i)\brate[\- ]limit(?:ed|ing)?\b/,
            // The literal word "throttle" / "throttled" / "throttling".
            /(?i)\bthrottl(?:ed|ing)?\b/,
        ]
        for r in patterns {
            if s.contains(r) { return true }
        }
        return false
    }

    static func tupleLE(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Bool {
        if a.0 != b.0 { return a.0 < b.0 }
        if a.1 != b.1 { return a.1 < b.1 }
        return a.2 <= b.2
    }

    static func tupleLT(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Bool {
        if a.0 != b.0 { return a.0 < b.0 }
        if a.1 != b.1 { return a.1 < b.1 }
        return a.2 < b.2
    }
}

/// Decoded shape of ``rmapi stat``'s JSON output. Fields match what the
/// cloud returns for both documents and collections.
struct StatResult: Sendable, Codable {
    var id: String
    var name: String
    var version: Int
    var modifiedClient: String
    var type: String
    var currentPage: Int
    var parent: String

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case name = "Name"
        case version = "Version"
        case modifiedClient = "ModifiedClient"
        case type = "Type"
        case currentPage = "CurrentPage"
        case parent = "Parent"
    }
}

/// One reMarkable tree entry. ``modifiedClient`` is the authoritative
/// change signal under sync15; ``version`` is kept for completeness but is
/// always 0 on accounts we've tested.
struct Node: Sendable, Hashable {
    enum DocType: String, Sendable, Codable { case collection = "CollectionType", document = "DocumentType" }

    var id: String
    var name: String
    var type: DocType
    var parent: String
    var modifiedClient: String
    var version: Int = 0
    var currentPage: Int = 0
    /// Absolute remote path as a list of segments (root excluded).
    var path: [String] = []

    var remotePath: String { "/" + path.joined(separator: "/") }
}

enum RmapiError: Error, CustomStringConvertible, Sendable {
    case invalidOutput(String, String)
    case invalidShellPath(String)
    case nonzeroExit(command: String, exitCode: Int32, stderr: String)
    case throttled(Int32, String)
    case noArchiveProduced(String)

    var description: String {
        switch self {
        case .invalidOutput(let cmd, let out):
            return "rmapi \(cmd) produced unparseable output: \(out.prefix(200))"
        case .invalidShellPath(let path):
            return "rmapi shell path contains unsupported characters: \(path)"
        case .nonzeroExit(let cmd, let rc, let err):
            return "\(cmd) exited \(rc): \(err.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .throttled(let rc, let err):
            return "rmapi throttled (rc=\(rc)): \(err.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .noArchiveProduced(let path):
            return "rmapi get \(path) produced no .rmdoc"
        }
    }

    var isThrottle: Bool {
        if case .throttled = self { return true }
        return false
    }
}
