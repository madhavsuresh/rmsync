import XCTest
@testable import RMScene

final class TextAndFixtureTests: XCTestCase {
    private func cid(_ value: Int) -> CrdtID {
        CrdtID(value == 0 ? 0 : 1, value)
    }

    private func makeTextItem(_ itemID: Int, _ leftID: Int, _ rightID: Int, _ deletedLength: Int, _ value: TextItemValue) -> CrdtSequenceItem<TextItemValue> {
        CrdtSequenceItem(itemID: cid(itemID), leftID: cid(leftID), rightID: cid(rightID), deletedLength: deletedLength, value: value)
    }

    func testExpandText1() {
        let result = expandTextItem(makeTextItem(17, 0, 0, 0, .string("AAAA")))
        XCTAssertEqual(result, [
            makeTextItem(17, 0, 18, 0, .string("A")),
            makeTextItem(18, 17, 19, 0, .string("A")),
            makeTextItem(19, 18, 20, 0, .string("A")),
            makeTextItem(20, 19, 0, 0, .string("A")),
        ])
    }

    func testExpandTextWithNewline() {
        let result = expandTextItem(makeTextItem(21, 20, 0, 0, .string("A\nB")))
        XCTAssertEqual(result, [
            makeTextItem(21, 20, 22, 0, .string("A")),
            makeTextItem(22, 21, 23, 0, .string("\n")),
            makeTextItem(23, 22, 0, 0, .string("B")),
        ])
    }

    func testExpandDeletedText() {
        let result = expandTextItem(makeTextItem(21, 20, 0, 2, .string("")))
        XCTAssertEqual(result, [
            makeTextItem(21, 20, 22, 1, .string("")),
            makeTextItem(22, 21, 0, 1, .string("")),
        ])
    }

    func testInlineFormattingAcrossParagraphs() throws {
        let document = try TextDocument.fromSceneItem(Text(
            items: CrdtSequence([
                makeTextItem(20, 0, 0, 0, .string("A")),
                makeTextItem(21, 20, 0, 0, .string("B\nC")),
                makeTextItem(24, 23, 0, 0, .string("D")),
                makeTextItem(30, 20, 21, 0, .formatCode(3)),
                makeTextItem(31, 23, 24, 0, .formatCode(4)),
            ]),
            styles: OrderedMap(),
            posX: -468.0,
            posY: 234.0,
            width: 936.0
        ))

        XCTAssertEqual(formattedLines(document), [
            FormattedParagraph(style: .plain, line: "A<i>B</i>"),
            FormattedParagraph(style: .plain, line: "<i>C</i>D"),
        ])
    }

    func testInlineFormattingBoldItalicInterleaved() throws {
        let document = try TextDocument.fromSceneItem(Text(
            items: CrdtSequence([
                makeTextItem(20, 0, 0, 0, .string("ABC\nDEF")),
                makeTextItem(30, 20, 21, 0, .formatCode(3)),
                makeTextItem(31, 21, 22, 0, .formatCode(1)),
                makeTextItem(32, 24, 25, 0, .formatCode(4)),
                makeTextItem(33, 25, 26, 0, .formatCode(2)),
            ]),
            styles: OrderedMap(),
            posX: -468.0,
            posY: 234.0,
            width: 936.0
        ))

        XCTAssertEqual(formattedLines(document), [
            FormattedParagraph(style: .plain, line: "A<i>B</i><i><b>C</b></i>"),
            FormattedParagraph(style: .plain, line: "<i><b>D</b></i><b>E</b>F"),
        ])
    }

    func testNormalABFixture() throws {
        XCTAssertEqual(formattedLines(try extractTextDocument("Normal_AB.rm")), [
            FormattedParagraph(style: .plain, line: "AB")
        ])
    }

    func testListFixture() throws {
        XCTAssertEqual(formattedLines(try extractTextDocument("Bold_Heading_Bullet_Normal.rm")), [
            FormattedParagraph(style: .bold, line: "A"),
            FormattedParagraph(style: .heading, line: "new line"),
            FormattedParagraph(style: .bullet, line: "B is a letter of the alphabet"),
            FormattedParagraph(style: .plain, line: "C"),
        ])
    }

    func testInlineFormatsFixture() throws {
        XCTAssertEqual(formattedLines(try extractTextDocument("Normal_A_stroke_2_layers_v3.3.2.rm")), [
            FormattedParagraph(style: .plain, line: "A"),
            FormattedParagraph(style: .plain, line: "v3.2.2"),
            FormattedParagraph(style: .plain, line: "Normal <b>bold</b> <i>italic</i>"),
            FormattedParagraph(style: .plain, line: "<b>Bold</b> <i>italic</i> normal"),
            FormattedParagraph(style: .bold, line: "Bold line"),
            FormattedParagraph(style: .plain, line: "Normal line"),
            FormattedParagraph(style: .heading, line: "Heading line"),
        ])
    }

    func testConcurrentAuthorOrderingFixture() throws {
        XCTAssertEqual(formattedLines(try extractTextDocument("test-crdt-ordering.rm")), [
            FormattedParagraph(style: .heading, line: "A12_Z")
        ])
    }

    func testSceneInfoPaperSize() throws {
        let tree = try RMSceneDecoder().decodeTree(from: fixtureData("Color_and_tool_v3.14.4.rm"))
        XCTAssertEqual(tree.sceneInfo?.paperSize?.0, 1620)
        XCTAssertEqual(tree.sceneInfo?.paperSize?.1, 2160)
    }

    func testColorToolParsing() throws {
        let blocks = try decodeFixtureBlocks("Color_and_tool_v3.14.4.rm")
        XCTAssertTrue(blocks.contains {
            if case let .sceneGlyphItem(block) = $0, block.item.value?.color == .highlight {
                return true
            }
            return false
        })
        XCTAssertTrue(blocks.contains {
            if case let .sceneLineItem(block) = $0, let value = block.item.value {
                return value.color == .highlight && value.tool == .shader
            }
            return false
        })
        XCTAssertTrue(blocks.contains {
            if case let .sceneLineItem(block) = $0, let value = block.item.value {
                return [.green2, .cyan, .magenta].contains(value.color) && value.tool == .ballpoint2
            }
            return false
        })
    }
}
