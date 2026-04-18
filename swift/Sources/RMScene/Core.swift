import Foundation

public struct RemarkableVersion: Hashable, Comparable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    private let components: [Int]

    public init(_ rawValue: String) {
        self.rawValue = rawValue
        let parsed = rawValue.split(separator: ".").map { Int($0) ?? 0 }
        self.components = Self.normalized(parsed.isEmpty ? [0] : parsed)
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public var description: String {
        rawValue
    }

    public static func < (lhs: RemarkableVersion, rhs: RemarkableVersion) -> Bool {
        let maxCount = max(lhs.components.count, rhs.components.count)
        for index in 0..<maxCount {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }

    private static func normalized(_ components: [Int]) -> [Int] {
        var components = components
        while components.count > 1, components.last == 0 {
            components.removeLast()
        }
        return components
    }
}

public struct UnexpectedBlockError: Error, Equatable, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

public struct BlockOverflowError: Error, Equatable, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

public enum RMSceneFormatError: Error, Equatable, LocalizedError {
    case wrongHeader(Data)
    case badTagType(Int, position: Int)
    case invalidValue(String)
    case eof
    case cyclicDependency
    case utf8DecodingFailed(Data)

    public var errorDescription: String? {
        switch self {
        case let .wrongHeader(header):
            return "Wrong header: \(header as NSData)"
        case let .badTagType(tagType, position):
            return String(format: "Bad tag type 0x%X at position %d", tagType, position)
        case let .invalidValue(message):
            return message
        case .eof:
            return "Unexpected end of file"
        case .cyclicDependency:
            return "cyclic dependency"
        case let .utf8DecodingFailed(data):
            return "Failed to decode UTF-8 string from \(data as NSData)"
        }
    }
}

public struct CrdtID: Hashable, Comparable, CustomStringConvertible, Sendable {
    public let part1: Int
    public let part2: Int

    public init(_ part1: Int, _ part2: Int) {
        self.part1 = part1
        self.part2 = part2
    }

    public static let zero = CrdtID(0, 0)

    public static func < (lhs: CrdtID, rhs: CrdtID) -> Bool {
        if lhs.part1 != rhs.part1 {
            return lhs.part1 < rhs.part1
        }
        return lhs.part2 < rhs.part2
    }

    public var description: String {
        "CrdtID(\(part1), \(part2))"
    }
}

public struct LWWValue<Value> {
    public var timestamp: CrdtID
    public var value: Value

    public init(timestamp: CrdtID, value: Value) {
        self.timestamp = timestamp
        self.value = value
    }
}

extension LWWValue: Equatable where Value: Equatable {}

public struct RGBAColor: Equatable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    public var alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

public enum TagType: Int {
    case id = 0xF
    case length4 = 0xC
    case byte8 = 0x8
    case byte4 = 0x4
    case byte1 = 0x1
}

public struct MainBlockInfo: Equatable {
    public var offset: Int
    public var size: Int
    public var extraData: Data
    public var blockType: Int
    public var minVersion: Int
    public var currentVersion: Int

    public init(offset: Int, size: Int, extraData: Data = Data(), blockType: Int, minVersion: Int, currentVersion: Int) {
        self.offset = offset
        self.size = size
        self.extraData = extraData
        self.blockType = blockType
        self.minVersion = minVersion
        self.currentVersion = currentVersion
    }
}

public struct SubBlockInfo: Equatable {
    public var offset: Int
    public var size: Int
    public var extraData: Data

    public init(offset: Int, size: Int, extraData: Data = Data()) {
        self.offset = offset
        self.size = size
        self.extraData = extraData
    }
}

public final class DataStream {
    public static let headerV6 = Data("reMarkable .lines file, version=6          ".utf8)

    private(set) var storage: Data
    private var offset: Int

    public init(_ data: Data = Data()) {
        self.storage = data
        self.offset = 0
    }

    public var rawData: Data {
        storage
    }

    public func tell() -> Int {
        offset
    }

    public func seek(_ position: Int) {
        offset = position
    }

    public func readHeader() throws {
        let header = try readBytes(DataStream.headerV6.count)
        guard header == DataStream.headerV6 else {
            throw RMSceneFormatError.wrongHeader(header)
        }
    }

    public func writeHeader() {
        writeBytes(DataStream.headerV6)
    }

    public func checkTag(expectedIndex: Int, expectedType: TagType) -> Bool {
        let position = offset
        defer { offset = position }
        do {
            let (index, tagType) = try readTagValues()
            return index == expectedIndex && tagType == expectedType
        } catch {
            return false
        }
    }

    @discardableResult
    public func readTag(expectedIndex: Int, expectedType: TagType) throws -> (Int, TagType) {
        let position = offset
        let (index, tagType) = try readTagValues()
        if index != expectedIndex {
            offset = position
            throw UnexpectedBlockError("Expected index \(expectedIndex), got \(index), at position \(offset)")
        }
        if tagType != expectedType {
            offset = position
            let typeName = String(describing: expectedType).capitalized
            throw UnexpectedBlockError(String(format: "Expected tag type %@ (0x%X), got 0x%X at position %d", typeName, expectedType.rawValue, tagType.rawValue, offset))
        }
        return (index, tagType)
    }

    public func writeTag(index: Int, tagType: TagType) throws {
        try writeVarUInt((index << 4) | tagType.rawValue)
    }

    public func readBytes(_ count: Int) throws -> Data {
        guard offset + count <= storage.count else {
            throw RMSceneFormatError.eof
        }
        let result = storage.subdata(in: offset..<(offset + count))
        offset += count
        return result
    }

    public func writeBytes(_ data: Data) {
        if offset == storage.count {
            storage.append(data)
            offset += data.count
            return
        }

        let end = offset + data.count
        if end <= storage.count {
            storage.replaceSubrange(offset..<end, with: data)
        } else {
            storage.replaceSubrange(offset..<storage.count, with: data.prefix(storage.count - offset))
            storage.append(data.suffix(end - storage.count))
        }
        offset = end
    }

    public func readBool() throws -> Bool {
        try readUInt8() != 0
    }

    public func readUInt8() throws -> UInt8 {
        let data = try readBytes(1)
        return data[data.startIndex]
    }

    public func readUInt16() throws -> UInt16 {
        let data = try readBytes(2)
        return UInt16(data[data.startIndex]) | (UInt16(data[data.startIndex + 1]) << 8)
    }

    public func readUInt32() throws -> UInt32 {
        let data = try readBytes(4)
        var value: UInt32 = 0
        for (index, byte) in data.enumerated() {
            value |= UInt32(byte) << (UInt32(index) * 8)
        }
        return value
    }

    public func readFloat32() throws -> Double {
        Double(Float(bitPattern: try readUInt32()))
    }

    public func readFloat64() throws -> Double {
        let data = try readBytes(8)
        var value: UInt64 = 0
        for (index, byte) in data.enumerated() {
            value |= UInt64(byte) << (UInt64(index) * 8)
        }
        return Double(bitPattern: value)
    }

    public func readVarUInt() throws -> Int {
        var shift = 0
        var result = 0
        while true {
            let value = Int(try readUInt8())
            result |= (value & 0x7F) << shift
            shift += 7
            if (value & 0x80) == 0 {
                break
            }
        }
        return result
    }

    public func readCrdtID() throws -> CrdtID {
        let part1 = Int(try readUInt8())
        let part2 = try readVarUInt()
        return CrdtID(part1, part2)
    }

    public func writeBool(_ value: Bool) {
        writeUInt8(value ? 1 : 0)
    }

    public func writeUInt8(_ value: UInt8) {
        writeBytes(Data([value]))
    }

    public func writeUInt16(_ value: UInt16) {
        writeBytes(Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
        ]))
    }

    public func writeUInt32(_ value: UInt32) {
        writeBytes(Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ]))
    }

    public func writeFloat32(_ value: Double) {
        writeUInt32(Float(value).bitPattern)
    }

    public func writeFloat64(_ value: Double) {
        let bitPattern = value.bitPattern
        writeBytes(Data([
            UInt8(bitPattern & 0xFF),
            UInt8((bitPattern >> 8) & 0xFF),
            UInt8((bitPattern >> 16) & 0xFF),
            UInt8((bitPattern >> 24) & 0xFF),
            UInt8((bitPattern >> 32) & 0xFF),
            UInt8((bitPattern >> 40) & 0xFF),
            UInt8((bitPattern >> 48) & 0xFF),
            UInt8((bitPattern >> 56) & 0xFF),
        ]))
    }

    public func writeVarUInt(_ value: Int) throws {
        guard value >= 0 else {
            throw RMSceneFormatError.invalidValue("value is negative")
        }
        var remainder = value
        var bytes = [UInt8]()
        while true {
            let toWrite = UInt8(remainder & 0x7F)
            remainder >>= 7
            if remainder != 0 {
                bytes.append(toWrite | 0x80)
            } else {
                bytes.append(toWrite)
                break
            }
        }
        writeBytes(Data(bytes))
    }

    public func writeCrdtID(_ value: CrdtID) throws {
        guard value.part1 < (1 << 8), value.part2 >= 0 else {
            throw RMSceneFormatError.invalidValue("CrdtID too large: \(value)")
        }
        writeUInt8(UInt8(value.part1))
        try writeVarUInt(value.part2)
    }

    private func readTagValues() throws -> (Int, TagType) {
        let rawValue = try readVarUInt()
        let index = rawValue >> 4
        let typeValue = rawValue & 0xF
        guard let tagType = TagType(rawValue: typeValue) else {
            throw RMSceneFormatError.badTagType(typeValue, position: offset)
        }
        return (index, tagType)
    }
}

