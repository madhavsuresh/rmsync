import ArgumentParser
import Foundation
import TOMLDecoder

#if os(Linux)
import Glibc
#else
import Darwin
#endif

struct PurgeCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "purge",
        abstract: "Preview or apply a complete local rmsync cleanup."
    )

    @Flag(name: .long, help: "Actually remove files. Without this flag, only print the purge plan.")
    var apply: Bool = false

    @Flag(name: .long, help: "Also move the configured remote cloud folder and its contents to cloud trash.")
    var cloud: Bool = false

    @Option(name: .long, help: "Remote folder to purge when config is missing, or to override config.")
    var remoteFolder: String?

    @Flag(name: .long, help: "Preserve the configured sync_dir local Markdown tree.")
    var keepSyncDir: Bool = false

    @Flag(name: .customLong("rmapi-auth"), help: "Also remove rmapi credentials/config at ~/.config/rmapi.")
    var rmapiAuth: Bool = false

    func run() async throws {
        let hints = PurgeEngine.loadConfigHints()
        let remoteFolder = remoteFolder ?? hints.remoteFolder
        let plan = try PurgeEngine.plan(
            hints: hints,
            includeSyncDir: !keepSyncDir,
            includeRmapiAuth: rmapiAuth
        )

        print("local purge targets:")
        for target in plan.localTargets {
            print("  \(target.kind.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) \(target.url.path)")
        }
        if plan.localTargets.isEmpty {
            print("  (none)")
        }

        if cloud {
            guard let remoteFolder else {
                print("")
                print("cloud purge requested, but no remote_folder could be read from config.")
                print("rerun with: rmsync purge --cloud --remote-folder <folder> --apply")
                throw ExitCode(1)
            }
            print("cloud purge target:")
            print("  \(PathUtilities.remoteFolderPath(remoteFolder))")
        } else {
            print("cloud purge target:")
            print("  (none; pass --cloud to include the configured remote folder)")
        }

        guard apply else {
            print("")
            print("preview only; no files removed")
            print("rerun with: rmsync purge --apply")
            if !cloud {
                print("cloud cleanup: rmsync purge --cloud --apply")
            }
            return
        }

        if cloud {
            guard let remoteFolder else { throw PurgeEngine.Error.missingRemoteFolder }
            print("")
            print("deleting cloud folder...")
            let result = try await PurgeEngine.purgeCloud(
                remoteFolder: remoteFolder,
                cloud: Cloud()
            )
            print("cloud deleted: \(result.deleted) item(s) from \(result.remoteRoot)")
        }

        print("")
        print("removing local files...")
        let result = try PurgeEngine.applyLocal(plan)
        print("local removed: \(result.removed)")
        print("local missing: \(result.missing)")
        if result.failed > 0 {
            print("local failed:  \(result.failed)")
            throw ExitCode(1)
        }
        print("purge complete")
    }
}

enum PurgeEngine {
    enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case missingRemoteFolder
        case refusingCloudRoot
        case refusingProtectedPath(String)

