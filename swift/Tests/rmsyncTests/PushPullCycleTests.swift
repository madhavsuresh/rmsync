import Foundation
import Testing
@testable import rmsync

/// Full deterministic push→pull composition test.
/// or ``Cloud``. Composes:
///
///   ``md → PageSplitter.split → [renderPage] → Archive.pack →
///    Archive.unpack → [parsePage] → PageSplitter.join → md'``
///
/// If any shape of ``md`` fails to round-trip, we have pinpoint evidence
/// of which in-process layer is responsible for the `attacks.md` wipe
/// class of bugs. If all shapes round-trip here but real docs still
/// wipe on live cloud pulls, the fault is server-side (hypothesis D).
@Suite("Push → pull full in-process cycle")
struct PushPullCycleTests {

    private let author = "11111111-2222-3333-4444-555555555555"

    private func cycle(_ md: String, docName: String) async throws -> String {
        // 1. Split markdown into per-page strings.
        let pagesMd = PageSplitter.split(md)

        // 2. Encode each page to .rm bytes.
        var pageBytes: [Data] = []
        var pageIDs: [String] = []
        for text in pagesMd {
            let bytes = try PageCodec.renderPage(text: text, authorUUID: author)
            pageBytes.append(bytes)
            pageIDs.append(Archive.newPageID())
        }

        // 3. Pack into a .rmdoc archive.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmsync-cycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let archivePath = tmp.appendingPathComponent("\(docName).rmdoc")
        let rmDocPages = zip(pageIDs, pageBytes).map {
            Archive.RmDocPage(pageID: $0.0, rmBytes: $0.1)
        }
        let doc = Archive.RmDoc(
            docID: "doc-\(UUID().uuidString.prefix(8))",
            visibleName: docName,
            parent: "",
            pages: rmDocPages,
            version: 1
        )
        _ = try await Archive.pack(doc, to: archivePath)

        // 4. Unpack — this is the same call the pull path makes.
        let unpacked = try await Archive.unpack(archivePath)

        // 5. Byte-identity check: Archive is expected to be transparent.
        //    If this ever fails we've found hypothesis B.
        #expect(unpacked.pages.count == pageBytes.count)
        for (i, page) in unpacked.pages.enumerated() {
            #expect(page.rmBytes == pageBytes[i])
        }

        // 6. Parse each page back, applying the pull-path filter that
        //    the fix introduced (skip empty pages, bail if all empty).
        var parsed: [String] = []
        for page in unpacked.pages {
            parsed.append(try PageCodec.parsePage(page.rmBytes))
        }
        let nonEmpty = parsed.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else {
            // Matches the "all empty → skip" guard in the pull renderer.
            throw PullCycleError.allPagesParsedEmpty
        }
        return PageSplitter.join(nonEmpty)
    }

    enum PullCycleError: Error, CustomStringConvertible {
        case allPagesParsedEmpty
        var description: String {
            switch self {
            case .allPagesParsedEmpty:
                return "every page parsed to empty — pull would be refused"
            }
        }
    }

    // MARK: - happy-path round-trips

    @Test("single-page plain markdown round-trips through full cycle")
    func singlePagePlain() async throws {
        let md = "hello\nworld\nthird line\n"
        let out = try await cycle(md, docName: "single-plain")
        #expect(out.contains("hello"))
        #expect(out.contains("world"))
        #expect(out.contains("third line"))
    }

    @Test("multi-page doc round-trips page-break separators")
    func multiPage() async throws {
        let md = """
        first page line 1
        first page line 2

        <!-- rmsync:page-break -->

        second page content
        """ + "\n"
        let out = try await cycle(md, docName: "multi-page")
        #expect(out.contains("first page line 1"))
        #expect(out.contains("second page content"))
        #expect(out.contains(PageSplitter.pageBreak))
    }

