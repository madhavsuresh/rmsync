import Foundation

public struct RMApiMockCommandResult: Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32 = 0, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum RMApiMockFaultKind: String, Codable, Sendable {
    case auth
    case compat400
    case throttle
    case noArchive = "no_archive"
}

public enum RMApiMockTestSupport {
    public static func reset(stateDir: URL) throws {
        try RMApiMockStore(root: stateDir).reset()
    }

    public static func clearFaults(stateDir: URL) throws {
        try RMApiMockStore(root: stateDir).updateFaults { faults in
            faults = FaultConfig()
        }
    }

    public static func setAuthBroken(_ enabled: Bool, stateDir: URL) throws {
        try RMApiMockStore(root: stateDir).updateFaults { faults in
            faults.authBroken = enabled
        }
    }

    public static func setPartialFindLimit(_ limit: Int?, stateDir: URL) throws {
        try RMApiMockStore(root: stateDir).updateFaults { faults in
            faults.partialFindLimit = limit
        }
    }

    public static func addNoArchivePath(_ path: String, stateDir: URL) throws {
        try RMApiMockStore(root: stateDir).updateFaults { faults in
            if !faults.noArchivePaths.contains(path) {
                faults.noArchivePaths.append(path)
            }
        }
    }

    public static func addCommandFault(
        command: String,
        kind: RMApiMockFaultKind,
        once: Bool,
        stateDir: URL
    ) throws {
        try RMApiMockStore(root: stateDir).updateFaults { faults in
            faults.commandFaults.append(CommandFault(
                command: command,
                kind: kind,
                remaining: once ? 1 : nil
            ))
        }
    }
}

public enum RMApiMockCommand {
    public static func run(
        arguments: [String],
        stdin: Data?,
        cwd: URL,
        environment: [String: String]
    ) -> RMApiMockCommandResult {
        do {
            let root = try stateRoot(environment: environment)
            let store = RMApiMockStore(root: root)
            if arguments.isEmpty {
                let text = stdin.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                return try store.runShell(text)
            }
            if arguments.first == "mock" {
                return try store.runControl(Array(arguments.dropFirst()))
            }
            return try store.run(arguments, cwd: cwd)
        } catch let error as MockError {
            return RMApiMockCommandResult(exitCode: error.exitCode, stderr: error.description + "\n")
        } catch {
            return RMApiMockCommandResult(exitCode: 1, stderr: "\(error)\n")
        }
    }

    private static func stateRoot(environment: [String: String]) throws -> URL {
        guard let raw = environment["RMAPI_MOCK_STATE_DIR"], !raw.isEmpty else {
            throw MockError.missingStateDir
        }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }
}

struct RMApiMockStore {
    let root: URL

    private var stateURL: URL { root.appendingPathComponent("state.json") }
    private var blobsDir: URL { root.appendingPathComponent("blobs", isDirectory: true) }

