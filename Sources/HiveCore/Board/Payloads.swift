import Foundation

/// One row of `/api/board`: a live or recently ended session.
public struct BoardRow: Sendable, JSONRepresentable {
    public var id: String
    public var pid: Int?
    public var name: String
    public var project: String
    public var worktree: String?
    public var branch: String?
    public var cwd: String?
    /// Antigravity only: the conversation in Antigravity's own web page.
    public var webUrl: String?
    public var group: String
    public var reason: String?
    public var headline: String
    public var doing: String?
    public var statusSince: Int?
    public var lastTs: Int?
    public var model: String?
    public var effort: String?
    public var subagentsRunning: Int
    public var subagentsTotal: Int
    public var helpers: [Helper]?
    /// Open questions in plain text, for reason `questions`; empty otherwise, and absent on ended rows.
    public var questions: [String]?
    public var plan: JSON
    public var hostId: String?
    public var entry: String?
    /// `google` for Google Antigravity conversations; nil for Claude Code.
    public var provider: String?
    public var version: String?
    public var startedAt: Int?
    public var uptime: Int?
    public var live: Bool
    public var quiet: Bool?
    public var canReply = false
    public var replyNote: String?

    public var json: JSON {
        var o = JSONObject([
            "id": .string(id), "pid": JSON(pid), "name": .string(name), "project": .string(project),
            "worktree": JSON(worktree), "branch": JSON(branch), "cwd": JSON(cwd),
        ])
        if provider != nil { o["webUrl"] = JSON(webUrl) }
        o["group"] = .string(group)
        o["reason"] = JSON(reason)
        o["headline"] = .string(headline)
        if live || provider != nil { o["doing"] = JSON(doing) }
        o["statusSince"] = JSON(statusSince)
        o["lastTs"] = JSON(lastTs)
        o["model"] = JSON(model)
        o["effort"] = JSON(effort)
        o["subagents"] = ["running": .int(subagentsRunning), "total": .int(subagentsTotal)]
        if let helpers { o["helpers"] = helpers.json }
        if let questions { o["questions"] = .array(questions.map(JSON.string)) }
        o["plan"] = plan
        o["hostId"] = JSON(hostId)
        o["entry"] = JSON(entry)
        if let provider { o["provider"] = .string(provider) }
        o["version"] = JSON(version)
        o["startedAt"] = JSON(startedAt)
        o["uptime"] = JSON(uptime)
        o["live"] = .bool(live)
        if let quiet { o["quiet"] = .bool(quiet) }
        o["canReply"] = .bool(canReply)
        o["replyNote"] = JSON(replyNote)
        return .object(o)
    }
}

/// Everything one board refresh produced.
public struct BoardState: Sendable {
    public var ready = false
    public var rows: [BoardRow] = []
    public var raws: [String: SessionFile] = [:]
    public var processes: [Int32: ProcRecord] = [:]
    public var mac: JSON = .null
    public var generatedAt = 0
    public var capabilities: JSON = ["reply": false]

    public static let empty = BoardState()

    public func row(_ id: String) -> BoardRow? { rows.first { $0.id == id } }

    public var counts: JSON {
        guard ready else { return .object(JSONObject()) }
        var o = JSONObject()
        for g in ["needs", "working", "idle", "ended"] { o[g] = .int(rows.filter { $0.group == g }.count) }
        return .object(o)
    }
}
