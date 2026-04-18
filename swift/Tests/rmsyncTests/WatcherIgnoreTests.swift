import Foundation
import Testing
@testable import rmsync

@Suite("Watcher ignore rules")
struct WatcherIgnoreTests {
    @Test("Dropbox conflict copies are ignored")
    func dropboxConflictCopy() {
        let sync = URL(fileURLWithPath: "/tmp/sync")
        #expect(LocalWatcher.shouldIgnore(
            "/tmp/sync/foo (Mac mini's conflicted copy 2026-04-17).md",
            syncDir: sync
        ))
        #expect(LocalWatcher.shouldIgnore(
            "/tmp/sync/bar (Alice's CONFLICTED COPY 2024-12-01 1).md",
            syncDir: sync
        ))
    }

    @Test("plain .md files are NOT ignored")
    func plainMDPasses() {
        let sync = URL(fileURLWithPath: "/tmp/sync")
        #expect(!LocalWatcher.shouldIgnore("/tmp/sync/note.md", syncDir: sync))
        #expect(!LocalWatcher.shouldIgnore(
            "/tmp/sync/my document with parens (yes).md",
            syncDir: sync
        ))
    }

    @Test("dotfiles / tmp / conflict files ignored")
    func dotfilesAndTmp() {
        let sync = URL(fileURLWithPath: "/tmp/sync")
        #expect(LocalWatcher.shouldIgnore("/tmp/sync/.DS_Store", syncDir: sync))
        #expect(LocalWatcher.shouldIgnore("/tmp/sync/.hidden.md", syncDir: sync))
        #expect(LocalWatcher.shouldIgnore("/tmp/sync/note.md.tmp", syncDir: sync))
        #expect(LocalWatcher.shouldIgnore("/tmp/sync/note.md.conflict", syncDir: sync))
    }

    @Test("non-.md suffixes are ignored")
    func nonMDIgnored() {
        let sync = URL(fileURLWithPath: "/tmp/sync")
        #expect(LocalWatcher.shouldIgnore("/tmp/sync/thing.txt", syncDir: sync))
        #expect(LocalWatcher.shouldIgnore("/tmp/sync/thing.pdf", syncDir: sync))
    }

    @Test("anything under .rmsync-trash ignored")
    func rmSyncTrash() {
        let sync = URL(fileURLWithPath: "/tmp/sync")
        #expect(LocalWatcher.shouldIgnore(
            "/tmp/sync/.rmsync-trash/old.md", syncDir: sync
        ))
    }

    @Test("symlink escapes are ignored")
    func symlinkEscapeIgnored() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmsync-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sync = tmp.appendingPathComponent("sync", isDirectory: true)
        let outside = tmp.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let link = sync.appendingPathComponent("escape", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(LocalWatcher.shouldIgnore(
            link.appendingPathComponent("note.md").path,
            syncDir: sync
        ))
    }
}