    func reset() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
        try fm.createDirectory(at: blobsDir, withIntermediateDirectories: true)
        try save(MockState())
    }

    func updateFaults(_ body: (inout FaultConfig) -> Void) throws {
        var state = try load()
        body(&state.faults)
        try save(state)
    }

    func run(_ arguments: [String], cwd: URL) throws -> RMApiMockCommandResult {
        var state = try load()
        let command = arguments[0]
        if let fault = state.takeFault(command: command) {
            try save(state)
            return faultResult(fault, command: command)
        }
        if state.faults.authBroken, command != "version" {
            return authResult()
        }

        let result: RMApiMockCommandResult
        switch command {
        case "version":
            result = RMApiMockCommandResult(stdout: "0.0.32\n")
        case "account":
            result = RMApiMockCommandResult(stdout: "mock@example.com\n")
        case "mkdir":
            guard arguments.count == 2 else { throw MockError.usage("mkdir <remote-path>") }
            result = try mkdir(arguments[1], state: &state)
        case "put":
            result = try put(Array(arguments.dropFirst()), cwd: cwd, state: &state)
        case "get":
            guard arguments.count == 2 else { throw MockError.usage("get <remote-path>") }
            result = try get(arguments[1], cwd: cwd, state: &state)
        case "mv":
            guard arguments.count == 3 else { throw MockError.usage("mv <src> <dst>") }
            result = try mv(from: arguments[1], to: arguments[2], state: &state)
        case "rm":
            guard arguments.count == 2 else { throw MockError.usage("rm <remote-path>") }
            result = try rm(arguments[1], state: &state)
        default:
            throw MockError.usage("unsupported command: \(command)")
        }
        try save(state)
        return result
    }

    func runShell(_ text: String) throws -> RMApiMockCommandResult {
        var state = try load()
        var stdout = ""
        var stderr = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let words = try parseShellWords(line)
            guard let command = words.first else { continue }
            if let fault = state.takeFault(command: command) {
                let result = faultResult(fault, command: command, shellMode: true)
                stdout += result.stdout
                stderr += result.stderr
                continue
            }
            switch command {
            case "find":
                guard words.count == 2 else { stderr += "usage: find <path>\n"; continue }
                stdout += try find(words[1], state: state)
            case "ls":
                guard words.count == 2 else { stderr += "usage: ls <path>\n"; continue }
                stdout += try ls(words[1], state: state)
            case "stat":
                guard words.count == 2 else { stderr += "usage: stat <path>\n"; continue }
                stdout += try stat(words[1], state: state)
            default:
                stderr += "unsupported shell command: \(command)\n"
            }
        }
        try save(state)
        return RMApiMockCommandResult(exitCode: 0, stdout: stdout, stderr: stderr)
    }

    func runControl(_ arguments: [String]) throws -> RMApiMockCommandResult {
        guard let command = arguments.first else {
            throw MockError.usage("mock <reset|fault|dump>")
        }
        switch command {
        case "reset":
            try reset()
            return RMApiMockCommandResult(stdout: "reset\n")
        case "dump":
            let data = try JSONEncoder.pretty.encode(load())
            return RMApiMockCommandResult(stdout: String(data: data, encoding: .utf8) ?? "")
        case "fault":
            try controlFault(Array(arguments.dropFirst()))
            return RMApiMockCommandResult(stdout: "ok\n")
        default:
            throw MockError.usage("mock <reset|fault|dump>")
        }
    }

    private func controlFault(_ arguments: [String]) throws {
        guard let command = arguments.first else {
            throw MockError.usage("mock fault <clear|auth|partial-find|no-archive|command>")
        }
        switch command {
        case "clear":
            try updateFaults { $0 = FaultConfig() }
        case "auth":
            guard arguments.count == 2 else { throw MockError.usage("mock fault auth <on|off>") }
            try updateFaults { $0.authBroken = arguments[1] == "on" }
        case "partial-find":
            guard arguments.count == 2 else { throw MockError.usage("mock fault partial-find <N|off>") }
            try updateFaults { faults in
                faults.partialFindLimit = arguments[1] == "off" ? nil : Int(arguments[1])
            }
        case "no-archive":
            guard arguments.count == 2 else { throw MockError.usage("mock fault no-archive <remote-path>") }
            try updateFaults { faults in
                if !faults.noArchivePaths.contains(arguments[1]) {
                    faults.noArchivePaths.append(arguments[1])
                }
            }
        case "command":
            guard arguments.count >= 3 else {
                throw MockError.usage("mock fault command <command> <auth|compat400|throttle|no_archive> [once|always]")
            }
            guard let kind = RMApiMockFaultKind(rawValue: arguments[2]) else {
                throw MockError.usage("unknown fault kind: \(arguments[2])")
            }
            let once = arguments.dropFirst(3).first == "once"
            try updateFaults { faults in
                faults.commandFaults.append(CommandFault(
                    command: arguments[1],
                    kind: kind,
                    remaining: once ? 1 : nil
                ))
            }
        default:
            throw MockError.usage("mock fault <clear|auth|partial-find|no-archive|command>")
        }
    }

    private func mkdir(_ rawPath: String, state: inout MockState) throws -> RMApiMockCommandResult {
        let path = normalize(rawPath)
        if let existing = state.entry(at: path), !existing.trashed {
            if existing.type == .collection {
                return RMApiMockCommandResult(exitCode: 1, stderr: "ERROR: entry already exists\n")
            }
            return RMApiMockCommandResult(exitCode: 1, stderr: "ERROR: file exists at path\n")
        }
        _ = state.ensureCollection(path: path)
        return RMApiMockCommandResult()
    }

    private func put(_ arguments: [String], cwd: URL, state: inout MockState) throws -> RMApiMockCommandResult {
        var args = arguments
        let force: Bool
        if args.first == "--force" {
            force = true
            args.removeFirst()
        } else {
            force = false
        }
        guard args.count == 2 else { throw MockError.usage("put [--force] <local> <remote-parent>") }
        let local = URL(fileURLWithPath: args[0], relativeTo: cwd).standardizedFileURL
        let remoteParent = normalize(args[1])
        let parent = state.ensureCollection(path: remoteParent)
        let parsed = try ArchiveMetadata.read(from: local)
        let destination = remoteParent + [parsed.name]
        if let idx = state.index(at: destination), !state.entries[idx].trashed {
            guard force else {
                return RMApiMockCommandResult(exitCode: 1, stderr: "ERROR: entry already exists\n")
            }
            let blob = try copyBlob(local)
            state.entries[idx].name = parsed.name
            state.entries[idx].parent = parent.id
            state.entries[idx].type = .document
            state.entries[idx].version += 1
            state.entries[idx].modifiedClient = state.nextModified()
            state.entries[idx].currentPage = 0
            state.entries[idx].archiveFile = blob
            state.entries[idx].rawFile = nil
            state.entries[idx].trashed = false
        } else {
            let blob = try copyBlob(local)
            state.entries.append(MockEntry(
                id: parsed.docID,
                name: parsed.name,
                type: .document,
                parent: parent.id,
                modifiedClient: state.nextModified(),
                version: parsed.version,
                currentPage: 0,
                path: destination,
                archiveFile: parsed.isArchive ? blob : nil,
                rawFile: parsed.isArchive ? nil : blob,
                trashed: false
            ))
        }
        return RMApiMockCommandResult()
    }

    private func get(_ rawPath: String, cwd: URL, state: inout MockState) throws -> RMApiMockCommandResult {
        let path = normalize(rawPath)
        let remotePath = remote(path)
        if state.faults.noArchivePaths.contains(remotePath) {
            return RMApiMockCommandResult()
        }
        guard let entry = state.entry(at: path), !entry.trashed, entry.type == .document else {
            return RMApiMockCommandResult(exitCode: 1, stderr: "ERROR: entry not found\n")
        }
        guard let archiveFile = entry.archiveFile else {
            return RMApiMockCommandResult()
        }
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let source = blobsDir.appendingPathComponent(archiveFile)
        let destination = cwd.appendingPathComponent("\(entry.name).rmdoc")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        return RMApiMockCommandResult()
    }

    private func mv(from rawSource: String, to rawDestination: String, state: inout MockState) throws -> RMApiMockCommandResult {
        let source = normalize(rawSource)
        var destination = normalize(rawDestination)
        if let destinationEntry = state.entry(at: destination),
           destinationEntry.type == .collection,
           !destinationEntry.trashed,
           let sourceName = source.last {
            destination.append(sourceName)
        }
        guard let idx = state.index(at: source), !state.entries[idx].trashed else {
            return RMApiMockCommandResult(exitCode: 1, stderr: "ERROR: source not found\n")
        }
        if let existing = state.entry(at: destination), !existing.trashed {
            return RMApiMockCommandResult(exitCode: 1, stderr: "ERROR: destination exists\n")
        }

        let oldPath = state.entries[idx].path
        let parent = state.ensureCollection(path: Array(destination.dropLast()))
        state.entries[idx].path = destination
        state.entries[idx].name = destination.last ?? state.entries[idx].name
        state.entries[idx].parent = parent.id
        state.entries[idx].modifiedClient = state.nextModified()
        if state.entries[idx].type == .collection {
            for i in state.entries.indices where state.entries[i].path.starts(with: oldPath) && i != idx {
                let suffix = state.entries[i].path.dropFirst(oldPath.count)
                state.entries[i].path = destination + Array(suffix)
                state.entries[i].modifiedClient = state.nextModified()
            }
        }
        return RMApiMockCommandResult()
    }

    private func rm(_ rawPath: String, state: inout MockState) throws -> RMApiMockCommandResult {
        let path = normalize(rawPath)
        var removed = 0
        for i in state.entries.indices where state.entries[i].path.starts(with: path) {
            if !state.entries[i].trashed {
                state.entries[i].trashed = true
                state.entries[i].modifiedClient = state.nextModified()
                removed += 1
            }
        }
        if removed == 0 {
            return RMApiMockCommandResult(exitCode: 1, stderr: "ERROR: entry not found\n")
        }
        return RMApiMockCommandResult()
    }

    private func find(_ rawRoot: String, state: MockState) throws -> String {
        let rootPath = normalize(rawRoot)
        var entries = state.visibleEntries().filter { entry in
            entry.path == rootPath || entry.path.starts(with: rootPath)
        }
        if let limit = state.faults.partialFindLimit {
            entries = Array(entries.prefix(max(0, limit)))
        }
        return entries.map { entry in
            let dropCount = rootPath.isEmpty ? 0 : max(0, rootPath.count - 1)
            let printable = entry.path.dropFirst(dropCount).joined(separator: "/")
            return "[\(entry.type.marker)] \(printable)"
        }
        .joined(separator: "\n")
        .appending(entries.isEmpty ? "" : "\n")
    }

    private func ls(_ rawRoot: String, state: MockState) throws -> String {
        let rootPath = normalize(rawRoot)
        let children = state.visibleEntries().filter { entry in
            entry.path.count == rootPath.count + 1
                && Array(entry.path.prefix(rootPath.count)) == rootPath
        }
        return children.map { "[\($0.type.marker)] \($0.name)" }
            .joined(separator: "\n")
            .appending(children.isEmpty ? "" : "\n")
    }

    private func stat(_ rawPath: String, state: MockState) throws -> String {
        let path = normalize(rawPath)
        guard let entry = state.entry(at: path), !entry.trashed else { return "" }
        let data = try JSONEncoder.sorted.encode(StatJSON(
            id: entry.id,
            name: entry.name,
            version: entry.version,
            modifiedClient: entry.modifiedClient,
            type: entry.type.rawValue,
            currentPage: entry.currentPage,
            parent: entry.parent
        ))
        return (String(data: data, encoding: .utf8) ?? "{}") + "\n"
    }

    private func faultResult(
        _ fault: RMApiMockFaultKind,
        command: String,
        shellMode: Bool = false
    ) -> RMApiMockCommandResult {
        switch fault {
        case .auth:
            return authResult(shellMode: shellMode)
        case .compat400:
            let message: String
            switch command {
            case "mkdir":
                message = "ERROR: failed to create directory: request failed with status 400\n"
            case "rm":
                message = "ERROR: failed to delete existing file: request failed with status 400\n"
            default:
                message = "ERROR: failed to upload file: request failed with status 400\n"
            }
            return RMApiMockCommandResult(exitCode: shellMode ? 0 : 1, stderr: message)
        case .throttle:
            return RMApiMockCommandResult(
                exitCode: shellMode ? 0 : 1,
                stderr: "HTTP 429 Too Many Requests: mock throttle\n"
            )
        case .noArchive:
            return RMApiMockCommandResult()
        }
    }

    private func authResult(shellMode: Bool = false) -> RMApiMockCommandResult {
        RMApiMockCommandResult(
            exitCode: shellMode ? 0 : 1,
            stderr: "Error: Refresh token is not set, please run rmapi to authenticate first.\n"
        )
    }

    private func load() throws -> MockState {
        try FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            let state = MockState()
            try save(state)
            return state
        }
        let data = try Data(contentsOf: stateURL)
        return try JSONDecoder().decode(MockState.self, from: data)
    }

    private func save(_ state: MockState) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(state)
        let tmp = stateURL.appendingPathExtension("tmp")
        try data.write(to: tmp)
        if FileManager.default.fileExists(atPath: stateURL.path) {
            _ = try FileManager.default.replaceItemAt(stateURL, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: stateURL)
        }
    }

    private func copyBlob(_ source: URL) throws -> String {
        try FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)
        let name = UUID().uuidString.lowercased() + "-" + source.lastPathComponent
        let destination = blobsDir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: destination)
        return name
    }
}

