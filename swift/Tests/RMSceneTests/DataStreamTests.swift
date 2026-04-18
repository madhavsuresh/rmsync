import XCTest
@testable import RMScene

final class DataStreamTests: XCTestCase {
    func testWriteUInt8() {
        let stream = DataStream()
        stream.writeUInt8(3)
        XCTAssertEqual(stream.rawData.map { String(format: "%02x", $0) }.joined(), "03")
    }

    func testWriteVarUInt() throws {
        let samples: [(Int, String)] = [
            (0x00, "00"),
            (0x03, "03"),
            (0x7f, "7f"),
            (0x8c, "8c01"),
            (0x9c, "9c01"),
            (0x3fff, "ff7f"),
        ]

        for (value, expected) in samples {
            let stream = DataStream()
            try stream.writeVarUInt(value)
            XCTAssertEqual(stream.rawData.map { String(format: "%02x", $0) }.joined(), expected)
            stream.seek(0)
            XCTAssertEqual(try stream.readVarUInt(), value)
        }
    }
}
