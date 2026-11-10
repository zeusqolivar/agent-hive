import Foundation

/// A JSON value that keeps object keys in their original order and tells integers from floats,
/// so payloads serialize the way Python's `json.dumps` writes them.
public enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSON])
    case object(JSONObject)
}

/// An ordered JSON object. Lookups are linear, which is fine for the small objects transcripts hold.
public struct JSONObject: Sendable, Equatable {
    public private(set) var keys: [String] = []
    public private(set) var values: [JSON] = []

    public init() {}

    public init(_ pairs: KeyValuePairs<String, JSON>) {
        for (k, v) in pairs { self[k] = v }
    }

    public var isEmpty: Bool { keys.isEmpty }
    public var count: Int { keys.count }

    public subscript(key: String) -> JSON? {
        get {
            guard let i = keys.firstIndex(of: key) else { return nil }
            return values[i]
        }
        set {
            if let i = keys.firstIndex(of: key) {
                if let newValue { values[i] = newValue } else { keys.remove(at: i); values.remove(at: i) }
            } else if let newValue {
                keys.append(key)
                values.append(newValue)
            }
        }
    }

    public var pairs: Zip2Sequence<[String], [JSON]> { zip(keys, values) }
}

// MARK: - Codable

extension JSON: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else {
            let d = try c.decode([String: JSON].self)
            var o = JSONObject()
            for k in d.keys.sorted() { o[k] = d[k] }
            self = .object(o)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o):
            var d: [String: JSON] = [:]
            for (k, v) in o.pairs { d[k] = v }
            try c.encode(d)
        }
    }
}

// MARK: - Building

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral, ExpressibleByFloatLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(nilLiteral: ()) { self = .null }
    public init(dictionaryLiteral elements: (String, JSON)...) {
        var o = JSONObject()
        for (k, v) in elements { o[k] = v }
        self = .object(o)
    }

    public init(_ s: String?) { self = s.map(JSON.string) ?? .null }
    public init(_ i: Int?) { self = i.map(JSON.int) ?? .null }
    public init(_ d: Double?) { self = d.map(JSON.double) ?? .null }
    public init(_ b: Bool?) { self = b.map(JSON.bool) ?? .null }
}

/// Types that turn themselves into a JSON payload.
public protocol JSONRepresentable {
    var json: JSON { get }
}

extension Optional where Wrapped: JSONRepresentable {
    public var json: JSON { self?.json ?? .null }
}

extension Array where Element: JSONRepresentable {
    public var json: JSON { .array(map(\.json)) }
}

// MARK: - Reading

extension JSON {
    public subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var object: JSONObject? { if case .object(let o) = self { return o }; return nil }
    public var array: [JSON]? { if case .array(let a) = self { return a }; return nil }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }

    /// An integer, as Python's `isinstance(x, int)` would accept (booleans excluded).
    public var int: Int? {
        if case .int(let i) = self { return i }
        return nil
    }

    public var number: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    /// Python truthiness.
    public var truthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s): return !s.isEmpty
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        }
    }

    public func replacingInStrings(_ target: String, with replacement: String) -> JSON {
        switch self {
        case .string(let s): return .string(s.replacingOccurrences(of: target, with: replacement))
        case .array(let a): return .array(a.map { $0.replacingInStrings(target, with: replacement) })
        case .object(let o):
            var out = JSONObject()
            for (k, v) in o.pairs { out[k] = v.replacingInStrings(target, with: replacement) }
            return .object(out)
        default: return self
        }
    }
}

extension Optional where Wrapped == JSON {
    /// Python truthiness of `d.get(key)`: a missing key is falsy.
    public var truthy: Bool { self?.truthy ?? false }
}

// MARK: - Parsing

public struct JSONParseError: Error, Sendable {
    public let offset: Int
}

extension JSON {
    public static func parse(_ data: Data) throws -> JSON {
        try data.withUnsafeBytes { raw in
            try parse(UnsafeBufferPointer(start: raw.baseAddress?.assumingMemoryBound(to: UInt8.self), count: raw.count))
        }
    }

    public static func parse(_ text: String) throws -> JSON {
        var text = text
        return try text.withUTF8 { try parse($0) }
    }

    public static func parse(_ bytes: UnsafeBufferPointer<UInt8>) throws -> JSON {
        var p = Parser(bytes: bytes)
        p.skipSpace()
        let value = try p.value(depth: 0)
        p.skipSpace()
        guard p.i == p.bytes.count else { throw JSONParseError(offset: p.i) }
        return value
    }

    private struct Parser {
        let bytes: UnsafeBufferPointer<UInt8>
        var i = 0

