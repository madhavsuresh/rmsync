import Foundation
import Testing
@testable import rmsync

@Suite("Path utilities")
struct PathUtilitiesTests {
    // MARK: - sanitization

    @Test("sanitize replaces forbidden chars")
    func sanitizeForbidden() {
        #expect(PathUtilities.sanitizeSegment("foo/bar") == "foo_bar")
        #expect(PathUtilities.sanitizeSegment("foo:bar") == "foo_bar")
    }

    @Test("sanitize strips trailing dots and spaces")
    func sanitizeStrips() {
        #expect(PathUtilities.sanitizeSegment("foo.") == "foo")
        #expect(PathUtilities.sanitizeSegment("   ") == "untitled")
        #expect(PathUtilities.sanitizeSegment("") == "untitled")
    }

    @Test("sanitize escapes Windows-reserved names")
    func sanitizeWindowsReserved() {
        #expect(PathUtilities.sanitizeSegment("CON") == "_CON_")
        // Original casing preserved — Python escapes with ``_{s}_``
        // where ``s`` keeps its input casing.
        #expect(PathUtilities.sanitizeSegment("com3") == "_com3_")
    }

    @Test("sanitize leaves well-formed names alone")
    func sanitizePassthrough() {
        #expect(PathUtilities.sanitizeSegment("hello world") == "hello world")
        #expect(PathUtilities.sanitizeSegment("normal_name") == "normal_name")
    }

    @Test("sanitize truncates to 200 chars")
    func sanitizeTruncates() {
        let out = PathUtilities.sanitizeSegment(String(repeating: "x", count: 300))
        #expect(out.count == 200)
    }

    // MARK: - remoteToLocal

    @Test("remote path maps to local .md")
    func remoteToLocalBasic() {
        let sync = URL(fileURLWithPath: "/tmp/sync")
        let result = PathUtilities.remoteToLocal(
            remotePath: "/Writing/Note", syncDir: sync, remoteFolder: "Writing"
        )
        #expect(result.path == "/tmp/sync/Note.md")
    }

    @Test("nested remote path preserves subdirs")
    func remoteToLocalNested() {
        let sync = URL(fileURLWithPath: "/tmp/sync")
        let result = PathUtilities.remoteToLocal(
            remotePath: "/Writing/Research/paper",
            syncDir: sync, remoteFolder: "Writing"
        )
        #expect(result.path == "/tmp/sync/Research/paper.md")
    }

    @Test("multi-segment remote folder prefix is stripped")
    func remoteToLocalMultiSegmentRoot() {
        let sync = URL(fileURLWithPath: "/tmp/sync")
        let result = PathUtilities.remoteToLocal(
            remotePath: "/sync/attack/Research/paper",
            syncDir: sync,
            remoteFolder: "sync/attack"
        )
        #expect(result.path == "/tmp/sync/Research/paper.md")

        let dir = PathUtilities.remoteToLocalDir(
            remotePath: "/sync/attack/Research",
            syncDir: sync,
            remoteFolder: "sync/attack"
        )
        #expect(dir.path == "/tmp/sync/Research")
    }

    // MARK: - localToRemoteParentChain (push side)

    @Test("top-level file maps to remoteFolder root")
    func parentChainTopLevel() {
        let sync = URL(fileURLWithPath: "/tmp/sync")
        let local = sync.appendingPathComponent("foo.md")
        let result = PathUtilities.localToRemoteParentChain(
            localPath: local, syncDir: sync, remoteFolder: "Writing"
        )
        #expect(result.parentPath == "/Writing")
        #expect(result.mkdirChain == ["/Writing"])
    }

    @Test("single-subdir file derives matching cloud parent")
    func parentChainSingleSubdir() {
        let sync = URL(fileURLWithPath: "/tmp/sync")
        let local = sync.appendingPathComponent("papers/foo.md")
        let result = PathUtilities.localToRemoteParentChain(
            localPath: local, syncDir: sync, remoteFolder: "Writing"
        )
        #expect(result.parentPath == "/Writing/papers")
        #expect(result.mkdirChain == ["/Writing", "/Writing/papers"])
    }

