import Foundation

/// Google Antigravity's transcripts (`brain/<id>/.system_generated/logs/transcript.jsonl`): one step per line,
/// `USER_INPUT`, `PLANNER_RESPONSE` (text, thinking, tool calls, tokens) and `GENERIC` (a tool's result).
/// Read as server.py's `scan_antigravity_lines` and `parse_antigravity_live` read them.
enum AntigravityTranscript {
    /// Antigravity's transcripts don't record the model.
    static let model = "Gemini"

    private static let userRequest = try! NSRegularExpression(pattern: "<USER_REQUEST>(.*?)</USER_REQUEST>",
                                                              options: [.dotMatchesLineSeparators])

    /// A user step's text: the part inside `<USER_REQUEST>` when there is one.
    static func request(_ value: JSON?) -> String {
        let content = Py.str(orEmpty: value)
        guard content.contains("<USER_REQUEST>"), let inside = Text.firstGroup(userRequest, content) else { return content }
        return Text.strip(inside)
    }

    /// A tool call's arguments: an object, or a JSON string holding one.
    static func arguments(_ value: JSON?) -> JSONObject {
        guard let value, value.truthy else { return JSONObject() }
        if case .string(let s) = value { return (try? JSON.parse(s))?.object ?? JSONObject() }
        return value.object ?? JSONObject()
    }

    static func stepID(_ d: JSONObject) -> String { Py.str(d["step_index"] ?? .null) }

    /// `scan_antigravity_lines`.
    static func scan(_ lines: [ArraySlice<UInt8>], naming: Naming) -> TranscriptTail {
        var out = TranscriptTail()
        out.model = model
        out.turnEnded = true
        var events: [TranscriptEvent] = []
        var seenSays = Set<String>()
        for raw in lines {
            guard let d = TailFile.object(raw) else { continue }
            let type = d["type"]?.string
            let step = stepID(d)
            let ts = Epoch.parse(d["created_at"])
            if let ts, ts != 0 { out.lastTs = ts }
            let input = d["input_tokens"], cached = d["cache_read_tokens"]
            if input.truthy || cached.truthy {
                out.contextTokens = Py.int(orZero: input) + Py.int(orZero: cached)
            }

            switch type {
            case "USER_INPUT":
                let content = request(d["content"])
                out.prompt = content
                out.promptTs = ts
                out.ask = nil
                out.askTs = nil
                out.recap = nil
                out.pending = []
                out.turnEnded = false
                events.append(TranscriptEvent(id: "\(step):you", t: ts, k: "you", title: Text.oneLine(content),
                                              body: Text.prefix(content, 3000)))

            case "PLANNER_RESPONSE":
                let content = Text.strip(Py.str(orEmpty: d["content"]))
                if !content.isEmpty, content != "None" {
                    out.lastText = content
                    out.lastTextTs = ts
                    out.ask = nil
                    out.askTs = nil
                    let key = Text.prefix(content, 200)
                    if !seenSays.contains(key) {
                        seenSays.insert(key)
                        events.append(TranscriptEvent(id: "\(step):say", t: ts, k: "say", title: Text.oneLine(content, 70),
                                                      body: Text.prefix(content, 3000)))
                    }
                }
                for call in d["tool_calls"]?.array ?? [] {
                    guard let tc = call.object else { continue }
                    let name = tc["name"].truthy ? Py.str(tc["name"]!) : "tool"
                    let args = arguments(tc["args"])
                    if name == "ask_question" {
                        out.ask = question(args["questions"])
                        out.askTs = ts
                    } else {
                        out.ask = nil
                        out.askTs = nil
                    }
                    let (verb, title, body) = label(name, args, naming: naming)
                    let ev = TranscriptEvent(id: "\(step):\(name)", t: ts, k: "tool", title: title,
                                             body: Text.prefix(body, 1500), verb: verb, tool: name)
                    events.append(ev)
                    out.pending = [ev]
                }

            case "GENERIC":
                out.pending = []
                out.ask = nil
                out.askTs = nil
                out.turnEnded = true

            default:
                break
            }
        }
        out.events = Array(events.suffix(TranscriptReader.maxEvents))
        return out
    }

