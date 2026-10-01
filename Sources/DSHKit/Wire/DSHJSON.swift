import Foundation

/// A JSON value that round-trips losslessly, matching the Harness wire contract.
///
/// The Harness validates every payload with `isRemoteJsonValue`, which rejects
/// non-finite numbers, negative zero, and non-plain objects. This enum cannot
/// represent any of those, so a decoded `DSHJSON` is always wire-legal.
public enum DSHJSON: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([DSHJSON])
    case object([String: DSHJSON])
}

// MARK: - Decoding

extension DSHJSON: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([DSHJSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: DSHJSON].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "value is not lossless JSON"
            )
        }
    }
}

extension DSHJSON: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Ergonomic accessors

extension DSHJSON {
    /// The object member, or nil for any other case.
    public subscript(key: String) -> DSHJSON? {
        guard case .object(let members) = self else { return nil }
        return members[key]
    }

    /// The array element at `index`, or nil when out of range or not an array.
    public subscript(index: Int) -> DSHJSON? {
        guard case .array(let elements) = self, elements.indices.contains(index) else { return nil }
        return elements[index]
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var doubleValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    public var intValue: Int? {
        guard case .number(let value) = self, value.isFinite,
              value.rounded() == value, value.magnitude < Double(Int.max)
        else { return nil }
        return Int(value)
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public var arrayValue: [DSHJSON]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    public var objectValue: [String: DSHJSON]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

// MARK: - Bridge to standard Foundation containers

extension DSHJSON {
    /// Convert to a `JSONSerialization`-compatible container.
    public var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let value): return value.map(\.anyValue)
        case .object(let value): return value.mapValues(\.anyValue)
        }
    }

    /// Build from an untyped container (`JSONSerialization` output).
    ///
    /// Returns nil for values outside the wire contract, so a malformed frame is
    /// rejected rather than silently coerced.
    ///
    /// Booleans must be identified through `CFBoolean` rather than `as? Bool`:
    /// `JSONSerialization` bridges every `NSNumber` so that `1 as? Bool` is `true`,
    /// which would silently turn the number `1` into a boolean and corrupt any
    /// numeric field that also admits a boolean (`header.version`, todo payloads).
    public init?(anyValue: Any) {
        if let number = anyValue as? NSNumber {
            // `CFBoolean` is the only reliable JSON-boolean marker here.
            let isBoolean = CFGetTypeID(number) == CFBooleanGetTypeID()
            self = isBoolean ? .bool(number.boolValue) : .number(number.doubleValue)
            return
        }

        switch anyValue {
        case is NSNull:
            self = .null
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            var elements: [DSHJSON] = []
            elements.reserveCapacity(value.count)
            for element in value {
                guard let converted = DSHJSON(anyValue: element) else { return nil }
                elements.append(converted)
            }
            self = .array(elements)
        case let value as [String: Any]:
            var members: [String: DSHJSON] = [:]
            members.reserveCapacity(value.count)
            for (key, element) in value {
                guard let converted = DSHJSON(anyValue: element) else { return nil }
                members[key] = converted
            }
            self = .object(members)
        default:
            return nil
        }
    }
}

// MARK: - Literals

extension DSHJSON: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension DSHJSON: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension DSHJSON: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension DSHJSON: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension DSHJSON: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension DSHJSON: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: DSHJSON...) { self = .array(elements) }
}

extension DSHJSON: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, DSHJSON)...) {
        var members: [String: DSHJSON] = [:]
        members.reserveCapacity(elements.count)
        for (key, value) in elements { members[key] = value }
        self = .object(members)
    }
}
