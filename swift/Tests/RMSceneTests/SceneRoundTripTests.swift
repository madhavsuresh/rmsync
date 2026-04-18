import XCTest
@testable import RMScene

final class SceneRoundTripTests: XCTestCase {
    private let fixturesAndVersions: [(String, RemarkableVersion)] = [
        ("Normal_AB.rm", "3.0"),
        ("Normal_A_stroke_2_layers.rm", "3.0"),
        ("Normal_A_stroke_2_layers_v3.2.2.rm", "3.2.2"),
        ("Normal_A_stroke_2_layers_v3.3.2.rm", "3.3.2"),
        ("Bold_Heading_Bullet_Normal.rm", "3.0"),
        ("Lines_v2.rm", "3.1"),
        ("Lines_v2_updated.rm", "3.2"),
        ("Wikipedia_highlighted_p1.rm", "3.1"),
        ("Wikipedia_highlighted_p2.rm", "3.1"),
        ("With_SceneInfo_Block.rm", "3.4"),
        ("Color_and_tool_v3.14.4.rm", "3.14"),
        ("More_color_highlight_shader_v3.15.4.2.rm", "3.15"),
    ]

    func testFixtureRoundTrips() throws {
        let decoder = RMSceneDecoder()
        let encoder = RMSceneEncoder()
        for (name, version) in fixturesAndVersions {
            var input = try fixtureData(name)
            if version == "3.2.2" || version == "3.3.2" {
                input = input.replacingOccurrences(of: hexData("010205"), with: hexData("020205"))
            }
            let output = try encoder.encode(try decoder.decodeBlocks(from: input), version: version)
            XCTAssertEqual(hexLines(input), hexLines(output), "Round-trip mismatch for \(name)")
        }
    }

    func testFilesFullyParsed() throws {
        let decoder = RMSceneDecoder()
        for (name, _) in fixturesAndVersions {
            let blocks = try decoder.decodeBlocks(from: fixtureData(name))
            for block in blocks {
                if case .unreadable = block {
                    XCTFail("Unreadable block in \(name)")
                }
                XCTAssertEqual(extraData(of: block), Data(), "Unexpected extra data in \(name)")
                XCTAssertEqual(extraValueData(of: block), Data(), "Unexpected extra value data in \(name)")
            }
        }
    }

    func testBlocksRoundTrip() throws {
        let block = SceneBlock.sceneTree(SceneTreeBlock(treeID: CrdtID(0, 11), nodeID: .zero, isUpdate: true, parentID: SceneTree.rootID))
        let data = try RMSceneEncoder().encode([block], version: "3.1")
        XCTAssertEqual(try RMSceneDecoder().decodeBlocks(from: data), [block])
    }

    func testWriteBlocks() throws {
        let data = try RMSceneEncoder().encode([
            .migrationInfo(MigrationInfoBlock(migrationID: CrdtID(1, 1), isDevice: true)),
        ], version: "3.1")
        XCTAssertEqual(data.prefix(DataStream.headerV6.count), DataStream.headerV6)
        XCTAssertEqual(data.dropFirst(DataStream.headerV6.count).map { String(format: "%02x", $0) }.joined(), "05000000000101001f01012101")
    }

    func testBlocksKeepUnknownDataInMainBlock() throws {
        let dataHex = """
        2E0000000000010D
        1C06000000
          1F0000
          2F0000
        2C05000000
          1F00002101
        3C05000000
          1F00002101
        5C08000000
          7C05000050070000
        E1FF
        """
        let blocks = try RMSceneDecoder().decodeBlocks(from: DataStream.headerV6 + hexData(dataHex))
        guard case let .sceneInfo(block) = try XCTUnwrap(blocks.first) else {
            return XCTFail("Expected scene info block")
        }
        XCTAssertEqual(block.extraData, hexData("E1FF"))
    }

    func testBlocksKeepUnknownDataInValueSubblock() throws {
        let dataHex = """
        5900000000020205
        1f0219
        2f021e
        3f0000
        4f0000
        5400000000
        6c43000000
          03
          140f000000
          2400000000
          38000000000000f03f
          4400000000
          5c1c000000
             f8fe82c2f42a30c3030008000000b869
             83c2622d30c3000008000000
          6f0001
          7f010f
          8f0101
        """
        let blocks = try RMSceneDecoder().decodeBlocks(from: DataStream.headerV6 + hexData(dataHex))
        guard case let .sceneLineItem(block) = try XCTUnwrap(blocks.first) else {
            return XCTFail("Expected scene line item block")
        }
        XCTAssertEqual(block.extraValueData, hexData("8f0101"))
    }

    func testUnreadableBlockContainmentAndRoundTrip() throws {
        let dataHex = """
        0600000000010103
        1f0219
        aabbcc
        0500000000010100
        1f0219
        2101
        """
        let input = DataStream.headerV6 + hexData(dataHex)
        let blocks = try RMSceneDecoder().decodeBlocks(from: input)
        XCTAssertEqual(blocks.count, 2)
        guard case let .unreadable(unreadable) = blocks[0] else {
            return XCTFail("Expected unreadable block")
        }
        XCTAssertEqual(unreadable.data, hexData("1f0219aabbcc"))
        let output = try RMSceneEncoder().encode(blocks, version: "3.0")
        XCTAssertEqual(output, input)
    }

    func testSimpleTextDocumentMatchesFixture() throws {
        let output = try RMSceneEncoder().encode(
            RMSceneEncoder().simpleTextDocument("AB", authorID: UUID(uuidString: "495ba59f-c943-2b5c-b455-3682f6948906")),
            version: "3.0"
        )
        XCTAssertEqual(hexLines(output), hexLines(try fixtureData("Normal_AB.rm")))
    }

    private func extraData(of block: SceneBlock) -> Data {
        switch block {
        case let .unreadable(value): return value.extraData
        case let .sceneInfo(value): return value.extraData
        case let .authorIDs(value): return value.extraData
        case let .migrationInfo(value): return value.extraData
        case let .treeNode(value): return value.extraData
        case let .pageInfo(value): return value.extraData
        case let .sceneTree(value): return value.extraData
        case let .sceneGlyphItem(value): return value.extraData
        case let .sceneGroupItem(value): return value.extraData
        case let .sceneLineItem(value): return value.extraData
        case let .sceneTextItem(value): return value.extraData
        case let .sceneTombstoneItem(value): return value.extraData
        case let .rootText(value): return value.extraData
        }
    }

    private func extraValueData(of block: SceneBlock) -> Data {
        switch block {
        case let .sceneGlyphItem(value): return value.extraValueData
        case let .sceneGroupItem(value): return value.extraValueData
        case let .sceneLineItem(value): return value.extraValueData
        case let .sceneTextItem(value): return value.extraValueData
        case let .sceneTombstoneItem(value): return value.extraValueData
        default: return Data()
        }
    }
}
