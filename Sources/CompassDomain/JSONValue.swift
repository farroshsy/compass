import Foundation

/// The value type of every forward-compatibility bag in the corpus.
/// `docs/achievement-protocol.md` §2.3.
///
/// **There is no floating-point case, and one MUST NOT be added.**
/// Floating-point formatting is not stable across platforms or releases, and
/// these values sit next to quantities that go inside a digest. Any quantity
/// that seems to need a fraction is expressed as an integer in a stated unit.
///
/// A JSON number with a fractional part therefore fails to decode rather than
/// being silently rounded — losing precision inside a bag whose whole purpose is
/// lossless round-tripping would be worse than refusing the line.
public enum JSONValue: Hashable, Sendable, Codable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: """
                    Unsupported JSON value. JSONValue has no floating-point case \
                    and one must not be added — docs/achievement-protocol.md §2.3.
                    """
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}
