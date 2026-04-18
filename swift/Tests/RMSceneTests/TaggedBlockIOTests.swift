import XCTest
@testable import RMScene

final class TaggedBlockIOTests: XCTestCase {
    func testWriteIDZero() throws {
        let writer = TaggedBlockWriter()
        try writer.writeID(index: 3, value: .zero)
        XCTAssertEqual(writer.encodedData.map { String(format: "%02x", $0) }.joined(), "3f0000")
    }

    func testWriteInt() throws {
        let writer = TaggedBlockWriter()
        try writer.writeInt(index: 3, value: 0xCDAB)
        XCTAssertEqual(writer.encodedData.map { String(format: "%02x", $0) }.joined(), "34abcd0000")
    }

    func testWriteBlock() throws {
        let writer = TaggedBlockWriter()
        try writer.withBlock(type: 5, minVersion: 1, currentVersion: 2) {
            try writer.writeInt(index: 3, value: 0x1234)
        }
        XCTAssertEqual(writer.encodedData.map { String(format: "%02x", $0) }.joined(), "05000000000102053434120000")
    }

    func testWriteBlockErrorIfNested() throws {
        let writer = TaggedBlockWriter()
        XCTAssertThrowsError(try writer.withBlock(type: 5, minVersion: 1, currentVersion: 2) {
            try writer.withBlock(type: 4, minVersion: 1, currentVersion: 1) {
                try writer.writeInt(index: 3, value: 0x1234)
            }
        }) { error in
            XCTAssertTrue(error is UnexpectedBlockError)
        }
    }

    func testWriteBlockErrorRecovery() throws {
        let writer = TaggedBlockWriter()
        do {
            try writer.withBlock(type: 5, minVersion: 1, currentVersion: 2) {
                try writer.writeInt(index: 3, value: 0x1234)
                throw NSError(domain: "test", code: 1)
            }
        } catch {}
        try writer.writeBool(index: 7, value: true)
        XCTAssertEqual(writer.encodedData.map { String(format: "%02x", $0) }.joined(), "7101")
    }

    func testWriteSubblock() throws {
        let writer = TaggedBlockWriter()
        try writer.withSubblock(index: 2) {
            try writer.writeInt(index: 3, value: 0x1234)
        }
        XCTAssertEqual(writer.encodedData.map { String(format: "%02x", $0) }.joined(), "2c050000003434120000")
    }

    func testWriteSubblockNested() throws {
        let writer = TaggedBlockWriter()
        try writer.withSubblock(index: 1) {
            try writer.withSubblock(index: 2) {
                try writer.writeInt(index: 3, value: 0x1234)
            }
        }
        XCTAssertEqual(writer.encodedData.map { String(format: "%02x", $0) }.joined(), "1c0a0000002c050000003434120000")
    }

    func testWriteSubblockErrorRecovery() throws {
        let writer = TaggedBlockWriter()
        do {
            try writer.withSubblock(index: 2) {
                try writer.writeInt(index: 3, value: 0x1234)
                throw NSError(domain: "test", code: 1)
            }
        } catch {}
        try writer.writeBool(index: 7, value: true)
        XCTAssertEqual(writer.encodedData.map { String(format: "%02x", $0) }.joined(), "7101")
    }

    func testReadBlock() throws {
        let reader = makeReader(hex: "0400000000010205ff00000000000000")
        let info = try XCTUnwrap(reader.nextBlockInfo())
        XCTAssertEqual(info.size, 4)
        XCTAssertEqual(info.blockType, 5)
        XCTAssertEqual(info.minVersion, 1)
        XCTAssertEqual(info.currentVersion, 2)
        XCTAssertEqual(info.offset, 8)
        XCTAssertEqual(try reader.data.readUInt32(), 0xFF)
        _ = try reader.finishCurrentBlock()
    }

    func testBytesRemainingInBlock() throws {
        let reader = makeReader(hex: "0400000000010205ff00000000000000")
        _ = try XCTUnwrap(reader.nextBlockInfo())
        XCTAssertEqual(try reader.bytesRemainingInBlock(), 4)
        _ = try reader.data.readUInt32()
        XCTAssertEqual(try reader.bytesRemainingInBlock(), 0)
        _ = try reader.finishCurrentBlock()
    }