        init(bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

        mutating func skipSpace() {
            while i < bytes.count {
                switch bytes[i] {
                case 0x20, 0x09, 0x0A, 0x0D: i += 1
                default: return
                }
            }
        }

        func fail() -> JSONParseError { JSONParseError(offset: i) }

        mutating func value(depth: Int) throws -> JSON {
            guard depth < 512, i < bytes.count else { throw fail() }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try objectValue(depth: depth)
            case UInt8(ascii: "["): return try arrayValue(depth: depth)
            case UInt8(ascii: "\""): return .string(try stringValue())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            case UInt8(ascii: "N"): try literal("NaN"); return .double(.nan)
            case UInt8(ascii: "I"): try literal("Infinity"); return .double(.infinity)
            default: return try numberValue()
            }
        }

        mutating func literal(_ word: StaticString) throws {
            let n = word.utf8CodeUnitCount
            guard i + n <= bytes.count else { throw fail() }
            let w = word.utf8Start
            for k in 0..<n where bytes[i + k] != w[k] { throw fail() }
            i += n
        }

        mutating func objectValue(depth: Int) throws -> JSON {
            i += 1
            var o = JSONObject()
            skipSpace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
            while true {
                skipSpace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail() }
                let key = try stringValue()
                skipSpace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw fail() }
                i += 1
                skipSpace()
                // Python keeps the last value for a repeated key, in the first key's position.
                o[key] = try value(depth: depth + 1)
                skipSpace()
                guard i < bytes.count else { throw fail() }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
                throw fail()
            }
        }

        mutating func arrayValue(depth: Int) throws -> JSON {
            i += 1
            var a: [JSON] = []
            skipSpace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
            while true {
                skipSpace()
                a.append(try value(depth: depth + 1))
                skipSpace()
                guard i < bytes.count else { throw fail() }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
                throw fail()
            }
        }

        mutating func stringValue() throws -> String {
            i += 1
            let start = i
            // Fast path: no escapes.
            while i < bytes.count {
                let c = bytes[i]
                if c == UInt8(ascii: "\"") {
                    let s = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<i]), as: UTF8.self)
                    i += 1
                    return s
                }
                if c == UInt8(ascii: "\\") { break }
                if c < 0x20 { throw fail() }
                i += 1
            }
            var out: [UInt8] = Array(bytes[start..<i])
            while i < bytes.count {
                let c = bytes[i]
                if c == UInt8(ascii: "\"") {
                    i += 1
                    return String(decoding: out, as: UTF8.self)
                }
                if c < 0x20 { throw fail() }
                if c != UInt8(ascii: "\\") { out.append(c); i += 1; continue }
                i += 1
                guard i < bytes.count else { throw fail() }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800..<0xDC00).contains(code), i + 6 <= bytes.count,
                       bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                        let save = i
                        i += 2
                        let low = try hex4()
                        if (0xDC00..<0xE000).contains(low) {
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            i = save
                        }
                    }
                    let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
                    out.append(contentsOf: Array(String(Character(scalar)).utf8))
                default: throw fail()
                }
            }
            throw fail()
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= bytes.count else { throw fail() }
            var v: UInt32 = 0
            for _ in 0..<4 {
                let c = bytes[i]
                let d: UInt32
                switch c {
                case 0x30...0x39: d = UInt32(c - 0x30)
                case 0x41...0x46: d = UInt32(c - 0x41 + 10)
                case 0x61...0x66: d = UInt32(c - 0x61 + 10)
                default: throw fail()
                }
                v = v * 16 + d
                i += 1
            }
            return v
        }

        mutating func numberValue() throws -> JSON {
            let start = i
            var isFloat = false
            if i < bytes.count, bytes[i] == UInt8(ascii: "-") {
                i += 1
                if i < bytes.count, bytes[i] == UInt8(ascii: "I") { try literal("Infinity"); return .double(-.infinity) }
            }
            let digitsStart = i
            while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1 }
            guard i > digitsStart else { throw fail() }
            if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
                isFloat = true
                i += 1
                let f = i
                while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1 }
                guard i > f else { throw fail() }
            }
            if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
                isFloat = true
                i += 1
                if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
                let f = i
                while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1 }
                guard i > f else { throw fail() }
            }
            let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<i]), as: UTF8.self)
            if !isFloat, let v = Int(text) { return .int(v) }
            guard let d = Double(text) else { throw fail() }
            return .double(d)
        }
    }
}

// MARK: - Writing

