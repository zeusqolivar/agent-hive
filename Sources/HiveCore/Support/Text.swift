import Foundation

/// Small text helpers with the same results as the matching functions in server.py. Lengths and slices
/// count Unicode scalars, as Python's `len()` and `[:n]` count code points.
enum Text {
    /// `text[:n]` in Python.
    static func prefix(_ text: String, _ n: Int) -> String {
        let scalars = text.unicodeScalars
        guard n < scalars.count else { return text }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars.prefix(max(0, n)))
        return String(out)
    }

    /// `text[-n:]` in Python.
    static func suffix(_ text: String, _ n: Int) -> String {
        let scalars = text.unicodeScalars
        guard n < scalars.count else { return text }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars.suffix(max(0, n)))
        return String(out)
    }

    static func length(_ text: String) -> Int { text.unicodeScalars.count }

    /// Python's `str.isspace()` for one scalar, which `split()` and `strip()` use.
    static func isSpace(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    /// `text.strip()`.
    static func strip(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isSpace($0) }),
              let last = scalars.lastIndex(where: { !isSpace($0) }) else { return "" }
        return String(scalars[first...last])
    }

    /// `text.rstrip()`.
    static func rstrip(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let last = scalars.lastIndex(where: { !isSpace($0) }) else { return "" }
        return String(scalars[...last])
    }

    /// `" ".join(text.split())`.
    static func collapseSpaces(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for s in text.unicodeScalars {
            if isSpace(s) {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out.append(" ") }
                pendingSpace = false
                out.append(s)
            }
        }
        return String(out)
    }

    /// `one_line(text, limit)`: one line, no `**` or backticks, cut with an ellipsis.
    static func oneLine(_ text: String?, _ limit: Int = 160) -> String {
        var t = collapseSpaces(text ?? "")
        t = t.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        if length(t) <= limit { return t }
        return rstrip(prefix(t, limit - 1)) + "…"
    }

    static func oneLine(_ value: JSON?, _ limit: Int = 160) -> String {
        oneLine(Py.str(orEmpty: value), limit)
    }

    private static let sentence = try! NSRegularExpression(pattern: #"^(.{20,}?[.!?])(\s|$)"#)

    /// `first_sentence(text, limit)`.
    static func firstSentence(_ text: String?, _ limit: Int = 200) -> String {
        let line = oneLine(text, 1000)
        let ns = line as NSString
        if let m = sentence.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
            return oneLine(ns.substring(with: m.range(at: 1)), limit)
        }
        return oneLine(line, limit)
    }

    /// `os.path.basename`.
    static func basename(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// `os.path.dirname`.
    static func dirname(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        var head = Substring(path[...slash])
        if !head.allSatisfy({ $0 == "/" }) {
            while head.hasSuffix("/") { head = head.dropLast() }
        }
        return String(head)
    }

    static func capitalize(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst().lowercased()
    }

    /// Replaces every match of `regex` with `template` (NSRegularExpression syntax).
    static func sub(_ regex: NSRegularExpression, _ template: String, _ text: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                       withTemplate: template)
    }

    static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    static func firstGroup(_ regex: NSRegularExpression, _ text: String, _ group: Int = 1) -> String? {
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.range(at: group).location != NSNotFound else { return nil }
        return ns.substring(with: m.range(at: group))
    }
}

/// Python conversions applied to JSON values read from transcripts.
enum Py {
    /// `str(value)`.
    static func str(_ value: JSON) -> String {
        switch value {
        case .string(let s): return s
        default: return repr(value)
        }
    }

    /// `str(value or "")`.
    static func str(orEmpty value: JSON?) -> String {
        guard let value, value.truthy else { return "" }
        return str(value)
    }

    /// `repr(value)` for the types `json.loads` produces.
    static func repr(_ value: JSON) -> String {
        switch value {
        case .null: return "None"
        case .bool(let b): return b ? "True" : "False"
        case .int(let i): return String(i)
        case .double(let d):
            let s = JSON.pythonFloat(d)
            return s == "NaN" ? "nan" : s == "Infinity" ? "inf" : s == "-Infinity" ? "-inf" : s
        case .string(let s): return reprString(s)
        case .array(let a): return "[" + a.map(repr).joined(separator: ", ") + "]"
        case .object(let o): return "{" + o.pairs.map { reprString($0) + ": " + repr($1) }.joined(separator: ", ") + "}"
        }
    }