    @Test("attacks.md-shape doc (many short paragraphs) round-trips")
    func attacksShape() async throws {
        // Approximates a notebook used as a running task list:
        // many one-line paragraphs, no special formatting. This is
        // precisely the shape the user's real `attacks.md` had.
        let md = (1...50).map { "attack \($0) description" }.joined(separator: "\n") + "\n"
        let out = try await cycle(md, docName: "attacks-shape")
        #expect(out.contains("attack 1 "))
        #expect(out.contains("attack 25 "))
        #expect(out.contains("attack 50 "))
        // Critically: output must NOT be just "\n" — that's the wipe
        // signature from the original bug.
        #expect(out.count > 100)
    }

    // MARK: - explicit bug-repro

    @Test("cycle with a single empty page is refused by the pull-path guard")
    func singleEmptyPageRefused() async throws {
        // Build the archive manually with one page whose content is
        // empty. ``renderPage("")`` produces bytes that parse to "",
        // which the pull-path guard must refuse to overwrite with.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmsync-cycle-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let bytes = try PageCodec.renderPage(text: "", authorUUID: author)
        let doc = Archive.RmDoc(
            docID: "empty-1",
            visibleName: "empty-doc",
            parent: "",
            pages: [Archive.RmDocPage(pageID: Archive.newPageID(), rmBytes: bytes)],
            version: 1
        )
        let archivePath = tmp.appendingPathComponent("empty.rmdoc")
        _ = try await Archive.pack(doc, to: archivePath)
        let unpacked = try await Archive.unpack(archivePath)

        // Parse — this should return "" (contract), which the fix's
        // filter+bail must catch. Before the fix, this was the exact
        // payload (``"\n"``) that got atomically written over
        // ``attacks.md`` and truncated it to 1 byte.
        let parsed = unpacked.pages.map { (try? PageCodec.parsePage($0.rmBytes)) ?? "?" }
        #expect(parsed.count == 1)
        #expect(parsed[0] == "")

        // Apply the same policy used by the pull renderer.
        let emptyCount = parsed.filter { $0.isEmpty }.count
        #expect(emptyCount == parsed.count)  // all empty → pull refuses
    }

    // MARK: - Archive byte-identity cross-check (Change 5B)

    /// Stronger than ``ArchiveTests.packUnpackRoundTrip`` — uses real
    /// ``renderPage`` output (non-trivial binary shape) and asserts
    /// zip pack/unpack is byte-transparent.
    @Test("Archive.pack then unpack preserves rendered .rm bytes exactly")
    func archiveByteIdentity() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmsync-archive-id-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pageTexts = [
            "hello world\n",
            "second page with some more content\nand a second line\n",
            "third page\n",
        ]
        var rmBytesList: [Data] = []
        var rmDocPages: [Archive.RmDocPage] = []
        for text in pageTexts {
            let bytes = try PageCodec.renderPage(text: text, authorUUID: author)
            rmBytesList.append(bytes)
            rmDocPages.append(Archive.RmDocPage(pageID: Archive.newPageID(), rmBytes: bytes))
        }

        let archivePath = tmp.appendingPathComponent("doc.rmdoc")
        _ = try await Archive.pack(
            Archive.RmDoc(
                docID: "doc-id-1", visibleName: "Archive Identity",
                parent: "", pages: rmDocPages, version: 1
            ),
            to: archivePath
        )
        let unpacked = try await Archive.unpack(archivePath)
        #expect(unpacked.pages.count == rmBytesList.count)

        // SHA256-based cross-check: documents the per-byte identity
        // clearly in any failure report.
        for (i, page) in unpacked.pages.enumerated() {
            let originalSHA = PathUtilities.sha256(bytes: rmBytesList[i])
            let unpackedSHA = PathUtilities.sha256(bytes: page.rmBytes)
            #expect(originalSHA == unpackedSHA,
                "page \(i): zip pack/unpack mutated .rm bytes (orig=\(originalSHA) vs unpacked=\(unpackedSHA))")
        }
    }
}
