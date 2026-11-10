import Foundation

/// One line of the Terminal view: thinking, something said, a command, a file change or a tool call.
public struct LiveItem: Sendable, Equatable, JSONRepresentable {
    public var id: String
    public var t: Int?
    public var k: String
    public var text: String
    public var hidden: Bool?
    public var note: String?
    public var bg: Bool?
    public var body: String?
    public var quiet: Bool?
    public var open: Bool?
    public var out: String?
    public var err: Bool?
    public var sub: String?

    public var json: JSON {
        var o = JSONObject(["id": .string(id), "t": JSON(t), "k": .string(k), "text": .string(text)])
        if let hidden { o["hidden"] = .bool(hidden) }
        if let note { o["note"] = .string(note) }
        if let bg { o["bg"] = .bool(bg) }
        if let body { o["body"] = .string(body) }
        if let quiet { o["quiet"] = .bool(quiet) }
        if let open { o["open"] = .bool(open) }
        if let out { o["out"] = .string(out) }
        if let err { o["err"] = .bool(err) }
        if let sub { o["sub"] = .string(sub) }
        return .object(o)
    }
}

/// The end of a background command's output file.
public struct TaskTail: Sendable, Equatable, JSONRepresentable {
    public var id: String
    public var mtime: Int
    public var size: Int
    public var tail: String

    public var json: JSON { ["id": .string(id), "mtime": .int(mtime), "size": .int(size), "tail": .string(tail)] }
}

/// The Terminal feed, as server.py's `parse_live` and `background_tasks` build it.
public final class LiveFeed: @unchecked Sendable {
    public static let bytes = 1_500_000
    public static let maxItems = 300
    public static let maxOutput = 4000
    static let taskTail = 6000
    static let taskRecent: TimeInterval = 15 * 60

    let paths: HivePaths
    let naming: Naming
    let now: @Sendable () -> Date
    private let lock = NSLock()
    private var cache: [(path: String, size: Int, mtime: TimeInterval, items: [LiveItem])] = []

    public init(paths: HivePaths, now: @escaping @Sendable () -> Date = Date.init) {
        self.paths = paths
        naming = Naming(paths: paths)
        self.now = now
    }

    public func items(transcript: URL, sub: String?) -> [LiveItem] {
        let path = transcript.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { return [] }
        lock.lock()
        if let hit = cache.first(where: { $0.path == path }), hit.size == size, hit.mtime == mtime {
            lock.unlock()
            return hit.items
        }
        lock.unlock()
        guard let lines = try? TailFile.lines(transcript, size: size, want: Self.bytes) else { return [] }
        var items = paths.isAntigravity(transcript) ? AntigravityTranscript.live(lines, naming: naming) : parse(lines)
        if let sub { for n in items.indices { items[n].sub = sub } }
        items = Array(items.suffix(Self.maxItems))
        lock.lock()
        cache.removeAll { $0.path == path }
        cache.append((path, size, mtime, items))
        if cache.count > 60 { cache.removeFirst() }
        lock.unlock()
        return items
    }

    func parse(_ lines: [ArraySlice<UInt8>]) -> [LiveItem] {
        var items: [LiveItem] = []
        var byID: [String: Int] = [:]
        for raw in lines {
            if raw.isEmpty || TailFile.hasPrefixMarker(raw, TailFile.apiRequest) { continue }
            guard let d = TailFile.object(raw) else { continue }
            let kind = d["type"]?.string
            guard kind == "assistant" || kind == "user", !d["isMeta"].truthy else { continue }
            let ts = Epoch.parse(d["timestamp"])
            let uuid = d["uuid"].truthy ? Py.str(d["uuid"]!) : ts.map(String.init) ?? "None"
            let msg = d["message"]?.object ?? JSONObject()
            for (i, item) in TranscriptReader.parts(msg["content"]).enumerated() {
                guard let part = item.object else { continue }
                let ptype = part["type"]?.string
                let uid = "\(uuid):\(i)"
                if kind == "assistant", ptype == "thinking" {
                    // Most thinking blocks are stored with an empty text and only a signature.
                    let text = Text.strip(Py.str(orEmpty: part["thinking"]))
                    items.append(LiveItem(id: uid, t: ts, k: "think", text: Text.prefix(text, 12000), hidden: text.isEmpty))
                } else if kind == "assistant", ptype == "redacted_thinking" {
                    items.append(LiveItem(id: uid, t: ts, k: "think", text: "", hidden: true))
                } else if kind == "assistant", ptype == "text", !Text.strip(Py.str(orEmpty: part["text"])).isEmpty {
                    items.append(LiveItem(id: uid, t: ts, k: "say", text: Text.prefix(Text.strip(Py.str(part["text"]!)), 6000)))
                } else if kind == "assistant", ptype == "tool_use" {
                    let inp = part["input"]?.object ?? JSONObject()
                    let partID = part["id"].truthy ? Py.str(part["id"]!) : nil
                    let name = part["name"].truthy ? Py.str(part["name"]!) : "tool"
                    if var entry = entry(id: partID ?? uid, ts: ts, name: name, inp: inp) {
                        entry.open = true
                        items.append(entry)
                        if let partID { byID[partID] = items.count - 1 }
                    }
                } else if kind == "user", ptype == "tool_result" {
                    let useID = part["tool_use_id"].map(Py.str) ?? ""
                    if let n = byID[useID] {
                        items[n].open = nil
                        items[n].out = Self.clipOutput(part["content"])
                        if part["is_error"].truthy { items[n].err = true }
                    }
                } else if kind == "user", ptype == "text" {
                    let text = Text.strip(Patterns.cleanPrompt(Py.str(orEmpty: part["text"])))
                    if !text.isEmpty, !Text.matches(Patterns.eventTag, text) {
                        items.append(LiveItem(id: uid, t: ts, k: "you", text: Text.prefix(text, 3000)))
                    }
                }
            }
        }
        return items
    }

