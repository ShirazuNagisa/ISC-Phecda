import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSONValue { object[key] ?? .null }
    public var object: [String: JSONValue] { if case .object(let v) = self { v } else { [:] } }
    public var array: [JSONValue] { if case .array(let v) = self { v } else { [] } }
    public var string: String { if case .string(let v) = self { v } else { "" } }
    public var bool: Bool { if case .bool(let v) = self { v } else { false } }
    public var number: Double { if case .number(let v) = self { v } else { 0 } }
    public var id: String { self["id"].string }
    public var items: [JSONValue] { if case .array = self { array } else { self["items"].array } }
    public func data() throws -> Data { try JSONEncoder().encode(self) }
    public func text(pretty: Bool = false) throws -> String {
        let encoder = JSONEncoder()
        if pretty { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
    public static func parse(_ text: String) throws -> JSONValue { try JSONDecoder().decode(Self.self, from: Data(text.utf8)) }
}

public struct KernelError: Error, LocalizedError, Sendable {
    public let code: String
    public let status: Int
    public let message: String
    public init(code: String, status: Int = 0, message: String) { self.code = code; self.status = status; self.message = message }
    public var errorDescription: String? { message }
}

public struct KernelReply: Sendable {
    public let body: JSONValue
    public let status: Int
    public init(_ envelope: JSONValue) throws {
        guard envelope["ok"].bool else {
            throw KernelError(code: envelope["code"].string, status: Int(envelope["status"].number), message: envelope["error"].string.isEmpty ? "Invalid kernel reply" : envelope["error"].string)
        }
        status = Int(envelope["status"].number)
        body = envelope.object["body"] ?? envelope
    }
}
