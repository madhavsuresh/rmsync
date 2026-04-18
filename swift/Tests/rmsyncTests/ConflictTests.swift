import Foundation
import Testing
@testable import rmsync

@Suite("Conflict marker file")
struct ConflictTests {
    @Test("conflict_path adds .conflict suffix")
    func conflictPathSuffix() {
        let md = URL(fileURLWithPath: "/tmp/note.md")
        #expect(Conflict.conflictPath(for: md).lastPathComponent == "note.md.conflict")
    }

    @Test("write produces git-style markers")
    func writeContainsMarkers() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmsync-conflict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let md = tmp.appendingPathComponent("note.md")
        try "local content\n".write(to: md, atomically: true, encoding: .utf8)
        let cp = try Conflict.write(md: md, local: "local content\n", remote: "remote content\n")
        let body = try String(contentsOf: cp, encoding: .utf8)
        #expect(body.contains("<<<<<<< local"))
        #expect(body.contains("=======\n"))
        #expect(body.contains(">>>>>>> remote"))
        // Live file is untouched.
        #expect(try String(contentsOf: md, encoding: .utf8) == "local content\n")
    }

    @Test("has_unresolved_conflict_file toggles with the file's presence")
    func hasUnresolvedTracksExistence() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmsync-conflict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let md = tmp.appendingPathComponent("note.md")
        #expect(!Conflict.hasUnresolvedConflictFile(at: md))

        try "hi".write(to: md, atomically: true, encoding: .utf8)
        _ = try Conflict.write(md: md, local: "hi", remote: "bye")
        #expect(Conflict.hasUnresolvedConflictFile(at: md))

        try FileManager.default.removeItem(at: Conflict.conflictPath(for: md))
        #expect(!Conflict.hasUnresolvedConflictFile(at: md))
    }
}
