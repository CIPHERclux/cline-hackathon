import Foundation

/// A decoded JSON value. Script lines are decoded into this first, then validated into typed
/// actions (§6.4), so one bad field never throws away the whole line's context.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Decodes one JSON document. Returns nil for anything that is not valid JSON.
    public static func parse(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8),
            let decoded = try? JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed])
        else { return nil }
        return JSONValue(foundationObject: decoded)
    }

    init?(foundationObject: Any) {
        switch foundationObject {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            // JSONSerialization hands booleans over as NSNumber; tell them apart by type ID.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.compactMap(JSONValue.init(foundationObject:)))
        case let dictionary as [String: Any]:
            self = .object(dictionary.compactMapValues(JSONValue.init(foundationObject:)))
        default:
            return nil
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let dictionary) = self { return dictionary[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let number) = self { return number }
        return nil
    }

    public var integerValue: Int? {
        guard let number = numberValue, number.rounded() == number else { return nil }
        return Int(exactly: number)
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let array) = self { return array }
        return nil
    }

    public var isObject: Bool {
        if case .object = self { return true }
        return false
    }
}
