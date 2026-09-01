import Foundation

/// A permissive JSON value.
///
/// Prime Agent's session JSONL is a versioned, extension-extensible union: entries carry
/// arbitrary `details`/`data` payloads written by third-party extensions, and new entry
/// types appear between releases. Decoding into exhaustive Swift structs would make Aviary
/// throw on transcripts it could otherwise render perfectly. So every record is parsed into
/// `JSONValue` first and read through forgiving accessors — an unknown field is invisible,
/// never fatal.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Decoding

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let d = try? c.decode(Double.self) {
            self = .number(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unrepresentable JSON")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let d):
            // Keep integers integral on the way out so round-tripping models.json
            // doesn't rewrite `200000` as `200000.0`.
            if d == d.rounded(), abs(d) < 9_007_199_254_740_992 {
                try c.encode(Int64(d))
            } else {
                try c.encode(d)
            }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public static func parse(_ data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    public static func parse(line: String) -> JSONValue? {
        guard let d = line.data(using: .utf8) else { return nil }
        return parse(d)
    }
}

// MARK: - Accessors

extension JSONValue {
    public subscript(key: String) -> JSONValue? {
        guard case .object(let o) = self else { return nil }
        return o[key]
    }

    public subscript(index: Int) -> JSONValue? {
        guard case .array(let a) = self, a.indices.contains(index) else { return nil }
        return a[index]
    }

    /// Dotted path lookup: `entry.path("message.usage.cost.total")`.
    public func path(_ dotted: String) -> JSONValue? {
        var cur: JSONValue? = self
        for part in dotted.split(separator: ".") {
            if let idx = Int(part) {
                cur = cur?[idx]
            } else {
                cur = cur?[String(part)]
            }
            if cur == nil { return nil }
        }
        return cur
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let d): return d
        case .string(let s): return Double(s)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    public var intValue: Int? {
        guard let d = doubleValue, d.isFinite, d.rounded() == d else { return nil }
        // `Double(Int.max)` rounds up to the first unrepresentable Int on 64-bit targets.
        // Keep the upper bound exclusive so adversarial JSON is rejected rather than trapping
        // inside the numeric conversion before a reducer can quarantine the event.
        let upperExclusive = -Double(Int.min)
        guard d >= Double(Int.min), d < upperExclusive else { return nil }
        return Int(d)
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let d): return d != 0
        case .string(let s): return ["true", "1", "yes"].contains(s.lowercased())
        default: return nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var isNull: Bool { self == .null }

    /// String content whether the field holds a bare string or an array of content blocks.
    /// Prime Agent uses both shapes for `content` depending on message role and age.
    public var textContent: String {
        switch self {
        case .string(let s): return s
        case .array(let blocks):
            return blocks.compactMap { block -> String? in
                switch block["type"]?.stringValue {
                case "text": return block["text"]?.stringValue
                case "thinking": return block["thinking"]?.stringValue
                default: return nil
                }
            }.joined()
        case .object(let o):
            if let t = o["text"]?.stringValue { return t }
            return ""
        default: return ""
        }
    }

    /// Pretty-printed JSON, for inspector panes and "copy raw" affordances.
    public var prettyPrinted: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let d = try? enc.encode(self), let s = String(data: d, encoding: .utf8) else { return "" }
        return s
    }

    public var compactJSON: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        guard let d = try? enc.encode(self), let s = String(data: d, encoding: .utf8) else { return "" }
        return s
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}