public final class TaggedBlockReader {
    public let data: DataStream
    public private(set) var currentBlock: MainBlockInfo?

    private var warnedAboutExtraData = false

    public init(data: Data) {
        self.data = DataStream(data)
    }

    public func readHeader() throws {
        try data.readHeader()
    }

    public func readID(index: Int) throws -> CrdtID {
        try data.readTag(expectedIndex: index, expectedType: .id)
        return try data.readCrdtID()
    }

    public func readBool(index: Int) throws -> Bool {
        try data.readTag(expectedIndex: index, expectedType: .byte1)
        return try data.readBool()
    }

    public func readByte(index: Int) throws -> Int {
        try data.readTag(expectedIndex: index, expectedType: .byte1)
        return Int(try data.readUInt8())
    }

    public func readInt(index: Int) throws -> Int {
        try data.readTag(expectedIndex: index, expectedType: .byte4)
        return Int(try data.readUInt32())
    }

    public func readFloat(index: Int) throws -> Double {
        try data.readTag(expectedIndex: index, expectedType: .byte4)
        return try data.readFloat32()
    }

    public func readDouble(index: Int) throws -> Double {
        try data.readTag(expectedIndex: index, expectedType: .byte8)
        return try data.readFloat64()
    }

    public func readIDOptional(index: Int, default defaultValue: CrdtID? = nil) -> CrdtID? {
        optional(default: defaultValue) { try readID(index: index) }
    }