    @Test("nested-subdir file builds full mkdir chain")
    func parentChainNested() {
        let sync = URL(fileURLWithPath: "/tmp/sync")
        let local = sync.appendingPathComponent("papers/2026/foo.md")
        let result = PathUtilities.localToRemoteParentChain(
            localPath: local, syncDir: sync, remoteFolder: "Writing"
        )
        #expect(result.parentPath == "/Writing/papers/2026")
        #expect(result.mkdirChain == [
            "/Writing", "/Writing/papers", "/Writing/papers/2026",
        ])
    }

    @Test("remoteToLocalDir: bare /<remoteFolder> maps to sync_dir")
    func remoteToLocalDirTopLevel() {
        let sync = URL(fileURLWithPath: "/tmp/sync")
        let result = PathUtilities.remoteToLocalDir(
            remotePath: "/Writing", syncDir: sync, remoteFolder: "Writing"
        )
        #expect(result.path == "/tmp/sync")
    }

    @Test("remoteToLocalDir: nested cloud folder maps to nested local dir")
    func remoteToLocalDirNested() {
        let sync = URL(fileURLWithPath: "/tmp/sync")
        let result = PathUtilities.remoteToLocalDir(
            remotePath: "/Writing/papers/2026",
            syncDir: sync, remoteFolder: "Writing"
        )
        #expect(result.path == "/tmp/sync/papers/2026")
        // No .md suffix added — we're naming a directory, not a file.
        #expect(!result.path.hasSuffix(".md"))
    }

    @Test("dir helper: sync_dir itself maps to remoteFolder root")
    func dirChainTopLevel() {
        let sync = URL(fileURLWithPath: "/tmp/sync")
        let result = PathUtilities.localDirToRemoteChain(
            localDir: sync, syncDir: sync, remoteFolder: "Writing"
        )
        #expect(result.cloudPath == "/Writing")
        #expect(result.mkdirChain == ["/Writing"])
    }

    @Test("dir helper: single subdir resolves to matching cloud path")
    func dirChainSingleSubdir() {
        let sync = URL(fileURLWithPath: "/tmp/sync")
        let dir = sync.appendingPathComponent("papers")
        let result = PathUtilities.localDirToRemoteChain(
            localDir: dir, syncDir: sync, remoteFolder: "Writing"
        )
        #expect(result.cloudPath == "/Writing/papers")
        #expect(result.mkdirChain == ["/Writing", "/Writing/papers"])
    }

    @Test("dir helper: nested path builds full chain ending at the dir")
    func dirChainNested() {
        let sync = URL(fileURLWithPath: "/tmp/sync")
        let dir = sync.appendingPathComponent("papers/2026")
        let result = PathUtilities.localDirToRemoteChain(
            localDir: dir, syncDir: sync, remoteFolder: "Writing"
        )
        #expect(result.cloudPath == "/Writing/papers/2026")
        #expect(result.mkdirChain == [
            "/Writing", "/Writing/papers", "/Writing/papers/2026",
        ])
    }

    @Test("file outside sync_dir falls back to remoteFolder root")
    func parentChainOutsideSync() {
        // resolvedRelativePath returns nil for paths outside the
        // tree; the helper should default to /<remoteFolder> so a
        // misrouted job lands at the top rather than crashing.
        let sync = URL(fileURLWithPath: "/tmp/sync")
        let local = URL(fileURLWithPath: "/tmp/elsewhere/foo.md")
        let result = PathUtilities.localToRemoteParentChain(
            localPath: local, syncDir: sync, remoteFolder: "Writing"
        )
        #expect(result.parentPath == "/Writing")
        #expect(result.mkdirChain == ["/Writing"])
    }

    @Test("resolvedRelativePath rejects symlink escapes")
    func resolvedRelativePathRejectsSymlinkEscape() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmsync-realpath-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sync = tmp.appendingPathComponent("sync", isDirectory: true)
        let outside = tmp.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let link = sync.appendingPathComponent("escape", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let target = link.appendingPathComponent("note.md")
        #expect(PathUtilities.resolvedRelativePath(from: sync, to: target) == nil)
    }

    // MARK: - atomic write

    @Test("atomicWriteText creates parent + writes content")
    func atomicWriteCreatesParents() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmsync-path-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let nested = tmp.appendingPathComponent("deep/nested/file.md")
        try PathUtilities.atomicWriteText("hello\n", to: nested)
        #expect(try String(contentsOf: nested, encoding: .utf8) == "hello\n")
        // No leftover .tmp sidecar.
        #expect(!FileManager.default.fileExists(
            atPath: nested.appendingPathExtension("tmp").path
        ))
    }

    // MARK: - sha256

    @Test("sha256 matches known vector")
    func sha256KnownVector() {
        // echo -n "hello" | shasum -a 256
        let expected = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        #expect(PathUtilities.sha256("hello") == expected)
    }
}
