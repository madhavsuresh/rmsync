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

    @Test("omitted remote_folder keeps legacy Writing namespace")
    func omittedRemoteFolderKeepsLegacyWritingNamespace() throws {
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
        #expect(cfg.remoteFolder == "Writing")
    }
}