    public func readBoolOptional(index: Int, default defaultValue: Bool? = nil) -> Bool? {
        optional(default: defaultValue) { try readBool(index: index) }
    }

    public func readByteOptional(index: Int, default defaultValue: Int? = nil) -> Int? {
        optional(default: defaultValue) { try readByte(index: index) }
    }

    public func readIntOptional(index: Int, default defaultValue: Int? = nil) -> Int? {
        optional(default: defaultValue) { try readInt(index: index) }
    }

    public func readFloatOptional(index: Int, default defaultValue: Double? = nil) -> Double? {
        optional(default: defaultValue) { try readFloat(index: index) }
    }

    public func readDoubleOptional(index: Int, default defaultValue: Double? = nil) -> Double? {
        optional(default: defaultValue) { try readDouble(index: index) }
    }

    public func readColorOptional(index: Int) -> RGBAColor? {
        guard data.checkTag(expectedIndex: index, expectedType: .byte4) else {
            return nil
        }
        guard let packed = try? readInt(index: index) else {
            return nil
        }
        return RGBAColor(
            red: UInt8((packed >> 16) & 0xFF),
            green: UInt8((packed >> 8) & 0xFF),
            blue: UInt8(packed & 0xFF),
            alpha: UInt8((packed >> 24) & 0xFF)
        )
    }

    public func nextBlockInfo() throws -> MainBlockInfo? {
        guard currentBlock == nil else {
            throw UnexpectedBlockError("Already in a block")
        }

        do {
            let blockLength = Int(try data.readUInt32())
            let unknown = try data.readUInt8()
            let minVersion = Int(try data.readUInt8())
            let currentVersion = Int(try data.readUInt8())
            let blockType = Int(try data.readUInt8())
            guard unknown == 0, minVersion <= currentVersion else {
                throw RMSceneFormatError.invalidValue("Invalid main block header")
            }
            let info = MainBlockInfo(
                offset: data.tell(),
                size: blockLength,
                extraData: Data(),
                blockType: blockType,
                minVersion: minVersion,
                currentVersion: currentVersion
            )
            currentBlock = info
            return info
        } catch RMSceneFormatError.eof {
            return nil
        }
    }

    public func finishCurrentBlock() throws -> MainBlockInfo {
        guard var blockInfo = currentBlock else {
            throw RMSceneFormatError.invalidValue("Not in a block")
        }
        try checkPosition(offset: blockInfo.offset, size: blockInfo.size, extraData: &blockInfo.extraData)
        currentBlock = nil
        return blockInfo
    }

    public func bytesRemainingInBlock() throws -> Int {
        guard let blockInfo = currentBlock else {
            throw RMSceneFormatError.invalidValue("Not in a block")
        }
        return blockInfo.offset + blockInfo.size - data.tell()
    }

    public func beginSubblock(index: Int) throws -> SubBlockInfo {
        try data.readTag(expectedIndex: index, expectedType: .length4)
        let length = Int(try data.readUInt32())
        return SubBlockInfo(offset: data.tell(), size: length, extraData: Data())
    }

    public func finishSubblock(_ info: SubBlockInfo) throws -> SubBlockInfo {
        var info = info
        try checkPosition(offset: info.offset, size: info.size, extraData: &info.extraData)
        return info
    }

    public func hasSubblock(index: Int) -> Bool {
        if let currentBlock = currentBlock, data.tell() >= currentBlock.offset + currentBlock.size {
            return false
        }
        return data.checkTag(expectedIndex: index, expectedType: .length4)
    }

    public func readLWWBool(index: Int) throws -> LWWValue<Bool> {
        let subblock = try beginSubblock(index: index)
        let timestamp = try readID(index: 1)
        let value = try readBool(index: 2)
        _ = try finishSubblock(subblock)
        return LWWValue(timestamp: timestamp, value: value)
    }

    public func readLWWByte(index: Int) throws -> LWWValue<Int> {
        let subblock = try beginSubblock(index: index)
        let timestamp = try readID(index: 1)
        let value = try readByte(index: 2)
        _ = try finishSubblock(subblock)
        return LWWValue(timestamp: timestamp, value: value)
    }

    public func readLWWFloat(index: Int) throws -> LWWValue<Double> {
        let subblock = try beginSubblock(index: index)
        let timestamp = try readID(index: 1)
        let value = try readFloat(index: 2)
        _ = try finishSubblock(subblock)
        return LWWValue(timestamp: timestamp, value: value)
    }

    public func readLWWID(index: Int) throws -> LWWValue<CrdtID> {
        let subblock = try beginSubblock(index: index)
        let timestamp = try readID(index: 1)
        let value = try readID(index: 2)
        _ = try finishSubblock(subblock)
        return LWWValue(timestamp: timestamp, value: value)
    }

