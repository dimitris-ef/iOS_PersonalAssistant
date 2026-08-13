import Foundation

/// A minimal JSON Schema description used to declare tool parameters.
///
/// Providers render this into whatever their API expects (or into prompt text
/// for providers with no native tool-calling), which keeps tool definitions
/// independent of any one vendor's schema dialect.
public indirect enum JSONSchema: Hashable, Sendable, Codable {
    case string(description: String? = nil, format: StringFormat? = nil)
    case integer(description: String? = nil)
    case number(description: String? = nil)
    case boolean(description: String? = nil)
    case enumeration(values: [String], description: String? = nil)
    case array(items: JSONSchema, description: String? = nil)
    case object(properties: [String: JSONSchema], required: [String], description: String? = nil)

    public enum StringFormat: String, Hashable, Sendable, Codable {
        case dateTime = "date-time"
        case duration
        case uuid
    }
}

extension JSONSchema {
    /// Renders the schema as JSON, ready to be embedded in a provider request.
    public func jsonValue() -> JSONValue {
        switch self {
        case .string(let description, let format):
            var object: [String: JSONValue] = ["type": .string("string")]
            if let description { object["description"] = .string(description) }
            if let format { object["format"] = .string(format.rawValue) }
            return .object(object)

        case .integer(let description):
            var object: [String: JSONValue] = ["type": .string("integer")]
            if let description { object["description"] = .string(description) }
            return .object(object)

        case .number(let description):
            var object: [String: JSONValue] = ["type": .string("number")]
            if let description { object["description"] = .string(description) }
            return .object(object)

        case .boolean(let description):
            var object: [String: JSONValue] = ["type": .string("boolean")]
            if let description { object["description"] = .string(description) }
            return .object(object)

        case .enumeration(let values, let description):
            var object: [String: JSONValue] = [
                "type": .string("string"),
                "enum": .array(values.map { JSONValue.string($0) }),
            ]
            if let description { object["description"] = .string(description) }
            return .object(object)

        case .array(let items, let description):
            var object: [String: JSONValue] = [
                "type": .string("array"),
                "items": items.jsonValue(),
            ]
            if let description { object["description"] = .string(description) }
            return .object(object)

        case .object(let properties, let required, let description):
            var rendered: [String: JSONValue] = [:]
            for (key, value) in properties {
                rendered[key] = value.jsonValue()
            }
            var object: [String: JSONValue] = [
                "type": .string("object"),
                "properties": .object(rendered),
                "required": .array(required.sorted().map { JSONValue.string($0) }),
            ]
            if let description { object["description"] = .string(description) }
            return .object(object)
        }
    }
}
