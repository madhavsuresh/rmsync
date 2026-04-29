// Xattrs.swift's full implementation only exists on macOS — see the
// `#if os(macOS)` wrap in that file. The Linux stub there is a no-op,
// so these round-trip tests have nothing to assert against on Linux.
#if os(macOS)
import Foundation
import Testing
@testable import rmsync

@Suite("Xattrs (macOS)")
struct XattrsTests {
    @Test("apply writes the expected xattr set")
    func applyRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmsync-xattr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let file = tmp.appendingPathComponent("note.md")
        try "hi\n".write(to: file, atomically: true, encoding: .utf8)

        let meta = Xattrs.FileMetadata(
            docID: "abc-123",
            remotePath: "/Writing/foo",
            remoteModified: "2026-04-18T12:00:00Z",
            pageIDs: ["p1", "p2"]
        )
        Xattrs.apply(meta, to: file)

        let docIDRead = try Xattrs.getRaw(path: file, name: Xattrs.docIDKey)
        #expect(String(data: docIDRead, encoding: .utf8) == "abc-123")

        let rp = try Xattrs.getRaw(path: file, name: Xattrs.remotePathKey)
        #expect(String(data: rp, encoding: .utf8) == "/Writing/foo")

        let rm = try Xattrs.getRaw(path: file, name: Xattrs.remoteModifiedKey)
        #expect(String(data: rm, encoding: .utf8) == "2026-04-18T12:00:00Z")

        let pages = try Xattrs.getRaw(path: file, name: Xattrs.pageIDsKey)
        #expect(String(data: pages, encoding: .utf8) == "[\"p1\",\"p2\"]")

        // readDocID reads back the same value.
        #expect(Xattrs.readDocID(at: file) == "abc-123")

        // WhereFroms is a bplist array of strings.
        let wfData = try Xattrs.getRaw(path: file, name: Xattrs.whereFroms)
        let wf = try PropertyListSerialization.propertyList(
            from: wfData, format: nil
        ) as! [String]
        #expect(wf == ["reMarkable Cloud", "/Writing/foo"])

        // Kind is a single-string bplist.
        let kindData = try Xattrs.getRaw(path: file, name: Xattrs.kind)
        let kindValue = try PropertyListSerialization.propertyList(
            from: kindData, format: nil
        ) as! String
        #expect(kindValue == "reMarkable Notebook")

        // Tag entry is "<name>\n<colour>".
        let tagData = try Xattrs.getRaw(path: file, name: Xattrs.userTags)
        let tags = try PropertyListSerialization.propertyList(
            from: tagData, format: nil
        ) as! [String]
        #expect(tags == ["reMarkable\n5"])
    }

    @Test("apply skips nil fields")
    func skipsNilFields() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmsync-xattr-nil-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let file = tmp.appendingPathComponent("note.md")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        Xattrs.apply(Xattrs.FileMetadata(), to: file)

        // Core WhereFroms/kind/tag always get written.
        #expect((try? Xattrs.getRaw(path: file, name: Xattrs.kind)) != nil)
        // But rmsync.* xattrs are absent when the metadata is empty.
        #expect(Xattrs.readDocID(at: file) == nil)
        #expect((try? Xattrs.getRaw(path: file, name: Xattrs.remotePathKey)) == nil)
    }
}

#endif