    public func readLWWString(index: Int) throws -> LWWValue<String> {
        let subblock = try beginSubblock(index: index)
        let timestamp = try readID(index: 1)
        let string = try readString(index: 2)
        _ = try finishSubblock(subblock)
        return LWWValue(timestamp: timestamp, value: string)
    }

    public func readString(index: Int) throws -> String {
        let subblock = try beginSubblock(index: index)
        let stringLength = try data.readVarUInt()
        let isASCII = try data.readBool()
        guard isASCII, stringLength + 2 <= subblock.size else {
            throw RMSceneFormatError.invalidValue("Invalid string block")
        }
        let bytes = try data.readBytes(stringLength)
        guard let string = String(data: bytes, encoding: .utf8) else {
            throw RMSceneFormatError.utf8DecodingFailed(bytes)
        }
        _ = try finishSubblock(subblock)
        return string
    }

    public func readStringWithFormat(index: Int) throws -> (String, Int?) {
        let subblock = try beginSubblock(index: index)
        let stringLength = try data.readVarUInt()
        let isASCII = try data.readBool()
        guard isASCII, stringLength + 2 <= subblock.size else {
            throw RMSceneFormatError.invalidValue("Invalid string block")
        }
        let bytes = try data.readBytes(stringLength)
        guard let string = String(data: bytes, encoding: .utf8) else {
            throw RMSceneFormatError.utf8DecodingFailed(bytes)
        }
        let format = data.checkTag(expectedIndex: 2, expectedType: .byte4) ? try readInt(index: 2) : nil
        _ = try finishSubblock(subblock)
        return (string, format)
    }

    public func readIntPair(index: Int) throws -> (Int, Int) {
        let subblock = try beginSubblock(index: index)
        let first = Int(try data.readUInt32())
        let second = Int(try data.readUInt32())
        _ = try finishSubblock(subblock)
        return (first, second)
    }

    private func optional<T>(default defaultValue: T?, _ read: () throws -> T) -> T? {
        do {
            return try read()
        } catch is UnexpectedBlockError {
            return defaultValue
        } catch RMSceneFormatError.eof {
            return defaultValue
        } catch {
            return defaultValue
        }
    }

    private func checkPosition(offset: Int, size: Int, extraData: inout Data) throws {
        let current = data.tell()
        if current > offset + size {
            throw BlockOverflowError("\(offset) length \(size) overflow by \(current - (offset + size))")
        }
        if current < offset + size {
            if !warnedAboutExtraData {
                warnedAboutExtraData = true
            }
            let remaining = offset + size - current
            extraData = try data.readBytes(remaining)
        }
    }
}

public final class TaggedBlockWriter {
    public private(set) var data: DataStream
    public var version: RemarkableVersion?

    private var inBlock = false

    public init(data: Data = Data(), version: RemarkableVersion? = nil) {
        self.data = DataStream(data)
        self.version = version
    }

    public var encodedData: Data {
        data.rawData
    }

    public func writeHeader() {
        data.writeHeader()
    }

    public func writeID(index: Int, value: CrdtID) throws {
        try data.writeTag(index: index, tagType: .id)
        try data.writeCrdtID(value)
    }

    public func writeBool(index: Int, value: Bool) throws {
        try data.writeTag(index: index, tagType: .byte1)
        data.writeBool(value)
    }

    public func writeByte(index: Int, value: Int) throws {
        try data.writeTag(index: index, tagType: .byte1)
        data.writeUInt8(UInt8(value))
    }

    public func writeInt(index: Int, value: Int) throws {
        try data.writeTag(index: index, tagType: .byte4)
        data.writeUInt32(UInt32(value))
    }

    public func writeFloat(index: Int, value: Double) throws {
        try data.writeTag(index: index, tagType: .byte4)
        data.writeFloat32(value)
    }

    public func writeDouble(index: Int, value: Double) throws {
        try data.writeTag(index: index, tagType: .byte8)
        data.writeFloat64(value)
    }

    public func writeColor(index: Int, value: RGBAColor) throws {
        let packed = Int(value.blue) | (Int(value.green) << 8) | (Int(value.red) << 16) | (Int(value.alpha) << 24)
        try writeInt(index: index, value: packed)
    }

    @discardableResult
    public func withBlock<T>(type blockType: Int, minVersion: Int, currentVersion: Int, _ body: () throws -> T) throws -> T {
        guard !inBlock else {
            throw UnexpectedBlockError("Already in a block")
        }

        let previous = data
        let blockStream = DataStream()
        data = blockStream
        inBlock = true

        do {
            let result = try body()
            data = previous
            inBlock = false
            previous.writeUInt32(UInt32(blockStream.rawData.count))
            previous.writeUInt8(0)
            previous.writeUInt8(UInt8(minVersion))
            previous.writeUInt8(UInt8(currentVersion))
            previous.writeUInt8(UInt8(blockType))
            previous.writeBytes(blockStream.rawData)
            return result
        } catch {
            data = previous
            inBlock = false
            throw error
        }
    }

