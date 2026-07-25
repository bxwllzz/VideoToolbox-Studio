import CoreFoundation
import Foundation

enum JSONValue: Encodable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(foundationValue value: Any) {
        let object = value as AnyObject
        if CFGetTypeID(object) == CFBooleanGetTypeID() {
            self = .bool((value as? NSNumber)?.boolValue ?? false)
            return
        }

        switch value {
        case let value as String:
            self = .string(value)
        case let value as NSNumber:
            self = .number(value.doubleValue)
        case let value as Date:
            self = .string(ISO8601DateFormatter().string(from: value))
        case let value as Data:
            self = .string(value.base64EncodedString())
        case let value as NSDictionary:
            var dictionary: [String: JSONValue] = [:]
            for (key, nestedValue) in value {
                dictionary[String(describing: key)] = JSONValue(foundationValue: nestedValue)
            }
            self = .object(dictionary)
        case let value as NSArray:
            self = .array(value.map(JSONValue.init(foundationValue:)))
        default:
            self = .string(String(describing: value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}
