import Foundation

/// JSON values retained at extensible schema-v1 record boundaries.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Decimal)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let value = try? single.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? single.decode(Decimal.self) {
            self = .number(value)
        } else if let value = try? single.decode(String.self) {
            self = .string(value)
        } else if let values = try? decoder.container(keyedBy: DynamicJSONKey.self) {
            var object: [String: JSONValue] = [:]
            for key in values.allKeys {
                object[key.stringValue] = try values.decode(JSONValue.self, forKey: key)
            }
            self = .object(object)
        } else if var values = try? decoder.unkeyedContainer() {
            var array: [JSONValue] = []
            while !values.isAtEnd { array.append(try values.decode(JSONValue.self)) }
            self = .array(array)
        } else {
            throw DecodingError.dataCorruptedError(in: single, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var values = encoder.singleValueContainer()
            try values.encodeNil()
        case .bool(let value):
            var values = encoder.singleValueContainer()
            try values.encode(value)
        case .number(let value):
            var values = encoder.singleValueContainer()
            try values.encode(value)
        case .string(let value):
            var values = encoder.singleValueContainer()
            try values.encode(value)
        case .array(let value):
            var values = encoder.unkeyedContainer()
            for item in value { try values.encode(item) }
        case .object(let value):
            var values = encoder.container(keyedBy: DynamicJSONKey.self)
            for (key, item) in value { try values.encode(item, forKey: DynamicJSONKey(key)) }
        }
    }
}

/// Opaque extensible fields. The stored keys and values are intentionally not exposed to app views.
public struct OpaqueJSONFields: Hashable, Sendable {
    var values: [String: JSONValue]

    public init() { values = [:] }

    init(values: [String: JSONValue]) { self.values = values }

    static func decode(from decoder: Decoder, excluding knownKeys: Set<String>) throws -> OpaqueJSONFields {
        let values = try decoder.container(keyedBy: DynamicJSONKey.self)
        var fields: [String: JSONValue] = [:]
        for key in values.allKeys where !knownKeys.contains(key.stringValue) {
            fields[key.stringValue] = try values.decode(JSONValue.self, forKey: key)
        }
        return OpaqueJSONFields(values: fields)
    }

    func encode(to encoder: Encoder, excluding knownKeys: Set<String>) throws {
        var values = encoder.container(keyedBy: DynamicJSONKey.self)
        for (key, value) in self.values where !knownKeys.contains(key) {
            try values.encode(value, forKey: DynamicJSONKey(key))
        }
    }

    mutating func keepMissingFields(from fallback: OpaqueJSONFields) {
        for (key, value) in fallback.values where values[key] == nil { values[key] = value }
    }
}

struct DynamicJSONKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ stringValue: String) { self.stringValue = stringValue }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