    @discardableResult
    public func withSubblock<T>(index: Int, _ body: () throws -> T) throws -> T {
        let previous = data
        let subblockStream = DataStream()
        data = subblockStream

        do {
            let result = try body()
            data = previous
            try previous.writeTag(index: index, tagType: .length4)
            previous.writeUInt32(UInt32(subblockStream.rawData.count))
            previous.writeBytes(subblockStream.rawData)
            return result
        } catch {
            data = previous
            throw error
        }
    }

    public func writeLWWBool(index: Int, value: LWWValue<Bool>) throws {
        try withSubblock(index: index) {
            try writeID(index: 1, value: value.timestamp)
            try writeBool(index: 2, value: value.value)
        }
    }

    public func writeLWWByte(index: Int, value: LWWValue<Int>) throws {
        try withSubblock(index: index) {
            try writeID(index: 1, value: value.timestamp)
            try writeByte(index: 2, value: value.value)
        }
    }

    public func writeLWWFloat(index: Int, value: LWWValue<Double>) throws {
        try withSubblock(index: index) {
            try writeID(index: 1, value: value.timestamp)
            try writeFloat(index: 2, value: value.value)
        }
    }

    public func writeLWWID(index: Int, value: LWWValue<CrdtID>) throws {
        try withSubblock(index: index) {
            try writeID(index: 1, value: value.timestamp)
            try writeID(index: 2, value: value.value)
        }
    }

    public func writeLWWString(index: Int, value: LWWValue<String>) throws {
        try withSubblock(index: index) {
            try writeID(index: 1, value: value.timestamp)
            try writeString(index: 2, value: value.value)
        }
    }

    public func writeString(index: Int, value: String) throws {
        try withSubblock(index: index) {
            let encoded = Data(value.utf8)
            try data.writeVarUInt(encoded.count)
            data.writeBool(true)
            data.writeBytes(encoded)
        }
    }

    public func writeStringWithFormat(index: Int, text: String, format: Int) throws {
        try withSubblock(index: index) {
            let encoded = Data(text.utf8)
            try data.writeVarUInt(encoded.count)
            data.writeBool(true)
            data.writeBytes(encoded)
            try writeInt(index: 2, value: format)
        }
    }

    public func writeIntPair(index: Int, value: (Int, Int)) throws {
        try withSubblock(index: index) {
            data.writeUInt32(UInt32(value.0))
            data.writeUInt32(UInt32(value.1))
        }
    }
}

public struct OrderedMap<Key: Hashable, Value> {
    private var orderedPairsStorage: [(Key, Value)]
    private var indexes: [Key: Int]

    public init(_ pairs: [(Key, Value)] = []) {
        self.orderedPairsStorage = []
        self.indexes = [:]
        for (key, value) in pairs {
            self[key] = value
        }
    }

    public var orderedPairs: [(Key, Value)] {
        orderedPairsStorage
    }

    public var count: Int {
        orderedPairsStorage.count
    }

    public func contains(_ key: Key) -> Bool {
        indexes[key] != nil
    }

    public subscript(key: Key) -> Value? {
        get {
            guard let index = indexes[key] else {
                return nil
            }
            return orderedPairsStorage[index].1
        }
        set {
            if let newValue {
                if let index = indexes[key] {
                    orderedPairsStorage[index] = (key, newValue)
                } else {
                    indexes[key] = orderedPairsStorage.count
                    orderedPairsStorage.append((key, newValue))
                }
            } else if let index = indexes.removeValue(forKey: key) {
                orderedPairsStorage.remove(at: index)
                for itemIndex in index..<orderedPairsStorage.count {
                    indexes[orderedPairsStorage[itemIndex].0] = itemIndex
                }
            }
        }
    }
}

extension OrderedMap: Equatable where Key: Equatable, Value: Equatable {
    public static func == (lhs: OrderedMap<Key, Value>, rhs: OrderedMap<Key, Value>) -> Bool {
        guard lhs.orderedPairs.count == rhs.orderedPairs.count else {
            return false
        }
        for (left, right) in zip(lhs.orderedPairs, rhs.orderedPairs) {
            if left.0 != right.0 || left.1 != right.1 {
                return false
            }
        }
        return true
    }
}

public struct CrdtSequenceItem<Value> {
    public var itemID: CrdtID
    public var leftID: CrdtID
    public var rightID: CrdtID
    public var deletedLength: Int
    public var value: Value

    public init(itemID: CrdtID, leftID: CrdtID, rightID: CrdtID, deletedLength: Int, value: Value) {
        self.itemID = itemID
        self.leftID = leftID
        self.rightID = rightID
        self.deletedLength = deletedLength
        self.value = value
    }
}

extension CrdtSequenceItem: Equatable where Value: Equatable {}

public struct CrdtSequence<Value> {
    private var orderedItems: [CrdtSequenceItem<Value>]
    private var indexes: [CrdtID: Int]

    public init() {
        self.orderedItems = []
        self.indexes = [:]
    }

    public init<S: Sequence>(_ items: S) where S.Element == CrdtSequenceItem<Value> {
        self.orderedItems = []
        self.indexes = [:]
        for item in items {
            indexes[item.itemID] = orderedItems.count
            orderedItems.append(item)
        }
    }

    public mutating func add(_ item: CrdtSequenceItem<Value>) throws {
        guard indexes[item.itemID] == nil else {
            throw RMSceneFormatError.invalidValue("Already have item \(item.itemID)")
        }
        indexes[item.itemID] = orderedItems.count
        orderedItems.append(item)
    }

