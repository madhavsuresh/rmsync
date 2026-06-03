import Foundation
import Testing
@testable import rmsync

@Suite("Config")
struct ConfigTests {
    @Test("direct defaults use sync notes namespace")
    func directDefaultsUseSyncNotesNamespace() {
        let cfg = Config(syncDir: URL(fileURLWithPath: "/tmp/rmsync-notes"))
        #expect(cfg.remoteFolder == "sync/notes")
    }

    @Test("omitted remote_folder uses sync notes namespace")
    func omittedRemoteFolderUsesSyncNotesNamespace() throws {
        let root = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["RMSYNC_TEST_TMP"]
                ?? FileManager.default.temporaryDirectory.path,
            isDirectory: true
        )
        let dir = root.appendingPathComponent("config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("config.toml")
        try """
        sync_dir = "/tmp/rmsync-notes"
        """.write(to: path, atomically: true, encoding: .utf8)

        let cfg = try Config.load(from: path)
        #expect(cfg.remoteFolder == "sync/notes")
    }

    @Test("legacy Writing remote folder is rejected")
    func legacyWritingRemoteFolderRejected() throws {
        let path = try writeConfig("""
        sync_dir = "/tmp/rmsync-notes"
        remote_folder = "Writing"
        """)

        #expect(throws: Config.ConfigError.self) {
            _ = try Config.load(from: path)
        }
    }

    @Test("arbitrary ordinary remote folders are rejected")
    func arbitraryRemoteFolderRejected() throws {
        let path = try writeConfig("""
        sync_dir = "/tmp/rmsync-notes"
        remote_folder = "sync/custom"
        """)

        #expect(throws: Config.ConfigError.self) {
            _ = try Config.load(from: path)
        }
    }

    @Test("legacy worker keys are rejected")
    func legacyWorkerKeysRejected() throws {
        let path = try writeConfig("""
        sync_dir = "/tmp/rmsync-notes"
        remote_folder = "sync/notes"
        worker_pool_size = 3
        """)

        #expect(throws: Config.ConfigError.self) {
            _ = try Config.load(from: path)
        }
    }

    @Test("legacy deletion propagation keys are rejected")
    func legacyDeletionPropagationKeysRejected() throws {
        let path = try writeConfig("""
        sync_dir = "/tmp/rmsync-notes"
        remote_folder = "sync/notes"

        [deletion]
        enable_propagation = true
        """)

        #expect(throws: Config.ConfigError.self) {
            _ = try Config.load(from: path)
        }
    }

    private func writeConfig(_ text: String) throws -> URL {
        let root = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["RMSYNC_TEST_TMP"]
                ?? FileManager.default.temporaryDirectory.path,
            isDirectory: true
        )
        let dir = root.appendingPathComponent("config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("config.toml")
        try text.write(to: path, atomically: true, encoding: .utf8)
        return path
    }
}