    static func reprString(_ s: String) -> String {
        let quote: Character = s.contains("'") && !s.contains("\"") ? "\"" : "'"
        var out = String(quote)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if Character(scalar) == quote {
                    out += "\\" + String(quote)
                } else if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\x%02x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out.append(quote)
        return out
    }

    /// `int(value or 0)` for token counts; strings of digits count too.
    static func int(orZero value: JSON?) -> Int {
        guard let value, value.truthy else { return 0 }
        switch value {
        case .int(let i): return i
        case .double(let d): return Int(d)
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return Int(strip(s)) ?? 0
        default: return 0
        }
    }

    private static func strip(_ s: String) -> String { Text.strip(s) }
}

/// Timestamps as server.py's `epoch()` reads them: ISO 8601, `Z` or an offset, any number of fraction
/// digits; a time with no offset is local time. Returns whole seconds, rounded down.
enum Epoch {
    static func parse(_ value: JSON?) -> Int? {
        guard let value, value.truthy else { return nil }
        return parse(Py.str(value), timeZone: .current)
    }

    static func parse(_ text: String, timeZone: TimeZone = .current) -> Int? {
        let b = Array(text.utf8)
        func digits(_ at: Int, _ n: Int) -> Int? {
            guard at + n <= b.count else { return nil }
            var v = 0
            for k in at..<(at + n) {
                guard (0x30...0x39).contains(b[k]) else { return nil }
                v = v * 10 + Int(b[k] - 0x30)
            }
            return v
        }
        guard let year = digits(0, 4), b.count >= 10, b[4] == 0x2D, let month = digits(5, 2), b[7] == 0x2D,
              let day = digits(8, 2) else { return nil }
        var hour = 0, minute = 0, second = 0
        var frac = 0.0
        var i = 10
        var offset: Int?
        if i < b.count {
            guard b[i] == UInt8(ascii: "T") || b[i] == UInt8(ascii: " ") else { return nil }
            guard let h = digits(i + 1, 2) else { return nil }
            hour = h
            i += 3
            if i < b.count, b[i] == UInt8(ascii: ":") {
                guard let m = digits(i + 1, 2) else { return nil }
                minute = m
                i += 3
                if i < b.count, b[i] == UInt8(ascii: ":") {
                    guard let s = digits(i + 1, 2) else { return nil }
                    second = s
                    i += 3
                    if i < b.count, b[i] == UInt8(ascii: ".") || b[i] == UInt8(ascii: ",") {
                        i += 1
                        var scale = 0.1
                        let start = i
                        while i < b.count, (0x30...0x39).contains(b[i]) {
                            frac += Double(b[i] - 0x30) * scale
                            scale /= 10
                            i += 1
                        }
                        if i == start { return nil }
                    }
                }
            }
            if i < b.count {
                if b[i] == UInt8(ascii: "Z") {
                    offset = 0
                    i += 1
                } else if b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") {
                    let sign = b[i] == UInt8(ascii: "+") ? 1 : -1
                    guard let oh = digits(i + 1, 2) else { return nil }
                    i += 3
                    var om = 0
                    if i < b.count, b[i] == UInt8(ascii: ":") { i += 1 }
                    if let m = digits(i, 2) { om = m; i += 2 }
                    offset = sign * (oh * 3600 + om * 60)
                }
                guard i == b.count else { return nil }
            }
        }
        guard (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60 else { return nil }
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute; comps.second = second
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = offset.map { TimeZone(secondsFromGMT: $0)! } ?? timeZone
        guard let date = cal.date(from: comps) else { return nil }
        return Int((date.timeIntervalSince1970 + frac).rounded(.down))
    }
}

extension Array {
    /// A stable sort, as Python's `sorted` is.
    func stableSorted(by less: (Element, Element) -> Bool) -> [Element] {
        enumerated().sorted { a, b in
            if less(a.element, b.element) { return true }
            if less(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }
}
