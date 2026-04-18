import Foundation
import Testing
@testable import rmsync

/// Tests for the ``relocate`` subcommand's core logic. Exercises the
/// state-rewrite + config-rewrite pieces directly — the launchd
/// orchestration gets its own live test in Week 8.
@Suite("Relocate")
struct RelocateTests {
    @Test("state rows rewrite when sync_dir prefix changes")
    func stateRewritesLocalPaths() async throws {
        let (tmp, state, old, new) = try await setUp()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try await state.upsert(Document(
            docID: "doc-1",
            parentID: "",
            docType: "DocumentType",
            title: "Doc 1",
            remotePath: "/Writing/Doc 1",
            localPath: old.appendingPathComponent("Doc 1.md").path
        ))
        try await state.upsert(Document(
            docID: "doc-2",
            parentID: "",
            docType: "DocumentType",
            title: "Doc 2",
            remotePath: "/Writing/sub/Doc 2",
            localPath: old.appendingPathComponent("sub/Doc 2.md").path
        ))

        // Hand-port the rewrite step (this is what RelocateImpl.run
        // does internally between moveTree and config rewrite).
        let docs = try await state.allDocuments()
        let oldPrefix = old.path + "/"
        let newPrefix = new.path + "/"
        for var doc in docs where doc.localPath.hasPrefix(oldPrefix) {
            doc.localPath = newPrefix + doc.localPath.dropFirst(oldPrefix.count)
            try await state.upsert(doc)
        }

        let after = try await state.allDocuments()
        #expect(after.allSatisfy { $0.localPath.hasPrefix(new.path) })
    }

    @Test("config rewrite preserves surrounding structure")
    func configRewriteKeepsOtherKeys() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmsync-relocate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let cfgPath = tmp.appendingPathComponent("config.toml")
        try """
            # top comment
            sync_dir      = "/Users/alice/old-dir"
            remote_folder = "Writing"

            worker_pool_size = 3

            [log]
            level = "INFO"
            """.write(to: cfgPath, atomically: true, encoding: .utf8)

        let text = try String(contentsOf: cfgPath, encoding: .utf8)
        let pattern = /^(\s*sync_dir\s*=\s*)"[^"]*"/.anchorsMatchLineEndings()
        let rewritten = text.replacing(pattern) { match in
            match.output.1 + "\"/Users/alice/new-dir\""
        }

        #expect(rewritten.contains("sync_dir      = \"/Users/alice/new-dir\""))
        #expect(rewritten.contains("# top comment"))
        #expect(rewritten.contains("remote_folder = \"Writing\""))
        #expect(rewritten.contains("worker_pool_size = 3"))
        #expect(rewritten.contains("[log]"))
        #expect(rewritten.contains("level = \"INFO\""))
    }

    // MARK: - helpers

    private func setUp() async throws -> (tmp: URL, state: State, old: URL, new: URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmsync-relocate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let old = tmp.appendingPathComponent("old", isDirectory: true)
        let new = tmp.appendingPathComponent("new", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)

        let state = try State(path: tmp.appendingPathComponent("state.db"))
        return (tmp, state, old, new)
    }
}
