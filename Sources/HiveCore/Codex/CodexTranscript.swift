import Foundation

/// Where a Codex thread's latest turn stands, from the end of its rollout.
public struct CodexTurn: Codable, Sendable, Equatable {
    /// True after `task_started`, false after `task_complete` or `turn_aborted`; nil when the tail shows neither.
    public var running: Bool?
    public var startedTs: Int?
    public var endedTs: Int?
    /// The turn ended with an `error`, or was aborted.
    public var failed = false
    /// Questions from `request_user_input_async` (an `AgentMessage` item with `questions`) or a pending
    /// `request_user_input` call, until the next message from you.
    public var questions: [String] = []
    /// A pending call that asked to leave the sandbox (`sandbox_permissions`) or a pending `request_permissions`.
    public var approval: TranscriptEvent?
    /// `turn_context.approval_policy` when it's a plain value (`never`, `on-request`, …).
    public var approvalPolicy: String?

    public init() {}
}

/// Codex's rollouts (`~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl`): one `{timestamp, type, payload}`
/// object per line. `session_meta` opens the file; each turn is `task_started` … `task_complete` (`event_msg`),
/// with a `turn_context`, `response_item`s (messages, `function_call` / `custom_tool_call` and their outputs,
/// encrypted reasoning) and, in paginated rollouts, `item_completed` events.
///
/// Codex never writes its approval and question requests (`exec_approval_request`, `apply_patch_approval_request`,
/// `request_user_input`, `request_permissions`) to the rollout: its rollout policy treats them as transient. So a
/// request shows only as the call that caused it, still without an output.
enum CodexTranscript {
    static let injected = ["<environment_context", "<user_instructions", "<turn_aborted", "<user_shell_command",
                           "<subagent_notification", "# AGENTS.md instructions"]
    static let commandLiteral = try! NSRegularExpression(
        pattern: #"tools\.exec_command\(\s*\{\s*"?cmd"?\s*:\s*(`(?:[^`\\]|\\.)*`|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')"#)
    static let toolName = try! NSRegularExpression(pattern: #"tools\.([A-Za-z_][A-Za-z0-9_]*)\s*\("#)
    static let patchFile = try! NSRegularExpression(pattern: #"(?m)^\*\*\* (?:Update|Add|Delete) File: (.+)$"#)
    static let escalation = try! NSRegularExpression(pattern: #"\b(require_escalated|with_additional_permissions)\b"#)

    /// The text of a message's `content` list (`input_text`, `output_text` or `text` parts).
    static func text(_ content: JSON?) -> String {
        if let s = content?.string { return Text.strip(s) }
        let parts = (content?.array ?? []).compactMap { $0.object }
            .filter { ["input_text", "output_text", "text"].contains($0["type"]?.string ?? "") }
            .map { Py.str(orEmpty: $0["text"]) }
        return Text.strip(parts.joined(separator: "\n"))
    }

    /// Text Codex adds to the conversation itself: environment details, AGENTS.md, notifications.
    static func isInjected(_ text: String) -> Bool { injected.contains { text.hasPrefix($0) } }

    /// A call's arguments: `function_call.arguments` is a JSON string.
    static func arguments(_ value: JSON?) -> JSONObject {
        if let s = value?.string { return (try? JSON.parse(s))?.object ?? JSONObject() }
        return value?.object ?? JSONObject()
    }

    /// A call's output as text: a string, a list of text parts, or legacy `{"output": …}` JSON.
    static func output(_ value: JSON?) -> (text: String, failed: Bool) {
        if let s = value?.string {
            if s.hasPrefix("{"), let o = (try? JSON.parse(s))?.object, o["output"] != nil {
                let code = o["metadata"]?["exit_code"]?.int ?? 0
                return (Py.str(orEmpty: o["output"]), code != 0)
            }
            return (s, false)
        }
        if let list = value?.array {
            return (list.compactMap { $0.object }.filter { $0["type"]?.string == "text" || $0["type"]?.string == "input_text" }
                .map { Py.str(orEmpty: $0["text"]) }.joined(separator: "\n"), false)
        }
        if let o = value?.object { return (Py.str(orEmpty: o["content"]), o["success"]?.bool == false) }
        return ("", false)
    }

    /// The command a shell call runs: `cmd` (`exec_command`), `command` as a list or a string (`shell`,
    /// `shell_command`, `local_shell_call`).
    static func command(_ args: JSONObject) -> String? {
        if let cmd = args["cmd"]?.string { return cmd }
        if let list = args["command"]?.array {
            let words = list.compactMap(\.string)
            // ["bash", "-lc", "<script>"] reads better as the script.
            if words.count == 3, ["bash", "zsh", "sh"].contains(Text.basename(words[0])), words[1].hasPrefix("-") {
                return words[2]
            }
            return words.joined(separator: " ")
        }
        return args["command"]?.string
    }

    /// The commands a code-mode `exec` call starts with `tools.exec_command({cmd: …})`.
    static func commands(inCode code: String) -> [String] {
        let ns = code as NSString
        return commandLiteral.matches(in: code, range: NSRange(location: 0, length: ns.length)).map {
            let literal = ns.substring(with: $0.range(at: 1))
            let inner = String(literal.dropFirst().dropLast())
            if literal.hasPrefix("\""), let s = (try? JSON.parse("\"\(inner)\""))?.string { return s }
            return inner.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\`", with: "`")
        }
    }

    static func patchFiles(_ patch: String) -> [String] {
        let ns = patch as NSString
        return patchFile.matches(in: patch, range: NSRange(location: 0, length: ns.length)).map {
            Text.strip(ns.substring(with: $0.range(at: 1)))
        }
    }

    /// (verb, title, detail) for a call, with the title starting with the capitalised verb.
    static func label(name: String, namespace: String?, args: JSONObject, input: String?,
                      naming: Naming) -> (String, String, String) {
        func run(_ cmd: String) -> (String, String, String) { ("run", "Run " + Text.oneLine(cmd, 80), cmd) }
        switch name {
        case "exec_command", "shell", "shell_command", "local_shell_call", "container.exec":
            return run(command(args) ?? "")
        case "apply_patch":
            let patch = input ?? Py.str(orEmpty: args["input"] ?? args["patch"])
            let files = patchFiles(patch)
            let what = files.isEmpty ? "files" : naming.short(files[0]) + (files.count > 1 ? " and \(files.count - 1) more" : "")
            return ("edit", "Edit " + what, Text.prefix(patch, 1500))
        case "view_image":
            let path = Py.str(orEmpty: args["path"])
            return ("read", "View " + naming.short(path), path)
        case "web_search", "web__run", "search_query":
            let query = Py.str(orEmpty: args["query"] ?? args["q"])
            return ("search", query.isEmpty ? "Search the web" : "Search " + Text.oneLine(query, 80), Py.repr(.object(args)))
        case "request_user_input", "request_user_input_async":
            let qs = questions(args["questions"])
            return ("ask", "Ask " + (qs.first ?? "a question"), qs.joined(separator: "\n"))
        case "request_permissions":
            let why = Py.str(orEmpty: args["reason"] ?? args["justification"])
            return ("ask", "Ask for permission" + (why.isEmpty ? "" : ": " + Text.oneLine(why, 80)), Py.repr(.object(args)))
        case "send_message_to_user_async":
            let message = Py.str(orEmpty: args["message"])
            return ("use", "Send you a message", Text.prefix(message, 1500))
        case "wait", "write_stdin":
            return ("wait", "Wait for a running command", Py.repr(.object(args)))
        case "sleep":
            return ("wait", "Wait", Py.repr(.object(args)))
        case "js":
            let title = Py.str(orEmpty: args["title"])
            return ("use", title.isEmpty ? "Use JavaScript" : "Use " + Text.oneLine(title, 80),
                    Text.prefix(Py.str(orEmpty: args["code"]), 1500))
        case "exec":
            let code = input ?? ""
            if let cmd = commands(inCode: code).first { return ("run", "Run " + Text.oneLine(cmd, 80), Text.prefix(code, 1500)) }
            let ns = code as NSString
            let tools = toolName.matches(in: code, range: NSRange(location: 0, length: ns.length))
                .map { ns.substring(with: $0.range(at: 1)) }
            if tools.contains("apply_patch") {
                let files = patchFiles(code)
                return ("edit", "Edit " + (files.first.map(naming.short) ?? "files"), Text.prefix(code, 1500))
            }
            if tools.contains("view_image") { return ("read", "View an image", Text.prefix(code, 1500)) }
            if tools.contains(where: { $0.hasPrefix("web") }) { return ("search", "Search the web", Text.prefix(code, 1500)) }
            if let first = tools.first { return ("use", "Use " + first, Text.prefix(code, 1500)) }
            return ("run", "Run code", Text.prefix(code, 1500))
        default:
            let server = namespace.flatMap { $0.hasPrefix("mcp__") ? String($0.dropFirst(5)) : nil }
            let shown = server.map { "\($0) \(name)" } ?? name
            return ("use", "Use " + shown, Text.prefix(input ?? Py.repr(.object(args)), 1500))
        }
    }

    /// Question titles from `request_user_input(_async)` arguments or an `AgentMessage` item's `questions`.
    static func questions(_ value: JSON?) -> [String] {
        (value?.array ?? []).compactMap { q -> String? in
            if let s = q.string { return s }
            let o = q.object ?? JSONObject()
            let text = ["title", "question", "header"].lazy.compactMap { o[$0]?.string }.first { !$0.isEmpty }
            return text.map { Text.strip($0) }
        }
    }

    /// Whether a call asked to run outside the sandbox, which needs your approval unless the policy is `never`.
    static func asksToEscalate(name: String, args: JSONObject, input: String?) -> Bool {
        if name == "request_permissions" { return true }
        if let mode = args["sandbox_permissions"]?.string, mode == "require_escalated" || mode == "with_additional_permissions" {
            return true
        }
        if args["with_escalated_permissions"]?.bool == true { return true }
        if let input, Text.matches(escalation, input) { return true }
        return false
    }

    static func scan(_ lines: [ArraySlice<UInt8>], naming: Naming) -> TranscriptTail {
        var out = TranscriptTail()
        var turn = CodexTurn()
        var events: [TranscriptEvent] = []
        var byCall: [String: Int] = [:]
        var pendingOrder: [String] = []
        var escalated = Set<String>()
        var seenSays = Set<String>()
        var seenYou = Set<String>()

        func you(_ raw: String, _ ts: Int?, _ id: String) {
            let text = Text.strip(raw)
            if text.isEmpty || isInjected(text) { return }
            let key = Text.prefix(text, 200)
            out.prompt = text
            out.promptTs = ts
            out.ask = nil
            out.askTs = nil
            out.turnEnded = false
            turn.questions = []
            // A paginated rollout records your message twice: as a `message` and as a `UserMessage` item.
            if seenYou.contains(key) { return }
            seenYou.insert(key)
            events.append(TranscriptEvent(id: id, t: ts, k: "you", title: Text.oneLine(text), body: Text.prefix(text, 3000)))
        }

        func say(_ raw: String, _ ts: Int?, _ id: String) {
            let text = Text.strip(raw)
            if text.isEmpty { return }
            out.lastText = text
            out.lastTextTs = ts
            let key = Text.prefix(text, 200)
            if seenSays.contains(key) { return }
            seenSays.insert(key)
            events.append(TranscriptEvent(id: id, t: ts, k: "say", title: Text.oneLine(text, 70), body: Text.prefix(text, 3000)))
        }

        func call(_ p: JSONObject, ts: Int?, line: Int) {
            let name = Py.str(orEmpty: p["name"] ?? (p["type"]?.string == "local_shell_call" ? JSON.string("local_shell_call") : nil))
            let callID = Py.str(orEmpty: p["call_id"] ?? p["id"])
            var args = arguments(p["arguments"])
            if p["type"]?.string == "local_shell_call", let action = p["action"]?.object { args = action }
            let input = p["input"]?.string
            if name == "update_plan" {
                out.plan = (args["plan"]?.array ?? []).compactMap { $0.object }.map {
                    PlanItem(text: Py.str(orEmpty: $0["step"]), state: $0["status"].truthy ? Py.str($0["status"]!) : "pending")
                }
                return
            }
            let (verb, title, body) = label(name: name.isEmpty ? "tool" : name, namespace: p["namespace"]?.string,
                                            args: args, input: input, naming: naming)
            let id = callID.isEmpty ? "\(line):call" : callID
            events.append(TranscriptEvent(id: id, t: ts, k: "tool", title: title, body: body, verb: verb,
                                          tool: name.isEmpty ? "tool" : name))
            if name == "request_user_input" {
                let qs = questions(args["questions"])
                out.ask = qs.first ?? "Question"
                out.askTs = ts
                turn.questions = qs
            }
            guard !callID.isEmpty else { return }
            byCall[callID] = events.count - 1
            pendingOrder.removeAll { $0 == callID }
            pendingOrder.append(callID)
            if asksToEscalate(name: name, args: args, input: input) { escalated.insert(callID) }
        }

        func result(_ p: JSONObject) {
            let callID = Py.str(orEmpty: p["call_id"])
            pendingOrder.removeAll { $0 == callID }
            escalated.remove(callID)
            guard let n = byCall[callID] else { return }
            let (text, failed) = output(p["output"])
            events[n].out = Text.prefix(text, 1000)
            if failed { events[n].err = true }
            if events[n].tool == "request_user_input" {
                out.ask = nil
                out.askTs = nil
                turn.questions = []
            }
        }

        func endTurn(_ ts: Int?) {
            turn.running = false
            turn.endedTs = ts
            out.turnEnded = true
            pendingOrder.removeAll()
            escalated.removeAll()
            seenYou.removeAll()
        }

        for (line, raw) in lines.enumerated() {
            guard let d = TailFile.object(raw), let type = d["type"]?.string else { continue }
            let p = d["payload"]?.object ?? JSONObject()
            let ts = Epoch.parse(d["timestamp"])
            if let ts, ts != 0 { out.lastTs = ts }
            let ptype = p["type"]?.string
            switch type {
            case "session_meta":
                if p["cwd"].truthy { out.cwd = Py.str(p["cwd"]!) }
                if let branch = p["git"]?["branch"]?.string, !branch.isEmpty, branch != "HEAD" { out.branch = branch }

            case "turn_context":
                if p["cwd"].truthy { out.cwd = Py.str(p["cwd"]!) }
                if p["model"].truthy { out.model = Py.str(p["model"]!) }
                if p["effort"].truthy { out.effort = Py.str(p["effort"]!) }
                turn.approvalPolicy = p["approval_policy"]?.string

            case "event_msg":
                switch ptype {
                case "task_started", "turn_started":
                    turn.running = true
                    turn.startedTs = ts
                    turn.endedTs = nil
                    turn.failed = false
                    out.turnEnded = false
                    out.recap = nil
                case "task_complete", "turn_complete":
                    endTurn(ts)
                    if p["error"].truthy { turn.failed = true }
                    if let last = p["last_agent_message"]?.string { say(last, ts, "\(Py.str(orEmpty: p["turn_id"])):final") }
                case "turn_aborted":
                    endTurn(ts)
                    turn.failed = true
                case "token_count":
                    if let used = p["info"]?["last_token_usage"]?["input_tokens"]?.int, used > 0 { out.contextTokens = used }
                case "user_message":
                    you(Py.str(orEmpty: p["message"]), ts, "\(line):you")
                case "agent_message":
                    say(Py.str(orEmpty: p["message"]), ts, "\(line):say")
                case "item_completed":
                    let item = p["item"]?.object ?? JSONObject()
                    let id = Py.str(orEmpty: item["id"] ?? .string("\(line)"))
                    switch item["type"]?.string {
                    case "UserMessage":
                        you(text(item["content"]), ts, id)
                    case "AgentMessage":
                        say(text(item["content"]), ts, id)
                        let qs = questions(item["questions"])
                        if !qs.isEmpty {
                            turn.questions = qs
                            out.ask = qs[0]
                            out.askTs = ts
                        }
                    default:
                        break
                    }
                default:
                    break
                }

            case "response_item":
                switch ptype {
                case "message":
                    let id = Py.str(orEmpty: p["id"] ?? .string("\(line)"))
                    if p["role"]?.string == "user" { you(text(p["content"]), ts, id) }
                    if p["role"]?.string == "assistant" { say(text(p["content"]), ts, id) }
                case "function_call", "custom_tool_call", "local_shell_call":
                    call(p, ts: ts, line: line)
                case "function_call_output", "custom_tool_call_output", "local_shell_call_output":
                    result(p)
                default:
                    break
                }

            default:
                break
            }
        }

        out.pending = pendingOrder.compactMap { byCall[$0].map { events[$0] } }
        if turn.approvalPolicy != "never", let last = pendingOrder.last(where: { escalated.contains($0) }), let n = byCall[last] {
            turn.approval = events[n]
        }
        out.events = Array(events.suffix(TranscriptReader.maxEvents))
        out.codex = turn
        return out
    }

    /// The Terminal view's lines for one rollout.
    static func live(_ lines: [ArraySlice<UInt8>], naming: Naming) -> [LiveItem] {
        var items: [LiveItem] = []
        var byCall: [String: Int] = [:]
        for (line, raw) in lines.enumerated() {
            guard let d = TailFile.object(raw), d["type"]?.string == "response_item" else { continue }
            let p = d["payload"]?.object ?? JSONObject()
            let ts = Epoch.parse(d["timestamp"])
            let uid = Py.str(orEmpty: p["id"] ?? .string("\(line)"))
            switch p["type"]?.string {
            case "message":
                let body = text(p["content"])
                if body.isEmpty { continue }
                if p["role"]?.string == "user", !isInjected(body) {
                    items.append(LiveItem(id: uid, t: ts, k: "you", text: Text.prefix(body, 3000)))
                } else if p["role"]?.string == "assistant" {
                    items.append(LiveItem(id: uid, t: ts, k: "say", text: Text.prefix(body, 6000)))
                }
            case "reasoning":
                let summary = (p["summary"]?.array ?? []).compactMap { $0.object?["text"]?.string }.joined(separator: "\n")
                let text = Text.strip(summary)
                items.append(LiveItem(id: uid, t: ts, k: "think", text: Text.prefix(text, 12000), hidden: text.isEmpty))
            case "function_call", "custom_tool_call", "local_shell_call":
                let name = Py.str(orEmpty: p["name"] ?? (p["type"]?.string == "local_shell_call" ? JSON.string("local_shell_call") : nil))
                if name == "update_plan" { continue }
                var args = arguments(p["arguments"])
                if p["type"]?.string == "local_shell_call", let action = p["action"]?.object { args = action }
                let input = p["input"]?.string
                let callID = Py.str(orEmpty: p["call_id"])
                let id = callID.isEmpty ? uid : callID
                let (verb, title, body) = label(name: name, namespace: p["namespace"]?.string, args: args, input: input,
                                                naming: naming)
                let shell = ["exec_command", "shell", "shell_command", "local_shell_call"].contains(name)
                let code = name == "exec" ? commands(inCode: input ?? "") : []
                if shell || !code.isEmpty {
                    let cmd = shell ? (command(args) ?? "") : code.joined(separator: "\n")
                    let why = Text.oneLine(args["justification"], 120)
                    items.append(LiveItem(id: id, t: ts, k: "cmd", text: Text.prefix(cmd, LiveFeed.maxOutput),
                                          note: why.isEmpty ? nil : why, open: true))
                } else if verb == "edit" {
                    items.append(LiveItem(id: id, t: ts, k: "file", text: title, body: body, open: true))
                } else if verb == "read" {
                    items.append(LiveItem(id: id, t: ts, k: "file", text: title, quiet: true, open: true))
                } else {
                    items.append(LiveItem(id: id, t: ts, k: "tool", text: title, body: body, open: true))
                }
                if !callID.isEmpty { byCall[callID] = items.count - 1 }
            case "function_call_output", "custom_tool_call_output", "local_shell_call_output":
                guard let n = byCall[Py.str(orEmpty: p["call_id"])] else { continue }
                let (text, failed) = output(p["output"])
                items[n].open = nil
                items[n].out = LiveFeed.clipOutput(.string(text))
                if failed { items[n].err = true }
            default:
                break
            }
        }
        return items
    }
}
