import Foundation
import XCTest
@testable import RMScene

struct FormattedParagraph: Equatable {
    let style: ParagraphStyle
    let line: String
}

func fixtureData(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
        XCTFail("Missing fixture \(name)")
        return Data()
    }
    return try Data(contentsOf: url)
}

func hexData(_ hex: String) -> Data {
    let cleaned = hex.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "")
    var result = Data()
    var index = cleaned.startIndex
    while index < cleaned.endIndex {
        let next = cleaned.index(index, offsetBy: 2)
        result.append(UInt8(cleaned[index..<next], radix: 16)!)
        index = next
    }
    return result
}

func hexLines(_ data: Data, width: Int = 32) -> [String] {
    stride(from: 0, to: data.count, by: width).map {
        data[$0..<min($0 + width, data.count)].map { String(format: "%02x", $0) }.joined()
    }
}

func makeReader(hex: String) -> TaggedBlockReader {
    TaggedBlockReader(data: hexData(hex))
}

func decodeFixtureBlocks(_ name: String) throws -> [SceneBlock] {
    try RMSceneDecoder().decodeBlocks(from: fixtureData(name))
}

func extractTextDocument(_ name: String) throws -> TextDocument {
    let tree = try RMSceneDecoder().decodeTree(from: fixtureData(name))
    guard let text = tree.rootText else {
        XCTFail("Missing root text for \(name)")
        return TextDocument(contents: [])
    }
    return try TextDocument.fromSceneItem(text)
}

func formattedLines(_ document: TextDocument) -> [FormattedParagraph] {
    document.contents.map { paragraph in
        let line = paragraph.contents.map { segment -> String in
            var value = segment.string
            if segment.style.fontWeight == .bold {
                value = "<b>\(value)</b>"
            }
            if segment.style.fontStyle == .italic {
                value = "<i>\(value)</i>"
            }
            return value
        }.joined()
        return FormattedParagraph(style: paragraph.style.value, line: line)
    }
}

extension Data {
    func replacingOccurrences(of target: Data, with replacement: Data) -> Data {
        guard !target.isEmpty else {
            return self
        }
        var result = self
        var searchStart = result.startIndex
        while let range = result.range(of: target, in: searchStart..<result.endIndex) {
            result.replaceSubrange(range, with: replacement)
            searchStart = range.lowerBound + replacement.count
            if searchStart > result.endIndex {
                break
            }
        }
        return result
    }
}
