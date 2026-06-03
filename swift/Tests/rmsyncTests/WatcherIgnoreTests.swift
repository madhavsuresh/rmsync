import Foundation
import Testing
@testable import rmsync

@Suite("Watcher ignore rules")
struct WatcherIgnoreTests {
    @Test("Dropbox conflict copies are ignored")
    func dropboxConflictCopy() {
        let sync = URL(fileURLWithPath: "/tmp/sync")
        #expect(WatcherFilter.shouldIgnore(
            "/tmp/sync/foo (Mac mini's conflicted copy 2026-04-17).md",
            root: sync
        ))
        #expect(WatcherFilter.shouldIgnore(
            "/tmp/sync/bar (Alice's CONFLICTED COPY 2024-12-01 1).md",
            root: sync
        ))
    }

    @Test("plain .md files are not ignored")
    func plainMDPasses() {
        let sync = URL(fileURLWithPath: "/tmp/sync")
        #expect(!WatcherFilter.shouldIgnore("/tmp/sync/note.md", root: sync))
        #expect(!WatcherFilter.shouldIgnore(
            "/tmp/sync/my document with parens (yes).md",
            root: sync
        ))
    }

    @Test("dotfiles, tmp files, conflict files, and non-markdown files are ignored")
    func ignoredNamesAndExtensions() {
        let sync = URL(fileURLWithPath: "/tmp/sync")
        #expect(WatcherFilter.shouldIgnore("/tmp/sync/.DS_Store", root: sync))
        #expect(WatcherFilter.shouldIgnore("/tmp/sync/.hidden.md", root: sync))
        #expect(WatcherFilter.shouldIgnore("/tmp/sync/note.md.tmp", root: sync))
        #expect(WatcherFilter.shouldIgnore("/tmp/sync/note.md.conflict", root: sync))
        #expect(WatcherFilter.shouldIgnore("/tmp/sync/thing.txt", root: sync))
        #expect(WatcherFilter.shouldIgnore("/tmp/sync/thing.pdf", root: sync))
        #expect(WatcherFilter.shouldIgnore("/tmp/sync/thing.epub", root: sync))
    }

    @Test("anything under .rmsync-trash is ignored")
    func rmSyncTrash() {
        let sync = URL(fileURLWithPath: "/tmp/sync")
        #expect(WatcherFilter.shouldIgnore(
            "/tmp/sync/.rmsync-trash/old.md", root: sync
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

        #expect(WatcherFilter.shouldIgnore(
            link.appendingPathComponent("note.md").path,
            root: sync
        ))
    }
}