    func testBlockOverflow() throws {
        let reader = makeReader(hex: "0400000000010205ff00000000000000")
        _ = try XCTUnwrap(reader.nextBlockInfo())
        _ = try reader.data.readUInt32()
        _ = try reader.data.readUInt32()
        XCTAssertThrowsError(try reader.finishCurrentBlock()) { error in
            XCTAssertTrue(error is BlockOverflowError)
        }
    }

    func testIncompleteBlockSkipsToEnd() throws {
        let reader = makeReader(hex: "0400000000010205ff00000000000000")
        _ = try XCTUnwrap(reader.nextBlockInfo())
        XCTAssertEqual(reader.data.tell(), 8)
        let info = try reader.finishCurrentBlock()
        XCTAssertEqual(reader.data.tell(), 12)
        XCTAssertEqual(info.extraData, Data([0xff, 0x00, 0x00, 0x00]))
    }

    func testErrorIfAlreadyInBlock() throws {
        let reader = makeReader(hex: "0400000000010205ff00000000000000")
        _ = try XCTUnwrap(reader.nextBlockInfo())
        XCTAssertThrowsError(try reader.nextBlockInfo())
    }

    func testReadSubblock() throws {
        let reader = makeReader(hex: "5c04000000ff00000000000000")
        let subblock = try reader.beginSubblock(index: 5)
        XCTAssertEqual(subblock.size, 4)
        XCTAssertEqual(try reader.data.readUInt32(), 0xFF)
        _ = try reader.finishSubblock(subblock)
    }

    func testHasSubblock() {
        let reader = makeReader(hex: "5c04000000ff00000000000000")
        XCTAssertTrue(reader.hasSubblock(index: 5))
        XCTAssertTrue(reader.hasSubblock(index: 5))
        XCTAssertFalse(reader.hasSubblock(index: 4))
    }

    func testHasSubblockReturnsFalseWithBadData() {
        let reader = makeReader(hex: "1d000000")
        XCTAssertFalse(reader.hasSubblock(index: 1))
        XCTAssertFalse(reader.hasSubblock(index: 6))
        XCTAssertEqual(reader.data.tell(), 0)
    }

    func testHasSubblockReturnsFalseAtEndOfFile() {
        let reader = makeReader(hex: "")
        XCTAssertFalse(reader.hasSubblock(index: 2))
    }

    func testHasSubblockChecksForEndOfBlock() throws {
        let reader = makeReader(hex: """
            0300000000010103
            1f0219
            2c00000000010100
            """)
        _ = try XCTUnwrap(reader.nextBlockInfo())
        _ = try reader.readID(index: 1)
        XCTAssertFalse(reader.hasSubblock(index: 2))
        _ = try reader.finishCurrentBlock()
    }

    func testReadIntAndOptional() throws {
        let reader = makeReader(hex: "34abcd0000")
        XCTAssertEqual(try reader.readInt(index: 3), 0xCDAB)

        let optionalReader = makeReader(hex: "34abcd0000")
        XCTAssertEqual(optionalReader.readIntOptional(index: 2, default: -1), -1)
        XCTAssertEqual(optionalReader.readIntOptional(index: 3), 0xCDAB)
        XCTAssertNil(optionalReader.readIntOptional(index: 4))
    }

    func testReadLWWString() throws {
        let reader = makeReader(hex: "1c0d0000001f01012c050000000301616263")
        let value = try reader.readLWWString(index: 1)
        XCTAssertEqual(value.timestamp, CrdtID(1, 1))
        XCTAssertEqual(value.value, "abc")
    }

    func testReadStringASCII() throws {
        let reader = makeReader(hex: "1c050000000301616263")
        XCTAssertEqual(try reader.readString(index: 1), "abc")
    }

    func testReadStringUTF8() throws {
        let reader = makeReader(hex: "1c05000000030161c397")
        XCTAssertEqual(try reader.readString(index: 1), "a×")
    }
}
