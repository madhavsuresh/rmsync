import Foundation
import Testing
@testable import rmsync

@Suite("Page splitter")
struct PageSplitterTests {
    @Test("join then split round-trips multi-page content")
    func joinSplitRoundTrip() {
        let pages = ["first page\n", "second page\n", "third page\n"]
        let joined = PageSplitter.join(pages)
        #expect(joined.contains(PageSplitter.pageBreak))
        let parts = PageSplitter.split(joined)
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { $0.contains("page") })
    }

    @Test("split returns a single page when no separator present")
    func splitNoSeparator() {
        let parts = PageSplitter.split("just one page\n")
        #expect(parts.count == 1)
    }

    /// The reason we use the HTML-comment sentinel: ``---`` alone must
    /// not split, because it's a legitimate Markdown horizontal rule.
    @Test("horizontal rule does NOT split")
    func horizontalRuleSurvives() {
        let md = "para one\n\n---\n\npara two\n"
        let parts = PageSplitter.split(md)
        #expect(parts.count == 1)
        #expect(parts[0].contains("---"))
    }

    @Test("empty input still returns one (empty) page")
    func emptyInput() {
        #expect(PageSplitter.split("") == [""])
    }
}
