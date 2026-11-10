import Foundation

/// Shared patterns and names from server.py.
enum Patterns {
    static let id = try! NSRegularExpression(pattern: #"^[A-Za-z0-9_-]{6,80}$"#)
    static let ansi = try! NSRegularExpression(pattern: "\u{1b}\\[[0-9;?]*[A-Za-z]|\u{1b}\\][^\u{07}]*\u{07}")
    static let noiseTag = try! NSRegularExpression(
        pattern: #"<(system-reminder|command-message|command-args|local-command-caveat)\b[^>]*>.*?</\1>"#,
        options: [.dotMatchesLineSeparators])
    static let pasteTag = try! NSRegularExpression(pattern: #"</?pasted_content\b[^>]*>"#)
    static let eventTag = try! NSRegularExpression(pattern: #"^\s*<([a-z][a-z0-9-]*)\b"#)
    static let mcpUUID = try! NSRegularExpression(pattern: #"^[0-9a-f]{8}-"#)

    static let eventNames: [String: String] = [
        "ci-monitor-event": "Pull request update from the app",
        "side-sessions-event": "Update from a linked session",
        "task-notification": "Background task finished",
        "command-name": "Slash command",
        "local-command-stdout": "Slash command output",
        "bash-input": "Shell command you ran",
        "bash-stdout": "Shell output",
    ]
    static let internalTools: Set<String> = ["TodoWrite", "ToolSearch", "ReadNotifications"]

    static func isID(_ s: String) -> Bool { Text.matches(id, s) }

    /// Removes system reminders and pasted-content tags from what a person typed.
    static func cleanPrompt(_ text: String) -> String {
        Text.sub(pasteTag, "", Text.sub(noiseTag, "", text))
    }

    static func stripANSI(_ text: String) -> String { Text.sub(ansi, "", text) }
}

/// How paths and folders read to a person, given the user's home folder.
public struct Naming: Sendable {
    public let home: String

    public init(home: String) {
        self.home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
    }

    public init(paths: HivePaths) { self.init(home: paths.home.path) }

    /// `short_path`: `~/x` for paths inside the home folder.
    public func shortPath(_ p: String?) -> String? {
        guard let p, !p.isEmpty else { return p }
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    func short(_ p: String) -> String { shortPath(p) ?? p }

    private static let worktree = try! NSRegularExpression(pattern: #"^(.*)/\.claude/worktrees/([^/]+)"#)
    private static let projects = try! NSRegularExpression(pattern: #"/Projects/([^/]+)"#)

    /// `project_of`: the project and worktree names for a working folder.
    public func projectOf(_ cwdIn: String?) -> (project: String, worktree: String?) {
        guard var cwd = cwdIn, !cwd.isEmpty else { return ("Unknown", nil) }
        if cwd.contains("/scratch-workspaces/") { return ("No folder", nil) }
        var worktree: String?
        let ns = cwd as NSString
        if let m = Self.worktree.firstMatch(in: cwd, range: NSRange(location: 0, length: ns.length)) {
            worktree = ns.substring(with: m.range(at: 2))
            cwd = ns.substring(with: m.range(at: 1))
        }
        if let name = Text.firstGroup(Self.projects, cwd) { return (name, worktree) }
        let trimmed = rstripSlash(cwd)
        if trimmed == home { return ("Home folder", worktree) }
        let base = Text.basename(trimmed)
        return (base.isEmpty ? cwd : base, worktree)
    }

    private func rstripSlash(_ s: String) -> String {
        var s = Substring(s)
        while s.hasSuffix("/") { s = s.dropLast() }
        return String(s)
    }
}

let verbIng: [String: String] = [
    "run": "Running", "read": "Reading", "edit": "Editing", "write": "Writing",
    "search": "Searching", "fetch": "Fetching", "start": "Starting", "use": "Using",
    "ask": "Asking", "open": "Opening", "send": "Sending", "take": "Taking",
]

/// `split_mcp`: the friendly server name and tool name of an MCP tool.
func splitMCP(_ name: String) -> (server: String, tool: String) {
    let parts = name.components(separatedBy: "__")
    let server = parts.count > 1 ? parts[1] : ""
    let tool = (parts.last ?? "").replacingOccurrences(of: "_", with: " ")
    var friendly = server.replacingOccurrences(of: "Claude_", with: "").replacingOccurrences(of: "_", with: " ")
    if Text.matches(Patterns.mcpUUID, server) { friendly = "" }
    if server.hasPrefix("plugin_") {
        let bits = server.components(separatedBy: "_")
        friendly = bits.count > 1 ? bits[1] : ""
    }
    return (friendly, tool)
}

/// `tool_label`: a verb, an object and the full detail for a tool call, in words instead of JSON.
func toolLabel(name: String, input: JSONObject, naming: Naming) -> (verb: String, object: String, detail: String) {
    func s(_ key: String) -> String { Py.str(orEmpty: input[key]) }
    func dumped() -> String { input.isEmpty ? "" : Text.prefix(JSON.object(input).serializedString, 1500) }
    switch name {
    case "Bash":
        let cmd = s("command")
        let desc = input["description"].truthy ? s("description") : cmd
        return ("run", Text.oneLine(desc, 90), cmd)
    case "Read", "Edit", "Write", "NotebookEdit", "MultiEdit":
        let path = input["file_path"].truthy ? s("file_path") : input["notebook_path"].truthy ? s("notebook_path") : s("path")
        let verb = name == "Read" ? "read" : name == "Write" ? "write" : "edit"
        let base = Text.basename(path)
        return (verb, base.isEmpty ? "a file" : base, naming.short(path))
    case "Grep", "Glob":
        let pat = s("pattern")
        return ("search", "for " + Text.oneLine(pat, 70), pat)
    case "Agent", "Task":
        let desc = input["description"].truthy ? s("description") : s("subagent_type")
        return ("start", "subagent: " + Text.oneLine(desc, 80), Text.prefix(s("prompt"), 3000))
    case "WebSearch":
        return ("search", "the web for " + Text.oneLine(input["query"], 70), s("query"))
    case "WebFetch":
        return ("fetch", Text.oneLine(input["url"], 80), s("url"))
    case "AskUserQuestion":
        var q: JSON?
        if let qs = input["questions"]?.array, let first = qs.first, let o = first.object { q = o["question"] }
        return ("ask", Text.oneLine(q, 140), "")
    case "ExitPlanMode":
        return ("ask", "you to approve the plan", Text.prefix(s("plan"), 3000))
    case "Skill":
        return ("use", "skill " + Text.oneLine(input["skill"], 60), "")
    default:
        if name.hasPrefix("mcp__") {
            let (server, tool) = splitMCP(name)
            return ("use", server.isEmpty ? tool : server + ": " + tool, dumped())
        }
        return ("use", name, dumped())
    }
}