extension JSON {
    /// Serialized like Python's `json.dumps(value, ensure_ascii=False)`: `", "` and `": "` separators,
    /// keys in order, non-ASCII text left as is.
    public func serialized() -> Data {
        var out: [UInt8] = []
        out.reserveCapacity(256)
        write(to: &out)
        return Data(out)
    }

    public var serializedString: String { String(decoding: serialized(), as: UTF8.self) }

    /// Serialized like Python's `json.dumps(value, ensure_ascii=False, indent=indent)`: each member on its
    /// own line, `","` and `": "` separators, and empty lists and objects as `[]` and `{}`.
    public func serialized(indent: Int) -> Data {
        var out: [UInt8] = []
        out.reserveCapacity(1024)
        writeIndented(to: &out, indent: indent, level: 0)
        return Data(out)
    }

    func writeIndented(to out: inout [UInt8], indent: Int, level: Int) {
        func newline(_ level: Int) {
            out.append(0x0A)
            out.append(contentsOf: [UInt8](repeating: 0x20, count: indent * level))
        }
        switch self {
        case .array(let a) where !a.isEmpty:
            out.append(UInt8(ascii: "["))
            for (n, v) in a.enumerated() {
                if n > 0 { out.append(UInt8(ascii: ",")) }
                newline(level + 1)
                v.writeIndented(to: &out, indent: indent, level: level + 1)
            }
            newline(level)
            out.append(UInt8(ascii: "]"))
        case .object(let o) where !o.isEmpty:
            out.append(UInt8(ascii: "{"))
            for (n, (k, v)) in o.pairs.enumerated() {
                if n > 0 { out.append(UInt8(ascii: ",")) }
                newline(level + 1)
                JSON.writeString(k, to: &out)
                out.append(UInt8(ascii: ":"))
                out.append(UInt8(ascii: " "))
                v.writeIndented(to: &out, indent: indent, level: level + 1)
            }
            newline(level)
            out.append(UInt8(ascii: "}"))
        case .array:
            out.append(contentsOf: Array("[]".utf8))
        case .object:
            out.append(contentsOf: Array("{}".utf8))
        default:
            write(to: &out)
        }
    }

    func write(to out: inout [UInt8]) {
        switch self {
        case .null: out.append(contentsOf: Array("null".utf8))
        case .bool(let b): out.append(contentsOf: Array((b ? "true" : "false").utf8))
        case .int(let i): out.append(contentsOf: Array(String(i).utf8))
        case .double(let d): out.append(contentsOf: Array(JSON.pythonFloat(d).utf8))
        case .string(let s): JSON.writeString(s, to: &out)
        case .array(let a):
            out.append(UInt8(ascii: "["))
            for (n, v) in a.enumerated() {
                if n > 0 { out.append(UInt8(ascii: ",")); out.append(UInt8(ascii: " ")) }
                v.write(to: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let o):
            out.append(UInt8(ascii: "{"))
            for (n, (k, v)) in o.pairs.enumerated() {
                if n > 0 { out.append(UInt8(ascii: ",")); out.append(UInt8(ascii: " ")) }
                JSON.writeString(k, to: &out)
                out.append(UInt8(ascii: ":"))
                out.append(UInt8(ascii: " "))
                v.write(to: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    static func writeString(_ s: String, to out: inout [UInt8]) {
        out.append(0x22)
        for b in s.utf8 {
            switch b {
            case 0x22: out.append(0x5C); out.append(0x22)
            case 0x5C: out.append(0x5C); out.append(0x5C)
            case 0x0A: out.append(0x5C); out.append(UInt8(ascii: "n"))
            case 0x0D: out.append(0x5C); out.append(UInt8(ascii: "r"))
            case 0x09: out.append(0x5C); out.append(UInt8(ascii: "t"))
            case 0x08: out.append(0x5C); out.append(UInt8(ascii: "b"))
            case 0x0C: out.append(0x5C); out.append(UInt8(ascii: "f"))
            case 0..<0x20:
                out.append(contentsOf: Array(String(format: "\\u%04x", b).utf8))
            default: out.append(b)
            }
        }
        out.append(0x22)
    }

    /// Python's `repr(float)`, as `json.dumps` writes it.
    static func pythonFloat(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
        if d == d.rounded(), abs(d) < 1e16 { return String(format: "%.1f", d) }
        var s = "\(d)"
        // Swift writes 1e-05 and 1e+16 like Python; only make sure an exponent form keeps its sign.
        if let e = s.firstIndex(of: "e"), s[s.index(after: e)] != "-", s[s.index(after: e)] != "+" {
            s.insert("+", at: s.index(after: e))
        }
        return s
    }
}
