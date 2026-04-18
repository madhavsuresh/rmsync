import Foundation

/// A Sendable wrapper around a JSON payload. Holds the serialized Data
/// representation; encoding is done once at the producer, decoding happens
/// at the consumer (or never, if the payload is just shipped out a socket).
///
/// We use this instead of ``[String: Any]`` so actors can safely hand
/// payloads across isolation boundaries under Swift 6 strict concurrency.
struct SendableJSON: Sendable {
    let data: Data

    init(_ data: Data) { self.data = data }

    init(_ object: Any) throws {
        self.data = try JSONSerialization.data(withJSONObject: object)
    }

    /// Convenience for constructing from a dictionary literal.
    static func dict(_ pairs: [String: SendableValue]) -> SendableJSON {
        let mapped: [String: Any] = Dictionary(uniqueKeysWithValues: pairs.map {
            ($0.key, $0.value.toAny())
        })
        return try! SendableJSON(mapped)
    }

    func decodeDict() -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Value-type enum for building JSON dicts without sending ``Any``.
indirect enum SendableValue: Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([SendableValue])
    case object([String: SendableValue])

    fileprivate func toAny() -> Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let a): return a.map { $0.toAny() }
        case .object(let o):
            return Dictionary(uniqueKeysWithValues: o.map { ($0.key, $0.value.toAny()) })
        }
    }
}

extension SendableValue: ExpressibleByStringLiteral {
    init(stringLiteral value: String) { self = .string(value) }
}
extension SendableValue: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) { self = .int(value) }
}
extension SendableValue: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) { self = .bool(value) }
}
extension SendableValue: ExpressibleByNilLiteral {
    init(nilLiteral: ()) { self = .null }
}
