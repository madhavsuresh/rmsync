import XCTest
@testable import RMScene

final class CrdtSequenceTests: XCTestCase {
    private func cid(_ value: Int) -> CrdtID {
        CrdtID(value == 0 ? 0 : 1, value)
    }

    private func makeItem(_ itemID: Int, _ leftID: Int, _ rightID: Int, _ deletedLength: Int, _ value: String) -> CrdtSequenceItem<String> {
        CrdtSequenceItem(itemID: cid(itemID), leftID: cid(leftID), rightID: cid(rightID), deletedLength: deletedLength, value: value)
    }

    func testEmpty() throws {
        XCTAssertEqual(try CrdtSequence<String>().idsInOrder(), [])
    }

    func testJustOne() throws {
        let sequence = CrdtSequence([makeItem(1, 0, 0, 0, "A")])
        XCTAssertEqual(try sequence.idsInOrder(), [cid(1)])
    }

    func testTwo() throws {
        let items = [
            makeItem(1, 0, 0, 0, "A"),
            makeItem(2, 1, 0, 0, "B"),
        ]
        XCTAssertEqual(try CrdtSequence(items).idsInOrder(), try CrdtSequence(items.reversed()).idsInOrder())
    }

    func testOverlappingConcurrentInsertOrdering() throws {
        let a = CrdtSequenceItem(itemID: CrdtID(1, 1), leftID: .zero, rightID: .zero, deletedLength: 0, value: "A")
        let z = CrdtSequenceItem(itemID: CrdtID(1, 2), leftID: CrdtID(1, 1), rightID: .zero, deletedLength: 0, value: "Z")
        let author2 = CrdtSequenceItem(itemID: CrdtID(2, 1), leftID: CrdtID(1, 1), rightID: CrdtID(1, 2), deletedLength: 0, value: "12")
        let author1 = CrdtSequenceItem(itemID: CrdtID(1, 3), leftID: CrdtID(1, 1), rightID: CrdtID(1, 2), deletedLength: 0, value: "_")
        let items = [a, z, author2, author1]
        let sequence = CrdtSequence(items)
        XCTAssertEqual(try sequence.idsInOrder(), [CrdtID(1, 1), CrdtID(2, 1), CrdtID(1, 3), CrdtID(1, 2)])
        XCTAssertEqual(try sequence.valuesInOrder().joined(), "A12_Z")
        XCTAssertEqual(try sequence.idsInOrder(), try CrdtSequence(items.reversed()).idsInOrder())
    }

    func testUnknownID() throws {
        let items = [
            makeItem(28, 0, 15, 0, "A"),
            makeItem(31, 30, 15, 2, ""),
            makeItem(33, 32, 15, 0, "B"),
            makeItem(15, 0, 0, 0, "C"),
        ]
        XCTAssertEqual(try CrdtSequence(items).idsInOrder(), [cid(28), cid(31), cid(33), cid(15)])
    }

    func testUnknownIDAtRight() throws {
        let items = [
            makeItem(14, 0, 0, 0, "A"),
            makeItem(19, 14, 15, 0, "V"),
        ]
        XCTAssertEqual(try CrdtSequence(items).idsInOrder(), [cid(14), cid(19)])
    }

    func testIteratesInOrder() throws {
        let items = [
            makeItem(1, 0, 0, 0, "A"),
            makeItem(2, 1, 0, 0, "B"),
        ]
        for permutation in [items, Array(items.reversed())] {
            let sequence = CrdtSequence(permutation)
            XCTAssertEqual(try sequence.idsInOrder(), [cid(1), cid(2)])
            XCTAssertEqual(try sequence.valuesInOrder(), ["A", "B"])
        }
    }
}