struct MockState: Codable {
    var entries: [MockEntry] = [
        MockEntry(
            id: "root",
            name: "",
            type: .collection,
            parent: "",
            modifiedClient: "2026-06-03T00:00:00Z",
            version: 0,
            currentPage: 0,
            path: [],
            archiveFile: nil,
            rawFile: nil,
            trashed: false
        )
    ]
    var clock: Int = 1
    var faults = FaultConfig()

    mutating func ensureCollection(path: [String]) -> MockEntry {
        if let idx = index(at: path) {
            entries[idx].trashed = false
            return entries[idx]
        }
        let parentPath = Array(path.dropLast())
        let parent = ensureCollection(path: parentPath)
        let entry = MockEntry(
            id: collectionID(path),
            name: path.last ?? "",
            type: .collection,
            parent: parent.id,
            modifiedClient: nextModified(),
            version: 0,
            currentPage: 0,
            path: path,
            archiveFile: nil,
            rawFile: nil,
            trashed: false
        )
        entries.append(entry)
        return entry
    }

    func entry(at path: [String]) -> MockEntry? {
        entries.first { $0.path == path }
    }

    func index(at path: [String]) -> Int? {
        entries.firstIndex { $0.path == path }
    }

    func visibleEntries() -> [MockEntry] {
        entries
            .filter { !$0.trashed && !$0.path.isEmpty }
            .sorted { lhs, rhs in lhs.path.joined(separator: "/") < rhs.path.joined(separator: "/") }
    }

