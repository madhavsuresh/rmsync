import Foundation
import Testing
@testable import rmsync

@Suite("Purge")
struct PurgeTests {
    @Test("plan covers library config logs launch agents bin sync dir and optional rmapi auth")
    func planIncludesAllLocalArtifacts() throws {
        let home = URL(fileURLWithPath: "/Users/alice", isDirectory: true)
        let state = home.appendingPathComponent("Library/Application Support/rmsync", isDirectory: true)
        let logs = home.appendingPathComponent("Library/Logs/rmsync", isDirectory: true)
        let config = home.appendingPathComponent(".config/rmsync/config.toml")
        let syncDir = home.appendingPathComponent("Documents/notes", isDirectory: true)

        let plan = try PurgeEngine.plan(
            hints: PurgeEngine.ConfigHints(syncDir: syncDir, remoteFolder: "sync/notes"),
            includeSyncDir: true,
            includeRmapiAuth: true,
            home: home,
            configPath: config,
            stateDir: state,
            logDir: logs
        )

        let paths = Set(plan.localTargets.map(\.url.path))
        #expect(paths.contains("/Users/alice/Library/LaunchAgents/com.user.rmsync.plist"))
        #expect(paths.contains("/Users/alice/Library/LaunchAgents/com.user.rmsync.menubar.plist"))
        #expect(paths.contains("/Users/alice/.local/bin/rmsync"))
        #expect(paths.contains("/Users/alice/.config/rmsync"))
        #expect(paths.contains("/Users/alice/Library/Application Support/rmsync"))
        #expect(paths.contains("/Users/alice/Library/Logs/rmsync"))
        #expect(paths.contains("/Users/alice/Documents/notes"))
        #expect(paths.contains("/Users/alice/.config/rmapi"))
    }

    @Test("relaxed config hints work with legacy keys normal config rejects")
    func relaxedConfigHintsSurviveLegacyKeys() throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let config = root.appendingPathComponent("config.toml")
        try """
        sync_dir = "~/old-rmsync"
        remote_folder = "archive/old-notes"
        poll_interval_seconds = 5

        [deletion]
        enable_propagation = true
        """.write(to: config, atomically: true, encoding: .utf8)

        #expect(throws: Config.ConfigError.self) {
            _ = try Config.load(from: config)
        }

        let hints = PurgeEngine.loadConfigHints(configPath: config)
        #expect(hints.syncDir?.path.hasSuffix("/old-rmsync") == true)
        #expect(hints.remoteFolder == "archive/old-notes")
    }

    @Test("cloud purge deletes children before the configured root")
    func cloudPurgeDeletesRemoteTreeDepthFirst() async throws {
        let cloud = RecordingPurgeCloud(nodes: [
            Node(
                id: "folder-a",
                name: "a",
                type: .collection,
                parent: "notes",
                modifiedClient: "2026-06-03T00:00:00Z",
                path: ["sync", "notes", "a"]
            ),
            Node(
                id: "doc-nested",
                name: "nested",
                type: .document,
                parent: "folder-a",
                modifiedClient: "2026-06-03T00:00:00Z",
                path: ["sync", "notes", "a", "nested"]
            ),
            Node(
                id: "doc-top",
                name: "top",
                type: .document,
                parent: "notes",
                modifiedClient: "2026-06-03T00:00:00Z",
                path: ["sync", "notes", "top"]
            ),
        ])

        let result = try await PurgeEngine.purgeCloud(remoteFolder: "sync/notes", cloud: cloud)
        let deletes = await cloud.deletes()

        #expect(result.remoteRoot == "/sync/notes")
        #expect(result.deleted == 4)
        #expect(deletes.first == "/sync/notes/a/nested")
        #expect(deletes.last == "/sync/notes")
        #expect(Set(deletes) == [
            "/sync/notes/a",
            "/sync/notes/a/nested",
            "/sync/notes/top",
            "/sync/notes",
        ])
    }

    @Test("cloud purge refuses the cloud root")
    func cloudPurgeRefusesRoot() async {
        let cloud = RecordingPurgeCloud(nodes: [])
        await #expect(throws: PurgeEngine.Error.self) {
            _ = try await PurgeEngine.purgeCloud(remoteFolder: "/", cloud: cloud)
        }
    }

    private static func tempDir() throws -> URL {
        let base: URL
        if let override = ProcessInfo.processInfo.environment["RM_SYNC_TMP_DIR"] {
            base = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            base = FileManager.default.temporaryDirectory
        }
        let url = base.appendingPathComponent("rmsync-purge-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor RecordingPurgeCloud: CloudWriteClient {
    private let nodes: [Node]
    private var removed: [String] = []

    init(nodes: [Node]) {
        self.nodes = nodes
    }

    func deletes() -> [String] { removed }

    func tree(_ root: String) async throws -> [Node] {
        nodes.filter { $0.remotePath.hasPrefix(root) }
    }

    func get(_ remotePath: String, dest: URL) async throws -> URL {
        _ = remotePath
        _ = dest
        throw RecordingPurgeCloudError.unsupported
    }

    func stat(_ remotePath: String) async throws -> StatResult? {
        _ = remotePath
        throw RecordingPurgeCloudError.unsupported
    }

    func put(local: URL, remoteParent: String, update: Bool) async throws {
        _ = local
        _ = remoteParent
        _ = update
        throw RecordingPurgeCloudError.unsupported
    }

    func mkdir(_ remotePath: String) async throws {
        _ = remotePath
        throw RecordingPurgeCloudError.unsupported
    }

    func mv(from src: String, to dst: String) async throws {
        _ = src
        _ = dst
        throw RecordingPurgeCloudError.unsupported
    }

    func rm(_ remotePath: String) async throws {
        removed.append(remotePath)
    }
}

private enum RecordingPurgeCloudError: Error {
    case unsupported
}
