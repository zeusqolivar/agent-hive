import Foundation

/// Parses the end of Claude Code transcripts (`~/.claude/projects/<dir>/<session>.jsonl`) the way
/// server.py's `read_transcript` does, caching each file's result until its size or mtime changes.
public final class TranscriptReader: @unchecked Sendable {
    public static let tailBytes = 2_000_000
    public static let retryBytes = 16_000_000
    public static let maxEvents = 120
    /// How many parsed files to keep; the app runs for days and sessions keep appearing.
    public static let cacheLimit = 400

    let paths: HivePaths
    let naming: Naming
    private let lock = NSLock()
    private var cache: [String: (size: Int, mtime: TimeInterval, tail: TranscriptTail, used: UInt64)] = [:]
    private var clock: UInt64 = 0

    public init(paths: HivePaths) {
        self.paths = paths
        naming = Naming(paths: paths)
    }

    public func read(_ url: URL) -> TranscriptTail? {
        let path = url.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              let mdate = attrs[.modificationDate] as? Date else { return nil }
        let mtime = mdate.timeIntervalSince1970
        lock.lock()
        if let hit = cache[path], hit.size == size, hit.mtime == mtime {
            clock += 1
            cache[path]?.used = clock
            lock.unlock()
            return hit.tail
        }
        lock.unlock()
        let antigravity = paths.isAntigravity(url)
        guard let lines = try? TailFile.lines(url, size: size, want: Self.tailBytes) else { return nil }
        var tail = antigravity ? AntigravityTranscript.scan(lines, naming: naming) : scan(lines)
        if !antigravity, tail.events.count < 20, size > Self.tailBytes,
           let wider = try? scan(TailFile.lines(url, size: size, want: Self.retryBytes)) {
            tail = wider
        }
        tail.size = size
        tail.mtime = Int(mtime.rounded(.down))
        lock.lock()
        clock += 1
        cache[path] = (size, mtime, tail, clock)
        if cache.count > Self.cacheLimit {
            // Drop the least recently used quarter in one go, so this doesn't run on every read.
            let drop = cache.sorted { $0.value.used < $1.value.used }.prefix(cache.count - Self.cacheLimit * 3 / 4)
            for (key, _) in drop { cache.removeValue(forKey: key) }
        }
        lock.unlock()
        return tail
    }

    var cachedCount: Int { lock.withLock { cache.count } }

    /// Forgets cached files that no longer matter, so a long-running app doesn't grow without bound.
    public func prune(keeping paths: Set<String>) {
        lock.lock()
        cache = cache.filter { paths.contains($0.key) }
        lock.unlock()
    }

    // MARK: - scan_lines

