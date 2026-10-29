import Foundation

/// A JSON tree with no assumed shape.
///
/// Agent session stores change field types between versions, and several of them
/// write records this app has never seen on disk. Binding an untyped tree lets the
/// adapters read the fields they recognise and shrug off the rest, instead of
/// losing the whole file because one member changed from a string to an object.
indirect enum JSONValue: Decodable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let bool = try? container.decode(Bool.self) { self = .bool(bool); return }
        if let number = try? container.decode(Double.self) { self = .number(number); return }
        if let string = try? container.decode(String.self) { self = .string(string); return }
        if let array = try? container.decode([JSONValue].self) { self = .array(array); return }
        if let object = try? container.decode([String: JSONValue].self) { self = .object(object); return }
        self = .null
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .number(let double): return Int(double)
        case .string(let string): return Int(string)
        case .bool(let flag): return flag ? 1 : 0
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let flag) = self { return flag }
        return nil
    }

    var stringValue: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let array) = self { return array }
        return nil
    }

    /// Null, `{}`, `[]` and `""` all mean "nothing recorded here" to these stores.
    var isPresent: Bool {
        switch self {
        case .null: return false
        case .string(let string): return !string.isEmpty
        case .array(let array): return !array.isEmpty
        case .object(let object): return !object.isEmpty
        case .bool: return true
        case .number: return true
        }
    }

    /// A readable string from a record whose schema is unknown: the value itself
    /// when it is already text, otherwise the first of the usual text fields.
    var displayText: String? {
        if let string = stringValue, !string.isEmpty { return string }
        if case .object(let object) = self {
            for key in ["text", "title", "content", "message", "summary", "reason"] {
                if let string = object[key]?.displayText, !string.isEmpty { return string }
            }
        }
        if case .array(let array) = self {
            for element in array {
                if let string = element.displayText, !string.isEmpty { return string }
            }
        }
        return nil
    }
}