    public func sequenceItems() -> [CrdtSequenceItem<Value>] {
        orderedItems
    }

    public func idsInOrder() throws -> [CrdtID] {
        try toposortItems(orderedItems)
    }

    public func valuesInOrder() throws -> [Value] {
        try idsInOrder().map { self[$0] }
    }

    public func itemsInOrder() throws -> [(CrdtID, Value)] {
        try idsInOrder().map { ($0, self[$0]) }
    }

    public subscript(key: CrdtID) -> Value {
        orderedItems[indexes[key]!].value
    }

    fileprivate func item(for key: CrdtID) -> CrdtSequenceItem<Value>? {
        guard let index = indexes[key] else {
            return nil
        }
        return orderedItems[index]
    }
}

extension CrdtSequence: Equatable where Value: Equatable {}

private enum ToposortNode: Hashable {
    case start
    case end
    case id(CrdtID)
}

private func toposortItems<Value>(_ items: [CrdtSequenceItem<Value>]) throws -> [CrdtID] {
    guard !items.isEmpty else {
        return []
    }

    var itemMap: [CrdtID: CrdtSequenceItem<Value>] = [:]
    for item in items {
        itemMap[item.itemID] = item
    }

    func sideNode(for item: CrdtSequenceItem<Value>, side: String) -> ToposortNode {
        let sideID = side == "left" ? item.leftID : item.rightID
        if sideID == .zero || itemMap[sideID] == nil {
            return side == "left" ? .start : .end
        }
        return .id(sideID)
    }

    var inDegree: [ToposortNode: Int] = [:]
    var dependents: [ToposortNode: [ToposortNode]] = [:]
    var allNodes: Set<ToposortNode> = [.start, .end]

    for item in itemMap.values {
        let itemNode = ToposortNode.id(item.itemID)
        let leftNode = sideNode(for: item, side: "left")
        let rightNode = sideNode(for: item, side: "right")

        allNodes.insert(itemNode)
        allNodes.insert(leftNode)
        allNodes.insert(rightNode)

        inDegree[itemNode, default: 0] += 1
        dependents[leftNode, default: []].append(itemNode)

        inDegree[rightNode, default: 0] += 1
        dependents[itemNode, default: []].append(rightNode)
    }

    for node in allNodes where inDegree[node] == nil {
        inDegree[node] = 0
    }

    func sortKey(_ node: ToposortNode) -> (Int, Int, Int) {
        switch node {
        case .start:
            return (0, 0, 0)
        case .end:
            return (2, 0, 0)
        case let .id(id):
            return (1, -id.part1, id.part2)
        }
    }

    var ready = allNodes.filter { inDegree[$0] == 0 }.sorted { sortKey($0) < sortKey($1) }
    var result: [CrdtID] = []

    while !ready.isEmpty {
        let node = ready.removeFirst()
        if case let .id(id) = node, itemMap[id] != nil {
            result.append(id)
        }
        if node == .end {
            break
        }

        for dependent in dependents[node, default: []] {
            inDegree[dependent, default: 0] -= 1
            if inDegree[dependent] == 0 {
                ready.append(dependent)
                ready.sort { sortKey($0) < sortKey($1) }
            }
        }
    }

    let remaining = allNodes.filter { ($0 != .end) && (inDegree[$0, default: 0] > 0) }
    if !remaining.isEmpty {
        throw RMSceneFormatError.cyclicDependency
    }

    return result
}

public enum PenColor: Int, Equatable {
    case black = 0
    case gray = 1
    case white = 2
    case yellow = 3
    case green = 4
    case pink = 5
    case blue = 6
    case red = 7
    case grayOverlap = 8
    case highlight = 9
    case green2 = 10
    case cyan = 11
    case magenta = 12
    case yellow2 = 13
}

public enum Pen: Int, Equatable {
    case paintbrush1 = 0
    case pencil1 = 1
    case ballpoint1 = 2
    case marker1 = 3
    case fineliner1 = 4
    case highlighter1 = 5
    case eraser = 6
    case mechanicalPencil1 = 7
    case eraserArea = 8
    case paintbrush2 = 12
    case mechanicalPencil2 = 13
    case pencil2 = 14
    case ballpoint2 = 15
    case marker2 = 16
    case fineliner2 = 17
    case highlighter2 = 18
    case caligraphy = 21
    case shader = 23

    public static func isHighlighter(_ value: Int) -> Bool {
        value == Pen.highlighter1.rawValue || value == Pen.highlighter2.rawValue
    }
}

public enum ParagraphStyle: Int, Equatable {
    case basic = 0
    case plain = 1
    case heading = 2
    case bold = 3
    case bullet = 4
    case bullet2 = 5
    case checkbox = 6
    case checkboxChecked = 7
}

public enum TextItemValue: Equatable {
    case string(String)
    case formatCode(Int)
}

public final class Group: Equatable {
    public var nodeID: CrdtID
    public var children: CrdtSequence<SceneItem>
    public var label: LWWValue<String>
    public var visible: LWWValue<Bool>
    public var anchorID: LWWValue<CrdtID>?
    public var anchorType: LWWValue<Int>?
    public var anchorThreshold: LWWValue<Double>?
    public var anchorOriginX: LWWValue<Double>?