    mutating func nextModified() -> String {
        let value = String(format: "2026-06-03T00:%02d:%02dZ", (clock / 60) % 60, clock % 60)
        clock += 1
        return value
    }

    mutating func takeFault(command: String) -> RMApiMockFaultKind? {
        guard let idx = faults.commandFaults.firstIndex(where: { $0.command == command }) else {
            return nil
        }
        let fault = faults.commandFaults[idx].kind
        if let remaining = faults.commandFaults[idx].remaining {
            if remaining <= 1 {
                faults.commandFaults.remove(at: idx)
            } else {
                faults.commandFaults[idx].remaining = remaining - 1
            }
        }
        return fault
    }

    private func collectionID(_ path: [String]) -> String {
        if path.isEmpty { return "root" }
        return "col-" + path.joined(separator: "_")
    }
}

struct MockEntry: Codable {
    var id: String
    var name: String
    var type: EntryType
    var parent: String
    var modifiedClient: String
    var version: Int
    var currentPage: Int
    var path: [String]
    var archiveFile: String?
    var rawFile: String?
    var trashed: Bool
}

enum EntryType: String, Codable {
    case collection = "CollectionType"
    case document = "DocumentType"

    var marker: String {
        switch self {
        case .collection: return "d"
        case .document: return "f"
        }
    }
}

