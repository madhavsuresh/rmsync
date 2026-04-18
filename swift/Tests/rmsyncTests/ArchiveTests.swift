import Foundation
import Testing
@testable import rmsync

@Suite("Archive pack/unpack")
struct ArchiveTests {
    @Test("pack → unpack preserves pages")
    func packUnpackRoundTrip() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmsync-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pageID1 = Archive.newPageID()
        let pageID2 = Archive.newPageID()
        let doc = Archive.RmDoc(
            docID: "doc-1234",
            visibleName: "My Notebook",
            parent: "",
            pages: [
                Archive.RmDocPage(pageID: pageID1, rmBytes: Data([0x00, 0x01, 0x02])),
                Archive.RmDocPage(pageID: pageID2, rmBytes: Data([0x03, 0x04, 0x05, 0x06])),
            ],
            version: 3
        )
        let archivePath = tmp.appendingPathComponent("doc.rmdoc")
        _ = try await Archive.pack(doc, to: archivePath)
        #expect(FileManager.default.fileExists(atPath: archivePath.path))

        let roundTrip = try await Archive.unpack(archivePath)
        #expect(roundTrip.docID == "doc-1234")
        #expect(roundTrip.visibleName == "My Notebook")
        #expect(roundTrip.pages.count == 2)
        #expect(roundTrip.pages[0].pageID == pageID1)
        #expect(roundTrip.pages[0].rmBytes == Data([0x00, 0x01, 0x02]))
        #expect(roundTrip.pages[1].pageID == pageID2)
    }

    /// The cover-page regression. ``coverPageNumber: -1`` is load-bearing —
    /// anything else makes the tablet render a blank cover page. See
    /// CHANGES_FROM_SPEC.md for the discovery story.
    @Test("packed .content has coverPageNumber = -1")
    func coverPageNumberNegativeOne() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmsync-cover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let doc = Archive.RmDoc(
            docID: "abc",
            visibleName: "N",
            pages: [Archive.RmDocPage(pageID: Archive.newPageID(), rmBytes: Data([0x50]))]
        )
        let archivePath = tmp.appendingPathComponent("x.rmdoc")
        _ = try await Archive.pack(doc, to: archivePath)

        // Peek at the .content JSON directly — unpack strips it to the
        // pages list, which is not what we want to assert about here.
        let extractDir = tmp.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        let unzip = try await Subprocess.run(
            executablePath: "/usr/bin/unzip",
            args: ["-qq", "-o", archivePath.path, "-d", extractDir.path]
        )
        #expect(unzip.exitCode == 0)

        let contentData = try Data(contentsOf: extractDir.appendingPathComponent("abc.content"))
        let content = try JSONSerialization.jsonObject(with: contentData) as! [String: Any]

        // Three invariants:
        //   1. coverPageNumber is -1
        //   2. pageCount matches
        //   3. cPages shape (no legacy flat "pages: [id, ...]")
        #expect(content["coverPageNumber"] as? Int == -1)
        #expect(content["pageCount"] as? Int == 1)
        #expect(content["cPages"] != nil)

        let cpages = content["cPages"] as! [String: Any]
        let entries = cpages["pages"] as! [[String: Any]]
        #expect(entries.count == 1)
        let entry = entries[0]
        #expect(entry["id"] is String)
        #expect(entry["idx"] != nil)
        // No ``template`` field on content pages — the presence of
        // ``template: Blank`` is what the tablet injects, and we must
        // not mirror that back on upload.
        #expect(entry["template"] == nil)
    }

    @Test("extract page_ids handles legacy + sync15 shapes")
    func extractPageIDsBothShapes() async throws {
        // Write a minimal archive by hand with the legacy shape, verify
        // unpack still returns the page.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmsync-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let docID = "legacy-1"
        let pageID = "page-legacy-1"
        let staging = tmp.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let meta: [String: Any] = ["visibleName": "Legacy", "version": 1]
        let content: [String: Any] = [
            "coverPageNumber": -1,
            "pageCount": 1,
            "pages": [pageID],  // legacy flat shape
            "fileType": "notebook",
        ]
        try JSONSerialization.data(withJSONObject: meta)
            .write(to: staging.appendingPathComponent("\(docID).metadata"))
        try JSONSerialization.data(withJSONObject: content)
            .write(to: staging.appendingPathComponent("\(docID).content"))
        let pageDir = staging.appendingPathComponent(docID, isDirectory: true)
        try FileManager.default.createDirectory(at: pageDir, withIntermediateDirectories: true)
        try Data([0xDE, 0xAD, 0xBE, 0xEF]).write(
            to: pageDir.appendingPathComponent("\(pageID).rm")
        )

        let archivePath = tmp.appendingPathComponent("legacy.rmdoc")
        let zipResult = try await Subprocess.run(
            executablePath: "/usr/bin/zip",
            args: ["-qr", archivePath.path, "."],
            cwd: staging
        )
        #expect(zipResult.exitCode == 0)

        let unpacked = try await Archive.unpack(archivePath)
        #expect(unpacked.pages.count == 1)
        #expect(unpacked.pages[0].pageID == pageID)
        #expect(unpacked.pages[0].rmBytes == Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }
}