    public init(
        nodeID: CrdtID,
        children: CrdtSequence<SceneItem> = CrdtSequence(),
        label: LWWValue<String> = LWWValue(timestamp: .zero, value: ""),
        visible: LWWValue<Bool> = LWWValue(timestamp: .zero, value: true),
        anchorID: LWWValue<CrdtID>? = nil,
        anchorType: LWWValue<Int>? = nil,
        anchorThreshold: LWWValue<Double>? = nil,
        anchorOriginX: LWWValue<Double>? = nil
    ) {
        self.nodeID = nodeID
        self.children = children
        self.label = label
        self.visible = visible
        self.anchorID = anchorID
        self.anchorType = anchorType
        self.anchorThreshold = anchorThreshold
        self.anchorOriginX = anchorOriginX
    }

    public static func == (lhs: Group, rhs: Group) -> Bool {
        lhs.nodeID == rhs.nodeID &&
            lhs.children == rhs.children &&
            lhs.label == rhs.label &&
            lhs.visible == rhs.visible &&
            lhs.anchorID == rhs.anchorID &&
            lhs.anchorType == rhs.anchorType &&
            lhs.anchorThreshold == rhs.anchorThreshold &&
            lhs.anchorOriginX == rhs.anchorOriginX
    }
}

public struct Point: Equatable {
    public var x: Double
    public var y: Double
    public var speed: Double
    public var direction: Double
    public var width: Double
    public var pressure: Double

    public init(x: Double, y: Double, speed: Double, direction: Double, width: Double, pressure: Double) {
        self.x = x
        self.y = y
        self.speed = speed
        self.direction = direction
        self.width = width
        self.pressure = pressure
    }
}

public struct Line: Equatable {
    public var color: PenColor
    public var tool: Pen
    public var points: [Point]
    public var thicknessScale: Double
    public var startingLength: Double
    public var moveID: CrdtID?
    public var colorRGBA: RGBAColor?

    public init(color: PenColor, tool: Pen, points: [Point], thicknessScale: Double, startingLength: Double, moveID: CrdtID? = nil, colorRGBA: RGBAColor? = nil) {
        self.color = color
        self.tool = tool
        self.points = points
        self.thicknessScale = thicknessScale
        self.startingLength = startingLength
        self.moveID = moveID
        self.colorRGBA = colorRGBA
    }
}

public struct Text: Equatable {
    public var items: CrdtSequence<TextItemValue>
    public var styles: OrderedMap<CrdtID, LWWValue<ParagraphStyle>>
    public var posX: Double
    public var posY: Double
    public var width: Double

    public init(items: CrdtSequence<TextItemValue>, styles: OrderedMap<CrdtID, LWWValue<ParagraphStyle>>, posX: Double, posY: Double, width: Double) {
        self.items = items
        self.styles = styles
        self.posX = posX
        self.posY = posY
        self.width = width
    }
}

public struct Rectangle: Equatable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

public struct GlyphRange: Equatable {
    public var start: Int?
    public var length: Int
    public var text: String
    public var color: PenColor
    public var rectangles: [Rectangle]
    public var colorRGBA: RGBAColor?

    public init(start: Int?, length: Int, text: String, color: PenColor, rectangles: [Rectangle], colorRGBA: RGBAColor? = nil) {
        self.start = start
        self.length = length
        self.text = text
        self.color = color
        self.rectangles = rectangles
        self.colorRGBA = colorRGBA
    }
}

public indirect enum SceneItem: Equatable {
    case group(Group)
    case line(Line)
    case text(Text)
    case glyphRange(GlyphRange)
}

public struct InlineTextStyle: Equatable {
    public enum FontWeight: String, Equatable {
        case normal
        case bold
    }

    public enum FontStyle: String, Equatable {
        case normal
        case italic
    }

    public var fontWeight: FontWeight
    public var fontStyle: FontStyle

    public init(fontWeight: FontWeight = .normal, fontStyle: FontStyle = .normal) {
        self.fontWeight = fontWeight
        self.fontStyle = fontStyle
    }
}

public struct CrdtString: Equatable {
    public var string: String
    public var ids: [CrdtID]
    public var style: InlineTextStyle

    public init(string: String = "", ids: [CrdtID] = [], style: InlineTextStyle = InlineTextStyle()) {
        self.string = string
        self.ids = ids
        self.style = style
    }
}

public struct Paragraph: Equatable {
    public var contents: [CrdtString]
    public var startID: CrdtID
    public var style: LWWValue<ParagraphStyle>

    public init(contents: [CrdtString], startID: CrdtID, style: LWWValue<ParagraphStyle> = LWWValue(timestamp: .zero, value: .plain)) {
        self.contents = contents
        self.startID = startID
        self.style = style
    }
}

public struct TextDocument: Equatable {
    public var contents: [Paragraph]

    public init(contents: [Paragraph]) {
        self.contents = contents
    }

