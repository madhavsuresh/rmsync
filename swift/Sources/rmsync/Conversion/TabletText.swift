import Foundation

/// Source-preserving text transforms for the tablet display path.
///
/// The local Markdown file is authoritative. We only collapse blank lines
/// before writing text to the tablet so Markdown paragraph separators do not
/// render as oversized vertical gaps. We do not translate Markdown syntax into
/// native reMarkable styles.
enum TabletText {
    struct Normalized {
        var text: String
        var sourceBoundaries: [String.Index]
    }

    static func normalizeForTablet(_ source: String) -> String {
        normalizeWithBoundaries(source).text
    }

    static func sourceByApplyingTabletEdit(
        baseSource: String,
        editedTablet: String
    ) -> String? {
        let normalized = normalizeWithBoundaries(baseSource)
        let baseTablet = normalized.text
        if editedTablet == baseTablet { return baseSource }

        let patch = singleRangePatch(base: baseTablet, edited: editedTablet)
        guard patch.start <= patch.end,
              patch.end < normalized.sourceBoundaries.count else {
            return nil
        }

        let sourceStart = normalized.sourceBoundaries[patch.start]
        let sourceEnd = normalized.sourceBoundaries[patch.end]
        return String(baseSource[..<sourceStart])
            + patch.replacement
            + String(baseSource[sourceEnd...])
    }

    static func normalizeWithBoundaries(_ source: String) -> Normalized {
        guard !source.isEmpty else {
            return Normalized(text: "", sourceBoundaries: [source.startIndex])
        }

        var output = ""
        var boundaries: [String.Index] = [source.startIndex]
        var inFence = false
        var lineStart = source.startIndex

        func emit(_ range: Range<String.Index>) {
            var idx = range.lowerBound
            while idx < range.upperBound {
                output.append(source[idx])
                idx = source.index(after: idx)
                boundaries.append(idx)
            }
        }

        func skipThrough(_ idx: String.Index) {
            boundaries[boundaries.count - 1] = idx
        }

        while lineStart < source.endIndex {
            var lineEnd = lineStart
            while lineEnd < source.endIndex, source[lineEnd] != "\n" {
                lineEnd = source.index(after: lineEnd)
            }
            if lineEnd < source.endIndex {
                lineEnd = source.index(after: lineEnd)
            }

            let line = String(source[lineStart..<lineEnd])
            let body = line.hasSuffix("\n") ? String(line.dropLast()) : line
            let trimmed = body.trimmingCharacters(in: .whitespaces)
            let fenceLine = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")

            if fenceLine {
                emit(lineStart..<lineEnd)
                inFence.toggle()
            } else if !inFence, trimmed.isEmpty {
                skipThrough(lineEnd)
            } else {
                emit(lineStart..<lineEnd)
            }

            lineStart = lineEnd
        }

        return Normalized(text: output, sourceBoundaries: boundaries)
    }

    private static func singleRangePatch(base: String, edited: String) -> (
        start: Int, end: Int, replacement: String
    ) {
        let baseChars = Array(base)
        let editedChars = Array(edited)
        var prefix = 0
        while prefix < baseChars.count,
              prefix < editedChars.count,
              baseChars[prefix] == editedChars[prefix] {
            prefix += 1
        }

        var suffix = 0
        while suffix < baseChars.count - prefix,
              suffix < editedChars.count - prefix,
              baseChars[baseChars.count - 1 - suffix] == editedChars[editedChars.count - 1 - suffix] {
            suffix += 1
        }

        let baseEnd = baseChars.count - suffix
        let editedEnd = editedChars.count - suffix
        let replacement = String(editedChars[prefix..<editedEnd])
        return (prefix, baseEnd, replacement)
    }
}