struct FaultConfig: Codable {
    var authBroken: Bool = false
    var partialFindLimit: Int?
    var noArchivePaths: [String] = []
    var commandFaults: [CommandFault] = []
}

struct CommandFault: Codable {
    var command: String
    var kind: RMApiMockFaultKind
    var remaining: Int?
}

struct StatJSON: Codable {
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

struct ArchiveMetadata {
    var docID: String
    var name: String
    var version: Int
    var isArchive: Bool

    static func read(from local: URL) throws -> ArchiveMetadata {
        let name = local.deletingPathExtension().lastPathComponent
        guard local.pathExtension == "rmdoc" else {
            return ArchiveMetadata(
                docID: UUID().uuidString.lowercased(),
                name: name,
                version: 1,
                isArchive: false
            )
        }

        let entries = try runProcess(executable: "/usr/bin/zipinfo", args: ["-1", local.path]).stdout
            .split(separator: "\n")
            .map(String.init)
        guard let metadataEntry = entries.first(where: { $0.hasSuffix(".metadata") }) else {
            return ArchiveMetadata(
                docID: UUID().uuidString.lowercased(),
                name: name,
                version: 1,
                isArchive: true
            )
        }
        let docID = String(metadataEntry.dropLast(".metadata".count))
        let metadata = try runProcess(executable: "/usr/bin/unzip", args: ["-p", local.path, metadataEntry]).stdout
        let data = Data(metadata.utf8)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let version = (json?["version"] as? Int) ?? 1
        return ArchiveMetadata(docID: docID, name: name, version: version, isArchive: true)
    }
}

enum MockError: Error, CustomStringConvertible {
    case missingStateDir
    case usage(String)
    case processFailed(String, String)

    var exitCode: Int32 {
        switch self {
        case .missingStateDir, .usage, .processFailed:
            return 1
        }
    }

    var description: String {
        switch self {
        case .missingStateDir:
            return "RMAPI_MOCK_STATE_DIR is required"
        case .usage(let message):
            return "usage: \(message)"
        case .processFailed(let command, let stderr):
            return "\(command) failed: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

private func normalize(_ raw: String) -> [String] {
    raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
}

private func remote(_ path: [String]) -> String {
    "/" + path.joined(separator: "/")
}

private func parseShellWords(_ line: String) throws -> [String] {
    var words: [String] = []
    var current = ""
    var inQuote = false
    for ch in line {
        if ch == "\"" {
            inQuote.toggle()
            continue
        }
        if ch == " ", !inQuote {
            if !current.isEmpty {
                words.append(current)
                current = ""
            }
            continue
        }
        current.append(ch)
    }
    if inQuote { throw MockError.usage("unterminated quote in shell command") }
    if !current.isEmpty { words.append(current) }
    return words
}

private func runProcess(executable: String, args: [String]) throws -> (stdout: String, stderr: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = args
    let out = Pipe()
    let err = Pipe()
    task.standardOutput = out
    task.standardError = err
    try task.run()
    task.waitUntilExit()
    let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard task.terminationStatus == 0 else {
        throw MockError.processFailed(([executable] + args).joined(separator: " "), stderr)
    }
    return (stdout, stderr)
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