        var description: String {
            switch self {
            case .missingRemoteFolder:
                return "cloud purge requested, but no remote_folder was available"
            case .refusingCloudRoot:
                return "refusing to purge the cloud root; pass a non-root remote folder"
            case .refusingProtectedPath(let path):
                return "refusing to remove protected path: \(path)"
            }
        }
    }

    struct ConfigHints: Equatable {
        var syncDir: URL?
        var remoteFolder: String?
    }

    enum LocalKind: String {
        case file
        case directory
    }

    struct LocalTarget: Equatable {
        var kind: LocalKind
        var url: URL
    }

    struct Plan: Equatable {
        var localTargets: [LocalTarget]
    }

    struct LocalResult: Equatable {
        var removed = 0
        var missing = 0
        var failed = 0
    }

    struct CloudResult: Equatable {
        var remoteRoot: String
        var deleted: Int
    }

    private struct MinimalConfig: Decodable {
        var syncDir: String?
        var remoteFolder: String?

        enum CodingKeys: String, CodingKey {
            case syncDir = "sync_dir"
            case remoteFolder = "remote_folder"
        }
    }

    static func loadConfigHints(configPath: URL = Paths.configPath) -> ConfigHints {
        guard let data = try? Data(contentsOf: configPath),
              let text = String(data: data, encoding: .utf8)
        else {
            return ConfigHints(syncDir: nil, remoteFolder: nil)
        }

        if let decoded = try? TOMLDecoder().decode(MinimalConfig.self, from: text) {
            return ConfigHints(
                syncDir: decoded.syncDir.map(expandedPathURL(_:)),
                remoteFolder: decoded.remoteFolder.map(PathUtilities.normalizedRemoteFolder)
            )
        }

        let parsed = parseConfigHintsFallback(text)
        return ConfigHints(
            syncDir: parsed.syncDir.map(expandedPathURL(_:)),
            remoteFolder: parsed.remoteFolder.map(PathUtilities.normalizedRemoteFolder)
        )
    }

    static func plan(
        hints: ConfigHints,
        includeSyncDir: Bool,
        includeRmapiAuth: Bool,
        home: URL = Paths.home,
        configPath: URL = Paths.configPath,
        stateDir: URL = Paths.stateDir,
        logDir: URL = Paths.logDir
    ) throws -> Plan {
        var targets: [LocalTarget] = [
            LocalTarget(kind: .file, url: launchAgentPath(home: home, label: Launchd.label)),
            LocalTarget(kind: .file, url: launchAgentPath(home: home, label: Launchd.menubarLabel)),
            LocalTarget(kind: .file, url: home.appendingPathComponent(".local/bin/rmsync")),
            LocalTarget(kind: .directory, url: configPath.deletingLastPathComponent()),
            LocalTarget(kind: .directory, url: stateDir),
            LocalTarget(kind: .directory, url: logDir),
        ]

        if includeSyncDir, let syncDir = hints.syncDir {
            targets.append(LocalTarget(kind: .directory, url: syncDir))
        }

        if includeRmapiAuth {
            targets.append(LocalTarget(kind: .directory, url: home.appendingPathComponent(".config/rmapi")))
        }

        var seen: Set<String> = []
        let deduped = try targets.compactMap { target -> LocalTarget? in
            let safeURL = target.url.standardizedFileURL
            try rejectProtectedPath(safeURL, home: home)
            guard seen.insert(safeURL.path).inserted else { return nil }
            return LocalTarget(kind: target.kind, url: safeURL)
        }
        return Plan(localTargets: deduped)
    }

    static func applyLocal(_ plan: Plan) throws -> LocalResult {
        #if os(macOS)
        _ = Launchd.stop(label: Launchd.label)
        _ = Launchd.stop(label: Launchd.menubarLabel)
        #endif

        let fm = FileManager.default
        var result = LocalResult()
        for target in plan.localTargets {
            if !pathExistsOrIsSymlink(target.url) {
                result.missing += 1
                continue
            }
            do {
                try fm.removeItem(at: target.url)
                result.removed += 1
            } catch {
                FileHandle.standardError.write(Data("failed to remove \(target.url.path): \(error)\n".utf8))
                result.failed += 1
            }
        }
        return result
    }

    static func purgeCloud(
        remoteFolder: String,
        cloud: any CloudWriteClient
    ) async throws -> CloudResult {
        let normalized = PathUtilities.normalizedRemoteFolder(remoteFolder)
        guard !normalized.isEmpty else { throw Error.refusingCloudRoot }

        let root = PathUtilities.remoteFolderPath(normalized)
        let nodes = try await cloud.tree(root)
        let paths = cloudDeleteOrder(remoteRoot: root, nodes: nodes)

        var deleted = 0
        for path in paths {
            try await cloud.rm(path)
            deleted += 1
        }
        return CloudResult(remoteRoot: root, deleted: deleted)
    }

    static func cloudDeleteOrder(remoteRoot: String, nodes: [Node]) -> [String] {
        var paths = Set(nodes.map(\.remotePath))
        paths.insert(remoteRoot)
        return paths.sorted { lhs, rhs in
            let lhsDepth = lhs.split(separator: "/").count
            let rhsDepth = rhs.split(separator: "/").count
            if lhsDepth != rhsDepth { return lhsDepth > rhsDepth }
            return lhs < rhs
        }
    }

    private static func launchAgentPath(home: URL, label: String) -> URL {
        home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static func rejectProtectedPath(_ url: URL, home: URL) throws {
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        let protected = Set([
            "/",
            homePath,
            home.appendingPathComponent("Library").path,
            home.appendingPathComponent("Library/Application Support").path,
            home.appendingPathComponent("Library/Logs").path,
            home.appendingPathComponent(".config").path,
            home.appendingPathComponent(".local").path,
            "/Users",
            "/Volumes",
            "/tmp",
            "/private/tmp",
        ])
        if protected.contains(path) {
            throw Error.refusingProtectedPath(path)
        }
    }

    private static func expandedPathURL(_ raw: String) -> URL {
        URL(fileURLWithPath: NSString(string: raw).expandingTildeInPath, isDirectory: true)
    }

    private static func parseConfigHintsFallback(_ text: String) -> (syncDir: String?, remoteFolder: String?) {
        var table = ""
        var syncDir: String?
        var remoteFolder: String?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = String(rawLine)
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                table = String(trimmed.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            guard table.isEmpty,
                  let equals = trimmed.firstIndex(of: "=")
            else { continue }

            let key = trimmed[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = trimmed[trimmed.index(after: equals)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = parseStringValue(rawValue) else { continue }

            if key == "sync_dir" { syncDir = value }
            if key == "remote_folder" { remoteFolder = value }
        }

        return (syncDir, remoteFolder)
    }

    private static func parseStringValue(_ raw: String) -> String? {
        guard raw.first == "\"" else { return nil }
        var escaped = false
        var value = ""
        for char in raw.dropFirst() {
            if escaped {
                value.append(char)
                escaped = false
                continue
            }
            if char == "\\" {
                escaped = true
                continue
            }
            if char == "\"" { return value }
            value.append(char)
        }
        return nil
    }

    private static func pathExistsOrIsSymlink(_ url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        var info = stat()
        return lstat(url.path, &info) == 0
    }
}