    /// `live_entry`: a terminal line for a tool call, or nil for bookkeeping tools.
    func entry(id: String, ts: Int?, name: String, inp: JSONObject) -> LiveItem? {
        if Patterns.internalTools.contains(name) || name.hasPrefix("mcp__ccd_") || name.hasSuffix("__update_plan")
            || name.hasSuffix("__wrap_up") { return nil }
        func s(_ k: String) -> String { Py.str(orEmpty: inp[k]) }
        switch name {
        case "Bash":
            return LiveItem(id: id, t: ts, k: "cmd", text: Text.prefix(s("command"), Self.maxOutput),
                            note: Text.oneLine(inp["description"], 120), bg: inp["run_in_background"].truthy)
        case "Edit", "MultiEdit":
            return LiveItem(id: id, t: ts, k: "file", text: "Edit " + naming.short(s("file_path")), body: Self.editDiff(inp))
        case "Write":
            let lines = s("content").components(separatedBy: "\n")
            var body = lines.prefix(40).map { "+ " + $0 }.joined(separator: "\n")
            if lines.count > 40 { body += "\n… \(lines.count - 40) more lines" }
            return LiveItem(id: id, t: ts, k: "file", text: "Write " + naming.short(s("file_path")),
                            body: Text.prefix(body, Self.maxOutput))
        case "Read":
            return LiveItem(id: id, t: ts, k: "file", text: "Read " + naming.short(s("file_path")), quiet: true)
        default:
            let (verb, obj, detail) = toolLabel(name: name, input: inp, naming: naming)
            return LiveItem(id: id, t: ts, k: "tool", text: "\(Text.capitalize(verb)) \(obj)", body: Text.prefix(detail, 1500))
        }
    }

    static func editDiff(_ inp: JSONObject) -> String {
        let old = Py.str(orEmpty: inp["old_string"]), new = Py.str(orEmpty: inp["new_string"])
        var lines = old.isEmpty ? [] : old.components(separatedBy: "\n").prefix(30).map { "- " + $0 }
        if !new.isEmpty { lines += new.components(separatedBy: "\n").prefix(30).map { "+ " + $0 } }
        return Text.prefix(lines.joined(separator: "\n"), maxOutput)
    }

    /// Keeps the end of long output, which is where the result and any error are.
    static func clipOutput(_ result: JSON?) -> String {
        var value = result
        if let list = result?.array {
            value = .string(list.compactMap { $0.object }.filter { $0["type"]?.string == "text" }
                .map { Py.str(orEmpty: $0["text"]) }.joined(separator: "\n"))
        }
        let text = Py.str(orEmpty: value)
        let n = Text.length(text)
        if n > maxOutput {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.groupingSeparator = ","
            f.usesGroupingSeparator = true
            f.locale = Locale(identifier: "en_US_POSIX")
            let count = f.string(from: NSNumber(value: n - maxOutput)) ?? String(n - maxOutput)
            return "[\(count) earlier characters not shown]\n" + Text.suffix(text, maxOutput)
        }
        return text
    }

    /// Output files of commands the session sent to the background, Claude Code's and Antigravity's task logs.
    /// These grow while they run.
    public func backgroundTasks(sessionId: String) -> [TaskTail] {
        guard Patterns.isID(sessionId) else { return [] }
        let fm = FileManager.default
        let root = paths.tasksRoot.path
        var out: [TaskTail] = []
        for project in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            out += tasks(in: "\(root)/\(project)/\(sessionId)/tasks", suffix: ".output")
        }
        out += tasks(in: paths.antigravityConversation(sessionId).appending(path: "tasks").path, suffix: ".log")
        return Array(out.stableSorted { $0.mtime > $1.mtime }.prefix(6))
    }

    /// The recent, non-empty files ending in `suffix` in one folder, each with the end of its text.
    private func tasks(in dir: String, suffix: String) -> [TaskTail] {
        let fm = FileManager.default
        let nowTs = now().timeIntervalSince1970
        var out: [TaskTail] = []
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(suffix) {
            let path = dir + "/" + name
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let size = (attrs[.size] as? NSNumber)?.intValue,
                  let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
                  nowTs - mtime <= Self.taskRecent, size > 0,
                  let handle = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? handle.close() }
            try? handle.seek(toOffset: UInt64(max(0, size - Self.taskTail)))
            let data = (try? handle.readToEnd()) ?? Data()
            out.append(TaskTail(id: String(name.dropLast(suffix.count)), mtime: Int(mtime.rounded(.down)),
                                size: size, tail: Patterns.stripANSI(String(decoding: data, as: UTF8.self))))
        }
        return out
    }
}