    public static func fromSceneItem(_ text: Text) throws -> TextDocument {
        let expanded = CrdtSequence(expandTextItems(text.items.sequenceItems()))
        var keys = try expanded.idsInOrder()
        var style = InlineTextStyle()
        var paragraphs: [Paragraph] = []

        func applyFormatting(_ code: Int) {
            switch code {
            case 1:
                style.fontWeight = .bold
            case 2:
                style.fontWeight = .normal
            case 3:
                style.fontStyle = .italic
            case 4:
                style.fontStyle = .normal
            default:
                break
            }
        }

        func parseParagraph() -> (CrdtID, [CrdtString]) {
            let startID: CrdtID
            if let first = keys.first, expanded[first] == .string("\n") {
                startID = first
                keys.removeFirst()
            } else {
                startID = .zero
            }

            var contents: [CrdtString] = []
            while let key = keys.first {
                let value = expanded[key]
                switch value {
                case let .formatCode(code):
                    applyFormatting(code)
                case let .string(string):
                    if string == "\n" {
                        return (startID, contents)
                    }
                    if contents.last?.style != style {
                        contents.append(CrdtString(style: style))
                    }
                    contents[contents.count - 1].string += string
                    contents[contents.count - 1].ids.append(key)
                }
                keys.removeFirst()
            }
            return (startID, contents)
        }

        while !keys.isEmpty {
            let (startID, contents) = parseParagraph()
            let paragraphStyle = text.styles[startID] ?? LWWValue(timestamp: .zero, value: .plain)
            paragraphs.append(Paragraph(contents: contents, startID: startID, style: paragraphStyle))
        }

        return TextDocument(contents: paragraphs)
    }
}

public func expandTextItem(_ item: CrdtSequenceItem<TextItemValue>) -> [CrdtSequenceItem<TextItemValue>] {
    let deletedLength: Int
    let characters: [String]

    switch item.value {
    case .formatCode:
        return [item]
    case let .string(string):
        if item.deletedLength > 0 {
            deletedLength = 1
            characters = Array(repeating: "", count: item.deletedLength)
        } else {
            deletedLength = 0
            characters = string.map(String.init)
        }
    }

    guard !characters.isEmpty else {
        return []
    }

    var itemID = item.itemID
    var leftID = item.leftID
    var result: [CrdtSequenceItem<TextItemValue>] = []

    for character in characters.dropLast() {
        let rightID = CrdtID(itemID.part1, itemID.part2 + 1)
        result.append(CrdtSequenceItem(itemID: itemID, leftID: leftID, rightID: rightID, deletedLength: deletedLength, value: .string(character)))
        leftID = itemID
        itemID = rightID
    }

    if let last = characters.last {
        result.append(CrdtSequenceItem(itemID: itemID, leftID: leftID, rightID: item.rightID, deletedLength: deletedLength, value: .string(last)))
    }

    return result
}

public func expandTextItems<S: Sequence>(_ items: S) -> [CrdtSequenceItem<TextItemValue>] where S.Element == CrdtSequenceItem<TextItemValue> {
    items.flatMap(expandTextItem)
}

public final class SceneTree {
    public static let rootID = CrdtID(0, 1)

    public let root: Group
    public private(set) var sceneInfo: SceneInfo?
    public private(set) var rootText: Text?

    private var nodeIDs: [CrdtID: Group]

    public init() {
        self.root = Group(nodeID: SceneTree.rootID)
        self.nodeIDs = [SceneTree.rootID: root]
    }

    public subscript(nodeID: CrdtID) -> Group? {
        nodeIDs[nodeID]
    }

    public func contains(nodeID: CrdtID) -> Bool {
        nodeIDs[nodeID] != nil
    }

    func addNode(nodeID: CrdtID, parentID _: CrdtID) throws {
        guard nodeIDs[nodeID] == nil else {
            throw RMSceneFormatError.invalidValue("Node \(nodeID) already in tree")
        }
        nodeIDs[nodeID] = Group(nodeID: nodeID)
    }

    func updateNode(_ group: Group) throws {
        guard let existing = nodeIDs[group.nodeID] else {
            throw RMSceneFormatError.invalidValue("Node does not exist for TreeNodeBlock: \(group.nodeID)")
        }
        existing.label = group.label
        existing.visible = group.visible
        existing.anchorID = group.anchorID
        existing.anchorType = group.anchorType
        existing.anchorThreshold = group.anchorThreshold
        existing.anchorOriginX = group.anchorOriginX
    }

    func addItem(_ item: CrdtSequenceItem<SceneItem>, parentID: CrdtID) throws {
        guard let parent = nodeIDs[parentID] else {
            throw RMSceneFormatError.invalidValue("Parent id not known: \(parentID)")
        }
        try parent.children.add(item)
    }

    func setSceneInfo(_ sceneInfo: SceneInfo) {
        self.sceneInfo = sceneInfo
    }

    func setRootText(_ rootText: Text) {
        self.rootText = rootText
    }

    public func walk() throws -> [SceneItem] {
        try walk(item: .group(root))
    }

    private func walk(item: SceneItem) throws -> [SceneItem] {
        switch item {
        case let .group(group):
            return try group.children.valuesInOrder().flatMap(walk(item:))
        default:
            return [item]
        }
    }
}

extension CrdtSequence where Value == SceneItem {
    fileprivate func valuesInOrder() throws -> [SceneItem] {
        try idsInOrder().map { self[$0] }
    }
}

extension CrdtSequence where Value == TextItemValue {
    fileprivate func valuesInOrder() throws -> [TextItemValue] {
        try idsInOrder().map { self[$0] }
    }
}
