import Foundation
import Testing
@testable import rmsync

@Suite("Explicit staged diff")
struct ExplicitDiffTests {
    @Test("path argument renders only the selected staged file")
    func pathArgumentRendersSelectedDiff() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try write("old foo\n", to: fixture.sync.appendingPathComponent("foo.md"))
        try write("new foo\n", to: fixture.files.appendingPathComponent("foo.md"))
        try write("old bar\n", to: fixture.sync.appendingPathComponent("bar.md"))
        try write("new bar\n", to: fixture.files.appendingPathComponent("bar.md"))

        let manifest = manifest(syncDir: fixture.sync, entries: [
            entry("foo.md", syncDir: fixture.sync, kind: .modified),
            entry("bar.md", syncDir: fixture.sync, kind: .modified),
        ])

        let diff = try ExplicitSync.diffText(manifest, root: fixture.stage, path: "foo.md")

        #expect(diff.contains("modified"))
        #expect(diff.contains("foo.md"))
        #expect(diff.contains("-old foo"))
        #expect(diff.contains("+new foo"))
        #expect(!diff.contains("bar.md"))
        #expect(!diff.contains("old bar"))
    }

    @Test("path argument accepts an absolute local path")
    func pathArgumentAcceptsAbsoluteLocalPath() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let local = fixture.sync.appendingPathComponent("nested/foo.md")
        let staged = fixture.files.appendingPathComponent("nested/foo.md")
        try write("local\n", to: local)
        try write("cloud\n", to: staged)

        let manifest = manifest(syncDir: fixture.sync, entries: [
            entry("nested/foo.md", syncDir: fixture.sync, kind: .modified),
        ])

        let diff = try ExplicitSync.diffText(manifest, root: fixture.stage, path: local.path)

        #expect(diff.contains("nested/foo.md"))
        #expect(diff.contains("-local"))
        #expect(diff.contains("+cloud"))
    }

    @Test("path argument reports missing staged paths")
    func pathArgumentReportsMissingPath() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let manifest = manifest(syncDir: fixture.sync, entries: [
            entry("foo.md", syncDir: fixture.sync, kind: .modified),
        ])

        do {
            _ = try ExplicitSync.diffText(manifest, root: fixture.stage, path: "missing.md")
            Issue.record("expected pathNotStaged")
        } catch let error as ExplicitSync.SyncError {
            guard case .pathNotStaged(let path) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(path == "missing.md")
        }
    }

    private struct Fixture {
        let root: URL
        let sync: URL
        let stage: URL
        let files: URL
    }

    private func makeFixture() throws -> Fixture {
        let fm = FileManager.default
        let basePath = ProcessInfo.processInfo.environment["RMSYNC_TEST_TMPDIR"]
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? fm.temporaryDirectory.path
        let root = URL(fileURLWithPath: basePath, isDirectory: true)
            .appendingPathComponent("rmsync-explicit-diff-tests-\(UUID().uuidString)", isDirectory: true)
        let sync = root.appendingPathComponent("sync", isDirectory: true)
        let stage = root.appendingPathComponent("stage", isDirectory: true)
        let files = stage.appendingPathComponent("files", isDirectory: true)
        try fm.createDirectory(at: sync, withIntermediateDirectories: true)
        try fm.createDirectory(at: files, withIntermediateDirectories: true)
        return Fixture(root: root, sync: sync, stage: stage, files: files)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func manifest(syncDir: URL, entries: [ExplicitSync.Entry]) -> ExplicitSync.Manifest {
        ExplicitSync.Manifest(
            id: "stage-id",
            createdAt: "2026-06-03T00:00:00Z",
            remoteFolder: Config.defaultRemoteFolder,
            syncDir: syncDir.path,
            entries: entries
        )
    }

    private func entry(
        _ rel: String,
        syncDir: URL,
        kind: ExplicitSync.ChangeKind
    ) -> ExplicitSync.Entry {
        let stem = rel.hasSuffix(".md") ? String(rel.dropLast(3)) : rel
        return ExplicitSync.Entry(
            kind: kind,
            docID: "doc-\(rel)",
            remotePath: "/sync/notes/\(stem)",
            localPath: syncDir.appendingPathComponent(rel).path,
            relativePath: rel,
            stagedPath: kind == .deleted ? nil : "files/\(rel)",
            remoteModified: "2026-06-03T00:00:00Z",
            remoteVersion: 1,
            remoteHash: "remote-\(rel)",
            remoteTabletHash: "remote-\(rel)",
            localHashAtPull: "local-\(rel)",
            baselineHash: "base-\(rel)",
            pageIDs: ["page-\(rel)"],
            error: nil
        )
    }
}