    /// The question an `ask_question` call asks: the first one's text, or "Question".
    static func question(_ value: JSON?) -> String? {
        var list = value
        if case .string(let s)? = value { list = (try? JSON.parse(s)) ?? .array([]) }
        guard let items = list?.array, let first = items.first else { return "Question" }
        guard let q = first.object?["question"], !q.isNull else { return nil }
        return Py.str(q)
    }

    /// (verb, title, detail) for a tool call, as `scan_antigravity_lines` names them.
    static func label(_ name: String, _ args: JSONObject, naming: Naming) -> (String, String, String) {
        let summary = Py.str(orEmpty: args["toolSummary"])
        func value(_ key: String) -> String { args[key].map(Py.str) ?? "" }
        func firstTruthy(_ keys: String...) -> String {
            keys.lazy.compactMap { args[$0] }.first { $0.truthy }.map(Py.str) ?? ""
        }
        switch name {
        case "run_command":
            return ("run", summary.isEmpty ? "Run \(Text.prefix(value("CommandLine"), 60))" : summary, value("CommandLine"))
        case "read_file", "read_resource":
            let path = firstTruthy("Path", "Uri")
            return ("read", "Read \(naming.short(path))", path)
        case "edit_file", "write_file":
            let path = firstTruthy("Path")
            return ("write", "Write \(naming.short(path))", path)
        case "search_web", "call_mcp_tool":
            return ("web", "Search \(value("query"))", Py.repr(.object(args)))
        case "invoke_subagent":
            return ("tool", "Subagent: \(value("Role"))", value("Prompt"))
        default:
            return ("tool", summary.isEmpty ? "Use \(name)" : summary, Py.repr(.object(args)))
        }
    }

    /// `parse_antigravity_live`: the Terminal view's lines for one transcript.
    static func live(_ lines: [ArraySlice<UInt8>], naming: Naming) -> [LiveItem] {
        var items: [LiveItem] = []
        for raw in lines {
            guard let d = TailFile.object(raw) else { continue }
            let ts = Epoch.parse(d["created_at"])
            let uid = "step:\(stepID(d))"
            switch d["type"]?.string {
            case "USER_INPUT":
                items.append(LiveItem(id: uid, t: ts, k: "you", text: Text.prefix(request(d["content"]), 3000)))
            case "PLANNER_RESPONSE":
                let thinking = Text.strip(Py.str(orEmpty: d["thinking"]))
                if !thinking.isEmpty {
                    items.append(LiveItem(id: "\(uid):think", t: ts, k: "think", text: Text.prefix(thinking, 12000)))
                }
                let content = Text.strip(Py.str(orEmpty: d["content"]))
                if !content.isEmpty {
                    items.append(LiveItem(id: "\(uid):say", t: ts, k: "say", text: Text.prefix(content, 6000)))
                }
                for call in d["tool_calls"]?.array ?? [] {
                    guard let tc = call.object else { continue }
                    let name = tc["name"].truthy ? Py.str(tc["name"]!) : "tool"
                    let args = arguments(tc["args"])
                    let summary = Py.str(orEmpty: args["toolSummary"])
                    let id = "\(uid):\(name)"
                    switch name {
                    case "run_command":
                        items.append(LiveItem(id: id, t: ts, k: "cmd", text: Text.prefix(args["CommandLine"].map(Py.str) ?? "",
                                                                                         LiveFeed.maxOutput),
                                              note: summary, open: true))
                    case "read_file", "read_resource":
                        let path = ["Path", "Uri"].lazy.compactMap { args[$0] }.first { $0.truthy }.map(Py.str) ?? ""
                        items.append(LiveItem(id: id, t: ts, k: "file", text: "Read \(naming.short(path))", quiet: true, open: true))
                    case "edit_file", "write_file":
                        let path = args["Path"].map(Py.str) ?? ""
                        items.append(LiveItem(id: id, t: ts, k: "file", text: "Write \(naming.short(path))", open: true))
                    default:
                        items.append(LiveItem(id: id, t: ts, k: "tool", text: summary.isEmpty ? "Use \(name)" : summary,
                                              body: Text.prefix(Py.repr(.object(args)), 1500), open: true))
                    }
                }
            case "GENERIC":
                if d["content"].truthy, let last = items.indices.last, items[last].open == true {
                    items[last].open = nil
                    items[last].out = LiveFeed.clipOutput(d["content"])
                }
            default:
                break
            }
        }
        return items
    }
}
