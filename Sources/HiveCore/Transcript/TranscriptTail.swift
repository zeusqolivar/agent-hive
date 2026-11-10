import Foundation

/// One timeline entry from a transcript: something you said, Claude said, a tool call, a recap or an
/// automated message. Keys match the event dictionaries in server.py's `scan_lines`.
public struct TranscriptEvent: Codable, Sendable, Equatable, JSONRepresentable {
    public var id: String
    public var t: Int?
    public var k: String
    public var title: String
    public var body: String
    public var verb: String?
    public var tool: String?
    public var out: String?
    public var err: Bool?

    public var json: JSON {
        var o = JSONObject(["id": .string(id), "t": JSON(t), "k": .string(k)])
        if let verb { o["verb"] = .string(verb) }
        o["title"] = .string(title)
        o["body"] = .string(body)
        if let tool { o["tool"] = .string(tool) }
        if let out { o["out"] = .string(out) }
        if let err { o["err"] = .bool(err) }
        return .object(o)
    }
}

public struct PlanItem: Codable, Sendable, Equatable, JSONRepresentable {
    public var text: String
    public var state: String
    public var json: JSON { ["text": .string(text), "state": .string(state)] }
}

public struct PullRequest: Codable, Sendable, Equatable, JSONRepresentable {
    public var url: String
    public var number: JSON?
    public var repo: JSON?

    public var json: JSON { ["url": .string(url), "number": number ?? .null, "repo": repo ?? .null] }

}

/// The parsed tail of a transcript, with the keys of server.py's `read_transcript`.
public struct TranscriptTail: Codable, Sendable, JSONRepresentable {
    public var title: String?
    public var prompt: String?
    public var promptTs: Int?
    public var model: String?
    public var effort: String?
    public var branch: String?
    public var cwd: String?
    public var mode: String?
    public var contextTokens: Int?
    public var lastTs: Int?
    public var lastText: String?
    public var lastTextTs: Int?
    public var recap: String?
    public var ask: String?
    public var askTs: Int?
    public var plan: [PlanItem] = []
    public var prs: [PullRequest] = []
    public var events: [TranscriptEvent] = []
    public var pending: [TranscriptEvent] = []
    public var turnEnded = false
    public var size: Int = 0
    public var mtime: Int = 0

    public init() {}

    public var json: JSON {
        [
            "title": JSON(title), "prompt": JSON(prompt), "promptTs": JSON(promptTs), "model": JSON(model),
            "effort": JSON(effort), "branch": JSON(branch), "cwd": JSON(cwd), "mode": JSON(mode),
            "contextTokens": JSON(contextTokens), "lastTs": JSON(lastTs), "lastText": JSON(lastText),
            "lastTextTs": JSON(lastTextTs), "recap": JSON(recap), "ask": JSON(ask), "askTs": JSON(askTs),
            "plan": plan.json, "prs": prs.json, "events": events.json, "pending": pending.json,
            "turnEnded": .bool(turnEnded), "size": .int(size), "mtime": .int(mtime),
        ]
    }
}

/// Reads the end of a file as lines: the last `want` bytes, minus the first (probably partial) line.
/// Matches server.py's `read_tail_lines`, including dropping one whole line when the cut lands on a line
/// boundary.
enum TailFile {
    static func lines(_ url: URL, size: Int, want: Int) throws -> [ArraySlice<UInt8>] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data: Data
        if size > want {
            try handle.seek(toOffset: UInt64(size - want))
            data = try handle.read(upToCount: want) ?? Data()
            if let nl = data.firstIndex(of: 0x0A) {
                data = data[(nl + 1)...]
            } else {
                data = Data()
            }
        } else {
            data = try handle.readToEnd() ?? Data()
        }
        let bytes = [UInt8](data)
        return bytes.split(separator: 0x0A, omittingEmptySubsequences: false)
    }

    /// Parses one line as a JSON object, or nil for blank, cut-off or non-object lines.
    static func object(_ line: ArraySlice<UInt8>) -> JSONObject? {
        guard !line.isEmpty else { return nil }
        return line.withUnsafeBufferPointer { buf in
            guard let value = try? JSON.parse(buf), case .object(let o) = value else { return nil }
            return o
        }
    }

    static func hasPrefixMarker(_ line: ArraySlice<UInt8>, _ marker: [UInt8], within limit: Int = 200) -> Bool {
        let head = line.prefix(limit)
        guard head.count >= marker.count else { return false }
        return head.withUnsafeBufferPointer { buf in
            let end = buf.count - marker.count
            var i = 0
            while i <= end {
                if buf[i] == marker[0] {
                    var k = 1
                    while k < marker.count, buf[i + k] == marker[k] { k += 1 }
                    if k == marker.count { return true }
                }
                i += 1
            }
            return false
        }
    }

    static let apiRequest = Array(#""type":"api-request"#.utf8)
}
