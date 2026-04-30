import Foundation
import Testing
@testable import rmsync

/// Tests routed through the cross-platform ``WatcherFilter`` rather
/// than ``LocalWatcher.shouldIgnore``. The forwarder on
/// ``LocalWatcher`` is macOS-only (the type itself is gated to
/// ``#if os(macOS)``) — the underlying rules live in
/// ``WatcherFilter``, so testing against that gives Linux coverage
/// too.
@Suite("Watcher ignore rules")
struct WatcherIgnoreTests {
    @Test("Dropbox conflict copies are ignored")
    func dropboxConflictCopy() {
        let sync = URL(fileURLWithPath: "/tmp/sync")
        #expect(WatcherFilter.shouldIgnore(
            "/tmp/sync/foo (Mac mini's conflicted copy 2026-04-17).md",
            root: sync, mode: .markdown
        ))
        #expect(WatcherFilter.shouldIgnore(
            "/tmp/sync/bar (Alice's CONFLICTED COPY 2024-12-01 1).md",
            root: sync, mode: .markdown
        ))
    }

    @Test("plain .md files are NOT ignored in markdown mode")
    func plainMDPasses() {
        let sync = URL(fileURLWithPath: "/tmp/sync")
        #expect(!WatcherFilter.shouldIgnore("/tmp/sync/note.md", root: sync, mode: .markdown))
        #expect(!WatcherFilter.shouldIgnore(
            "/tmp/sync/my document with parens (yes).md",
            root: sync, mode: .markdown
        ))
    }

    @Test("dotfiles / tmp / conflict files ignored in both modes")
    func dotfilesAndTmp() {
        let sync = URL(fileURLWithPath: "/tmp/sync")
        for mode in [WatcherMode.markdown, .inbox] {
            #expect(WatcherFilter.shouldIgnore("/tmp/sync/.DS_Store", root: sync, mode: mode))
            #expect(WatcherFilter.shouldIgnore("/tmp/sync/.hidden.md", root: sync, mode: mode))
            #expect(WatcherFilter.shouldIgnore("/tmp/sync/note.md.tmp", root: sync, mode: mode))
            #expect(WatcherFilter.shouldIgnore("/tmp/sync/note.md.conflict", root: sync, mode: mode))
        }
    }

    @Test("non-.md suffixes are ignored in markdown mode")
    func nonMDIgnoredInMarkdown() {
        let sync = URL(fileURLWithPath: "/tmp/sync")
        #expect(WatcherFilter.shouldIgnore("/tmp/sync/thing.txt", root: sync, mode: .markdown))
        #expect(WatcherFilter.shouldIgnore("/tmp/sync/thing.pdf", root: sync, mode: .markdown))
        #expect(WatcherFilter.shouldIgnore("/tmp/sync/thing.epub", root: sync, mode: .markdown))
    }

    @Test("anything under .rmsync-trash ignored")
    func rmSyncTrash() {
        let sync = URL(fileURLWithPath: "/tmp/sync")
        #expect(WatcherFilter.shouldIgnore(
            "/tmp/sync/.rmsync-trash/old.md", root: sync, mode: .markdown
        ))
    }

    // MARK: - inbox-mode-specific rules

    @Test("inbox mode: PDF and EPUB pass; .md ignored")
    func inboxAcceptsPDFAndEPUB() {
        let inbox = URL(fileURLWithPath: "/tmp/inbox")
        #expect(!WatcherFilter.shouldIgnore("/tmp/inbox/paper.pdf", root: inbox, mode: .inbox))
        #expect(!WatcherFilter.shouldIgnore("/tmp/inbox/book.epub", root: inbox, mode: .inbox))
        // Case-insensitive on extension.
        #expect(!WatcherFilter.shouldIgnore("/tmp/inbox/UPPER.PDF", root: inbox, mode: .inbox))
        // .md, .txt, .docx all rejected — only PDF/EPUB land cleanly on the tablet.
        #expect(WatcherFilter.shouldIgnore("/tmp/inbox/note.md", root: inbox, mode: .inbox))
        #expect(WatcherFilter.shouldIgnore("/tmp/inbox/notes.txt", root: inbox, mode: .inbox))
        #expect(WatcherFilter.shouldIgnore("/tmp/inbox/file.docx", root: inbox, mode: .inbox))
    }

    @Test("symlink escapes are ignored in both modes")
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

        for mode in [WatcherMode.markdown, .inbox] {
            #expect(WatcherFilter.shouldIgnore(
                link.appendingPathComponent("note.md").path,
                root: sync, mode: mode
            ))
        }
    }

    // MARK: - shouldIgnoreDir (directory-event filter, v0.2.22+)

    @Test("dir helper: regular subdir passes")
    func dirRegular() {
        let sync = URL(fileURLWithPath: "/tmp/sync")
        #expect(!WatcherFilter.shouldIgnoreDir("/tmp/sync/papers", root: sync, mode: .markdown))
        #expect(!WatcherFilter.shouldIgnoreDir("/tmp/sync/papers/2026", root: sync, mode: .markdown))
    }

    @Test("dir helper: hidden dirs blocked")
    func dirHiddenBlocked() {
        let sync = URL(fileURLWithPath: "/tmp/sync")
        #expect(WatcherFilter.shouldIgnoreDir("/tmp/sync/.git", root: sync, mode: .markdown))
        #expect(WatcherFilter.shouldIgnoreDir("/tmp/sync/.obsidian", root: sync, mode: .markdown))
        #expect(WatcherFilter.shouldIgnoreDir("/tmp/sync/.rmsync-trash/20260429T000000000Z", root: sync, mode: .markdown))
    }

    @Test("dir helper: anything below a hidden dir blocked")
    func dirNestedHidden() {
        let sync = URL(fileURLWithPath: "/tmp/sync")
        #expect(WatcherFilter.shouldIgnoreDir(
            "/tmp/sync/.git/refs/heads", root: sync, mode: .markdown
        ))
    }

    @Test("dir helper: inbox mode rejects every dir event")
    func dirInboxRejected() {
        let sync = URL(fileURLWithPath: "/tmp/sync")
        #expect(WatcherFilter.shouldIgnoreDir("/tmp/sync/papers", root: sync, mode: .inbox))
    }
}