    func scan(_ lines: [ArraySlice<UInt8>]) -> TranscriptTail {
        var out = TranscriptTail()
        var lastPrompt: String?
        var events: [TranscriptEvent] = []
        var byID: [String: Int] = [:]          // tool id -> index in events
        var pendingOrder: [String] = []
        var pendingSet: [String: Int] = [:]    // tool id -> index in events
        var seenSays = Set<String>()
        var prOrder: [String] = []
        var prs: [String: PullRequest] = [:]

        for raw in lines {
            if raw.isEmpty || TailFile.hasPrefixMarker(raw, TailFile.apiRequest) { continue }
            guard let d = TailFile.object(raw) else { continue }
            let kind = d["type"]?.string
            switch kind {
            case "custom-title":
                if d["customTitle"].truthy { out.title = Py.str(d["customTitle"]!) }
            case "mode":
                out.mode = d["mode"].flatMap { $0.isNull ? nil : Py.str($0) }
            case "last-prompt":
                if d["lastPrompt"].truthy { lastPrompt = Py.str(d["lastPrompt"]!) }
            case "pr-link":
                let url = Py.str(orEmpty: d["prUrl"])
                if url.hasPrefix("https://") {
                    if prs[url] == nil { prOrder.append(url) }
                    prs[url] = PullRequest(url: url, number: d["prNumber"], repo: d["prRepository"])
                }
            default: break
            }
            guard kind == "assistant" || kind == "user" else { continue }
            let ts = Epoch.parse(d["timestamp"])
            if let ts, ts != 0 { out.lastTs = ts }
            if d["gitBranch"].truthy, d["gitBranch"]?.string != "HEAD" { out.branch = Py.str(d["gitBranch"]!) }
            if d["cwd"].truthy { out.cwd = Py.str(d["cwd"]!) }
            let msg = d["message"]?.object ?? JSONObject()
            let uuid = d["uuid"].truthy ? Py.str(d["uuid"]!) : ts.map(String.init) ?? "None"
            let parts = Self.parts(msg["content"])

            if kind == "assistant" {
                if msg["model"].truthy, msg["model"]?.string != "<synthetic>" { out.model = Py.str(msg["model"]!) }
                if d["effort"].truthy { out.effort = Py.str(d["effort"]!) }
                out.turnEnded = msg["stop_reason"]?.string == "end_turn"
                if let usage = msg["usage"]?.object {
                    let total = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
                        .reduce(0) { $0 + Py.int(orZero: usage[$1]) }
                    if total != 0 { out.contextTokens = total }
                }
                for (i, item) in parts.enumerated() {
                    guard let part = item.object else { continue }
                    let ptype = part["type"]?.string
                    if ptype == "text", !Text.strip(Py.str(orEmpty: part["text"])).isEmpty {
                        let text = Text.strip(Py.str(part["text"]!))
                        out.lastText = text
                        out.lastTextTs = ts
                        let key = Text.prefix(text, 200)
                        if !seenSays.contains(key) {
                            seenSays.insert(key)
                            events.append(TranscriptEvent(id: "\(uuid):\(i)", t: ts, k: "say",
                                                          title: Text.oneLine(text), body: Text.prefix(text, 3000)))
                        }
                    } else if ptype == "tool_use" {
                        let name = part["name"].truthy ? Py.str(part["name"]!) : "tool"
                        let inp = part["input"]?.object ?? JSONObject()
                        if name.hasSuffix("__update_plan") {
                            out.plan = Self.applyPlan(out.plan, inp)
                            continue
                        }
                        if name == "TodoWrite" {
                            out.plan = (inp["todos"]?.array ?? []).compactMap { $0.object }.map {
                                PlanItem(text: Py.str(orEmpty: $0["content"]),
                                         state: $0["status"].truthy ? Py.str($0["status"]!) : "pending")
                            }
                            continue
                        }
                        if name.hasSuffix("__wrap_up") {
                            let recap = Py.str(orEmpty: inp["recap"])
                            if !recap.isEmpty { out.recap = recap }
                            if inp["ask"].truthy {
                                out.ask = Py.str(inp["ask"]!)
                                out.askTs = ts
                            } else {
                                out.ask = nil
                                out.askTs = nil
                            }
                            for n in out.plan.indices { out.plan[n].state = "completed" }
                            let asked = inp["ask"].truthy ? "\n\nAsked: " + Py.str(inp["ask"]!) : ""
                            events.append(TranscriptEvent(id: "\(uuid):\(i)", t: ts, k: "recap",
                                                          title: Text.oneLine(inp["recap"]), body: recap + asked))
                            continue
                        }
                        if Patterns.internalTools.contains(name) || name.hasPrefix("mcp__ccd_") { continue }
                        let (verb, obj, detail) = toolLabel(name: name, input: inp, naming: naming)
                        let partID = part["id"].truthy ? Py.str(part["id"]!) : nil
                        events.append(TranscriptEvent(id: partID ?? "\(uuid):\(i)", t: ts, k: "tool", title:
                                                        "\(Text.capitalize(verb)) \(obj)", body: detail, verb: verb, tool: name))
                        if let partID {
                            byID[partID] = events.count - 1
                            if pendingSet[partID] == nil { pendingOrder.append(partID) }
                            pendingSet[partID] = events.count - 1
                        }
                    }
                }
                continue
            }

            // kind == "user"
            if d["isMeta"].truthy { continue }
            out.turnEnded = false
            for (i, item) in parts.enumerated() {
                guard let part = item.object else { continue }
                let ptype = part["type"]?.string
                if ptype == "tool_result" {
                    let useID = part["tool_use_id"].map(Py.str) ?? ""
                    let ev = byID[useID]
                    if pendingSet.removeValue(forKey: useID) != nil {
                        pendingOrder.removeAll { $0 == useID }
                    }
                    if let ev {
                        var result = part["content"]
                        if let list = result?.array {
                            result = .string(list.compactMap { $0.object }.map { Py.str(orEmpty: $0["text"]) }
                                .joined(separator: "\n"))
                        }
                        events[ev].out = Text.prefix(Py.str(orEmpty: result), 1000)
                        if part["is_error"].truthy { events[ev].err = true }
                    }
                } else if ptype == "text" {
                    let text = Text.strip(Patterns.cleanPrompt(Py.str(orEmpty: part["text"])))
                    if text.isEmpty { continue }
                    if let tag = Text.firstGroup(Patterns.eventTag, text) {
                        events.append(TranscriptEvent(id: "\(uuid):\(i)", t: ts, k: "event",
                                                      title: Patterns.eventNames[tag] ?? "Automated message",
                                                      body: Text.prefix(text, 1500)))
                        continue
                    }
                    out.prompt = text
                    out.promptTs = ts
                    out.ask = nil
                    out.askTs = nil
                    out.recap = nil
                    events.append(TranscriptEvent(id: "\(uuid):\(i)", t: ts, k: "you",
                                                  title: Text.oneLine(text), body: Text.prefix(text, 3000)))
                }
            }
        }

        out.pending = pendingOrder.compactMap { pendingSet[$0].map { events[$0] } }
        if (out.prompt ?? "").isEmpty, let lastPrompt {
            out.prompt = Text.strip(Patterns.cleanPrompt(lastPrompt))
        }
        out.events = Array(events.suffix(Self.maxEvents))
        out.prs = prOrder.compactMap { prs[$0] }
        return out
    }

    /// Message content as a list of parts; a plain string is one text part.
    static func parts(_ content: JSON?) -> [JSON] {
        switch content {
        case .string(let s): return [["type": "text", "text": .string(s)]]
        case .array(let a): return a
        default: return []
        }
    }

    /// `apply_plan`: an `update_plan` call replaces, advances or ticks off plan items.
    static func applyPlan(_ planIn: [PlanItem], _ inp: JSONObject) -> [PlanItem] {
        if inp["items"].truthy {
            return (inp["items"]?.array ?? []).compactMap { $0.object }.map {
                PlanItem(text: Py.str(orEmpty: $0["content"]), state: $0["status"].truthy ? Py.str($0["status"]!) : "pending")
            }
        }
        var plan = planIn
        if inp["advance"].truthy {
            for n in plan.indices where plan[n].state == "in_progress" { plan[n].state = "completed" }
            if let n = plan.firstIndex(where: { $0.state == "pending" }) { plan[n].state = "in_progress" }
        }
        if inp["done"].truthy, let done = inp["done"]?.array {
            for v in done {
                if let n = v.int, n > 0, n <= plan.count { plan[n - 1].state = "completed" }
            }
        }
        if let n = inp["start"]?.int, n > 0, n <= plan.count { plan[n - 1].state = "in_progress" }
        return plan
    }
}
