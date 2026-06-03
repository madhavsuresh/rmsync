import Foundation

/// Joins per-page Markdown into a single document, splitting on an HTML
/// comment sentinel that can't be typed on the tablet by accident (which
/// ``---`` could — it's a legitimate Markdown horizontal rule).
///
/// Port of ``src/rm_sync/conversion/page_splitter.py``.
enum PageSplitter {
    static let pageBreak = "<!-- rmsync:page-break -->"

    static func join(_ pages: [String]) -> String {
        if pages.count == 1 { return pages[0] }
        let cleaned = pages.map { $0.trimmingTrailingNewlines() + "\n" }
        return cleaned.joined(separator: "\n\(pageBreak)\n\n")
    }

    static func split(_ markdown: String) -> [String] {
        let pattern = /(?m)^[ \t]*<!--\s*rmsync:page-break\s*-->[ \t]*$/
        if markdown.firstMatch(of: pattern) == nil { return [markdown] }
        let parts = markdown.split(separator: pattern, omittingEmptySubsequences: false)
        if parts.isEmpty { return [""] }
        return parts.map { piece -> String in
            let trimmed = String(piece).trimmingCharacters(in: .newlines)
            return trimmed.isEmpty ? "" : trimmed + "\n"
        }
    }
}

private extension String {
    func trimmingTrailingNewlines() -> String {
        var s = self
        while s.hasSuffix("\n") { s.removeLast() }
        return s
    }
}
