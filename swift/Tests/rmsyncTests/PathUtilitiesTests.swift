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
