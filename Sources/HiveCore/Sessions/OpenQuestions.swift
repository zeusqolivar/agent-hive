import Foundation

/// Questions a finished message leaves for you, as server.py's `open_questions` and `questions_of` find them:
/// sentences ending in "?", and the list items under headings such as "Left for you to decide" or
/// "Still open". Code blocks and quoted lines don't count. At most five.
public enum OpenQuestions {
    public static let limit = 5

    static let heading = try! NSRegularExpression(
        pattern: #"^(?:left for you to decide|still open(?: from before)?|your call|waiting on you|open questions?|"#
            + #"questions? for you|decisions?(?: for you| needed)?|needs? your (?:input|decision|ok))\b"#,
        options: [.caseInsensitive])
    static let listItem = try! NSRegularExpression(pattern: #"^(?:[-*\x{2022}]|\d+[.)])\s+"#)
    static let codeBlock = try! NSRegularExpression(pattern: "```.*?```", options: [.dotMatchesLineSeparators])
    static let markup = try! NSRegularExpression(pattern: "[*_`]+")
    static let sentenceBreak = try! NSRegularExpression(pattern: #"(?<=[.!?])\s+"#)
    /// Links and short quoted names: a "?" inside them doesn't end a question for you.
    static let shielded = try! NSRegularExpression(pattern: #"https?://\S+|"[^"]{0,80}"|\x{201c}[^\x{201d}]{0,80}\x{201d}"#)
    static let question = try! NSRegularExpression(pattern: #"[^.!?]*\?"#)

    static let hiddenQuestion = "\u{ffff}", hiddenStop = "\u{fffe}"

    /// `open_questions(text)`.
    public static func find(_ text: String?, limit: Int = OpenQuestions.limit) -> [String] {
        var found: [String] = []
        func add(_ raw: String) {
            var q = Text.strip(Text.oneLine(raw, 200))
            if let first = q.unicodeScalars.first, first.properties.isLowercase {
                q = first.properties.uppercaseMapping + String(q.unicodeScalars.dropFirst())
            }
            if !q.isEmpty, !found.contains(q) { found.append(q) }
        }

        var underHeading = false
        for raw in Text.sub(codeBlock, "", text ?? "").components(separatedBy: "\n") {
            let line = Text.strip(raw)
            if line.isEmpty || line.hasPrefix(">") { continue }
            let isItem = Text.matches(listItem, line)
            let body = Text.strip(Text.sub(markup, "", Text.sub(listItem, "", line)))
            let ns = body as NSString
            if let m = heading.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)) {
                underHeading = true
                let rest = Text.strip(lstrip(ns.substring(from: m.range.upperBound), " :-\u{2014}"))
                if !rest.isEmpty { add(split(sentenceBreak, rest).first ?? rest) }
                continue
            }
            if underHeading, isItem {
                add(body)
                continue
            }
            if !isItem { underHeading = false }
            let hidden = replacing(shielded, in: body) {
                $0.replacingOccurrences(of: "?", with: hiddenQuestion).replacingOccurrences(of: ".", with: hiddenStop)
            }
            let hns = hidden as NSString
            for m in question.matches(in: hidden, range: NSRange(location: 0, length: hns.length)) {
                add(hns.substring(with: m.range).replacingOccurrences(of: hiddenQuestion, with: "?")
                        .replacingOccurrences(of: hiddenStop, with: "."))
            }
        }
        return Array(found.prefix(limit))
    }

    /// `questions_of(tail)`: the open questions in the latest finished message, until you reply to it.
    public static func of(_ tail: TranscriptTail?) -> [String] {
        guard let tail else { return [] }
        var texts = [tail.recap]
        let replied = (tail.promptTs ?? 0) != 0 && (tail.lastTextTs ?? 0) != 0 && tail.promptTs! > tail.lastTextTs!
        if !replied { texts.append(tail.lastText) }
        return find(texts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n"))
    }

    /// `s.lstrip(chars)`.
    static func lstrip(_ s: String, _ chars: String) -> String {
        let set = Set(chars.unicodeScalars)
        return String(String.UnicodeScalarView(s.unicodeScalars.drop { set.contains($0) }))
    }

    /// `re.split(pattern, s)`.
    static func split(_ regex: NSRegularExpression, _ s: String) -> [String] {
        let ns = s as NSString
        var out: [String] = []
        var start = 0
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out.append(ns.substring(with: NSRange(location: start, length: m.range.location - start)))
            start = m.range.upperBound
        }
        out.append(ns.substring(from: start))
        return out
    }

    /// `re.sub(pattern, lambda m: transform(m.group(0)), s)`.
    static func replacing(_ regex: NSRegularExpression, in s: String, _ transform: (String) -> String) -> String {
        let ns = s as NSString
        var out = ""
        var start = 0
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: start, length: m.range.location - start))
            out += transform(ns.substring(with: m.range))
            start = m.range.upperBound
        }
        return out + ns.substring(from: start)
    }
}
