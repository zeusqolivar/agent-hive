import Foundation

/// Claude Code and Google Antigravity tokens per day, project, model and session over the last 7 local days,
/// read incrementally from every transcript and subagent log, as server.py's usage scan counts them.
///
/// A response is written once per content block, all with the same `message.id`. Each id is counted
/// once; later lines add only the growth in output tokens.
public final class UsageCounter: @unchecked Sendable {
    public static let days = 7

    private struct Key: Hashable { var day: String; var project: String; var model: String }

    private let paths: HivePaths
    private let naming: Naming
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    /// The project of an Antigravity conversation the board has seen, or nil.
    private let antigravityProject: @Sendable (String) -> String?
    private let lock = NSLock()
    private var agg: [Key: [Int]] = [:]
    private var aggOrder: [Key] = []
    private var sessions: [String: [String: [Int]]] = [:]
    private var sessionOrder: [String] = []
    private var offsets: [String: Int] = [:]
    private var seen: [String: Int] = [:]
    private var ready = false
    private var filesDone = 0
    private var filesTotal = 0
    private var scannedAt = 0
    private var loop: Task<Void, Never>?

    public init(paths: HivePaths, now: @escaping @Sendable () -> Date = Date.init, timeZone: TimeZone = .current,
                antigravityProject: @escaping @Sendable (String) -> String? = { _ in nil }) {
        self.paths = paths
        self.antigravityProject = antigravityProject
        naming = Naming(paths: paths)
        self.now = now
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        calendar = cal
    }

    /// Scans now and then once a minute.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard loop == nil else { return }
        loop = Task.detached(priority: .medium) { [weak self] in
            while !Task.isCancelled {
                self?.scan()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func localDay(_ ts: TimeInterval) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: ts))
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    func recentDays() -> [String] {
        let t = now().timeIntervalSince1970
        return (0..<Self.days).reversed().map { localDay(t - Double($0) * 86400) }
    }

    func files() -> [URL] {
        let fm = FileManager.default
        var top: [URL] = [], subs: [URL] = []
        for folder in (try? fm.contentsOfDirectory(atPath: paths.projects.path)) ?? [] {
            let dir = paths.projects.appending(path: folder, directoryHint: .isDirectory)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                if name.hasSuffix(".jsonl") { top.append(dir.appending(path: name, directoryHint: .notDirectory)) }
            }
        }
        for folder in (try? fm.contentsOfDirectory(atPath: paths.projects.path)) ?? [] {
            let dir = paths.projects.appending(path: folder, directoryHint: .isDirectory)
            for session in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                let sub = dir.appending(path: "\(session)/subagents", directoryHint: .isDirectory)
                for name in (try? fm.contentsOfDirectory(atPath: sub.path)) ?? [] where name.hasSuffix(".jsonl") {
                    subs.append(sub.appending(path: name, directoryHint: .notDirectory))
                }
            }
        }
        let brain = paths.antigravity.appending(path: "brain", directoryHint: .isDirectory)
        let antigravity = ((try? fm.contentsOfDirectory(atPath: brain.path)) ?? []).map {
            brain.appending(path: "\($0)/.system_generated/logs/transcript.jsonl", directoryHint: .notDirectory)
        }.filter { fm.fileExists(atPath: $0.path) }
        return top + subs + antigravity
    }

    static func sessionID(_ url: URL) -> String {
        let path = url.path
        if path.contains("/subagents/") { return url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent }
        if path.contains(".system_generated") {
            return url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        }
        return String(url.lastPathComponent.dropLast(".jsonl".count))
    }

    /// One incremental pass over every file changed in the last 8 days.
    public func scan() {
        let window = now().timeIntervalSince1970 - Double(Self.days + 1) * 86400
        let cutoff = Self.utcStamp(window)
        var todo: [(URL, Int)] = []
        for url in files() {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attrs[.size] as? NSNumber)?.intValue,
                  let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { continue }
            lock.lock()
            let known = offsets[url.path]
            lock.unlock()
            if mtime >= window, size != known { todo.append((url, size)) }
        }
        lock.lock()
        filesDone = 0
        filesTotal = todo.count
        lock.unlock()
        for (url, size) in todo {
            lock.lock()
            var start = offsets[url.path]
            lock.unlock()
            if start == nil || start! > size { start = Self.seekPast(url, size: size, cutoff: cutoff) }
            if var offset = start, let handle = try? FileHandle(forReadingFrom: url) {
                // Stream the file in chunks; only whole lines count, so a line being written is read next time.
                try? handle.seek(toOffset: UInt64(offset))
                let sid = Self.sessionID(url)
                let antigravity = url.path.contains("transcript.jsonl")
                var pending: [UInt8] = []
                while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                    pending.append(contentsOf: chunk)
                    var lineStart = 0
                    while let nl = pending[lineStart...].firstIndex(of: 0x0A) {
                        let line = pending[lineStart..<nl]
                        offset += nl + 1 - lineStart
                        lineStart = nl + 1
                        if antigravity {
                            if TailFile.hasPrefixMarker(line, Self.plannerMarker, within: Int.max),
                               TailFile.hasPrefixMarker(line, Self.outputMarker, within: Int.max)
                                || TailFile.hasPrefixMarker(line, Self.inputMarker, within: Int.max),
                               let d = TailFile.object(line) {
                                addAntigravity(d, sid: sid)
                            }
                        } else if TailFile.hasPrefixMarker(line, Self.usageMarker, within: Int.max),
                           TailFile.hasPrefixMarker(line, Self.assistantMarker, within: Int.max),
                           let d = TailFile.object(line) {
                            add(d, sid: sid)
                        }
                    }
                    pending.removeFirst(lineStart)
                }
                try? handle.close()
                lock.lock()
                offsets[url.path] = offset
                lock.unlock()
            }
            lock.lock()
            filesDone += 1
            lock.unlock()
        }
        lock.lock()
        if seen.count > 3_000_000 { seen.removeAll() }
        ready = true
        scannedAt = Int(now().timeIntervalSince1970)
        lock.unlock()
    }

    static let usageMarker = Array(#""usage""#.utf8)
    static let assistantMarker = Array(#""type":"assistant""#.utf8)
    static let plannerMarker = Array(#""PLANNER_RESPONSE""#.utf8)
    static let outputMarker = Array(#""output_tokens""#.utf8)
    static let inputMarker = Array(#""input_tokens""#.utf8)

    /// `add_antigravity_usage_line`: one planner step's tokens, filed under the conversation's project (or
    /// "Google Antigravity" while it isn't known) and the model "Gemini". There are no message ids to repeat.
    private func addAntigravity(_ d: JSONObject, sid: String) {
        guard d["type"]?.string == "PLANNER_RESPONSE" else { return }
        let input = Py.int(orZero: d["input_tokens"]), output = Py.int(orZero: d["output_tokens"])
        let cached = Py.int(orZero: d["cache_read_tokens"])
        guard input != 0 || output != 0 || cached != 0, let ts = Epoch.parse(d["created_at"]), ts != 0 else { return }
        let key = Key(day: localDay(TimeInterval(ts)), project: antigravityProject(sid) ?? "Google Antigravity",
                      model: AntigravityTranscript.model)
        lock.lock()
        defer { lock.unlock() }
        if agg[key] == nil { agg[key] = [0, 0, 0, 0, 0]; aggOrder.append(key) }
        if sessions[sid] == nil { sessions[sid] = [:]; sessionOrder.append(sid) }
        if sessions[sid]![key.day] == nil { sessions[sid]![key.day] = [0, 0, 0, 0, 0] }
        let row = [1, output, input, cached, 0]
        for n in 0..<5 {
            agg[key]![n] += row[n]
            sessions[sid]![key.day]![n] += row[n]
        }
    }

    private func add(_ d: JSONObject, sid: String) {
        guard d["type"]?.string == "assistant", let msg = d["message"]?.object, let usage = msg["usage"]?.object,
              let model = msg["model"], !model.isNull, model.string != "<synthetic>",
              let ts = Epoch.parse(d["timestamp"]) else { return }
        let output = Py.int(orZero: usage["output_tokens"])
        let mid = msg["id"].truthy ? Py.str(msg["id"]!) : d["uuid"].map(Py.str) ?? "None"
        let key = Key(day: localDay(TimeInterval(ts)), project: naming.projectOf(d["cwd"]?.string).project,
                      model: Py.str(model))
        lock.lock()
        defer { lock.unlock() }
        if agg[key] == nil { agg[key] = [0, 0, 0, 0, 0]; aggOrder.append(key) }
        if sessions[sid] == nil { sessions[sid] = [:]; sessionOrder.append(sid) }
        if sessions[sid]![key.day] == nil { sessions[sid]![key.day] = [0, 0, 0, 0, 0] }
        if let before = seen[mid] {
            let growth = max(0, output - before)
            seen[mid] = max(output, before)
            agg[key]![1] += growth
            sessions[sid]![key.day]![1] += growth
            return
        }
        seen[mid] = output
        let row = [1, output, Py.int(orZero: usage["input_tokens"]), Py.int(orZero: usage["cache_read_input_tokens"]),
                   Py.int(orZero: usage["cache_creation_input_tokens"])]
        for n in 0..<5 {
            agg[key]![n] += row[n]
            sessions[sid]![key.day]![n] += row[n]
        }
    }

    /// `seek_past`: a binary search for the offset where timestamps reach the cutoff, for big files.
    static func seekPast(_ url: URL, size: Int, cutoff: String) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var lo = 0, hi = size
        let window = 1 << 20
        while hi - lo > window {
            let mid = (lo + hi) / 2
            try? handle.seek(toOffset: UInt64(mid))
            let chunk = (try? handle.read(upToCount: window)) ?? Data()
            if let stamp = firstTimestamp(chunk), stamp < cutoff { lo = mid } else { hi = mid }
        }
        guard lo > 0 else { return 0 }
        // Skip the rest of the line the cut landed in, however long it is.
        var at = lo
        try? handle.seek(toOffset: UInt64(lo))
        while let chunk = try? handle.read(upToCount: window), !chunk.isEmpty {
            if let nl = chunk.firstIndex(of: 0x0A) { return at + (nl - chunk.startIndex) + 1 }
            at += chunk.count
        }
        return size
    }

    private static let timestamp = try! NSRegularExpression(pattern: #""timestamp":"([0-9T:.\-]+)Z?""#)

    static func firstTimestamp(_ data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        return Text.firstGroup(timestamp, text).map { Text.prefix($0, 19) }
    }

    static func utcStamp(_ t: TimeInterval) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    private func totals(_ byDay: [String: [Int]], _ days: [String]) -> [Int]? {
        let rows = days.compactMap { byDay[$0] }
        guard !rows.isEmpty else { return nil }
        return (0..<5).map { n in rows.reduce(0) { $0 + $1[n] } }
    }

    private static func tokens(_ row: [Int]) -> JSON {
        ["responses": .int(row[0]), "output": .int(row[1]), "input": .int(row[2]), "cacheRead": .int(row[3]),
         "cacheWrite": .int(row[4])]
    }

    /// `usage_for_session`: a session's totals over the last 7 days, or null.
    public func forSession(_ sid: String) -> JSON {
        let days = recentDays()
        lock.lock()
        let byDay = sessions[sid] ?? [:]
        lock.unlock()
        return totals(byDay, days).map(Self.tokens) ?? .null
    }

    /// `/api/usage`. `title` names a session (the board's name, or one read from its transcript).
    public func report(title: (String) async -> String) async -> Data {
        let wanted = recentDays()
        let today = localDay(now().timeIntervalSince1970)
        let (items, sessionRows, header) = lock.withLock {
            (aggOrder.map { ($0, agg[$0]!) }, sessionOrder.map { ($0, totals(sessions[$0]!, wanted)) },
             ["ready": .bool(ready), "filesDone": .int(filesDone), "filesTotal": .int(filesTotal),
              "scannedAt": .int(scannedAt), "today": .string(today)] as JSON)
        }

        var days: [String: [Int]] = Dictionary(uniqueKeysWithValues: wanted.map { ($0, [0, 0, 0, 0, 0, 0]) })
        var projects: [(String, [Int])] = [], models: [(String, [Int])] = []
        func bump(_ list: inout [(String, [Int])], _ name: String, _ row: [Int], today isToday: Bool) {
            var i = list.firstIndex { $0.0 == name }
            if i == nil { list.append((name, [0, 0, 0, 0, 0, 0])); i = list.count - 1 }
            for n in 0..<5 { list[i!].1[n] += row[n] }
            if isToday { list[i!].1[5] += row[1] }
        }
        for (key, row) in items where days[key.day] != nil {
            for n in 0..<5 { days[key.day]![n] += row[n] }
            bump(&projects, key.project, row, today: key.day == today)
            bump(&models, key.model, row, today: key.day == today)
        }
        func bucket(_ r: [Int]) -> JSONObject {
            JSONObject(["responses": .int(r[0]), "output": .int(r[1]), "input": .int(r[2]), "cacheRead": .int(r[3]),
                        "cacheWrite": .int(r[4]), "today": .int(r[5])])
        }
        func named(_ list: [(String, [Int])]) -> JSON {
            .array(list.stableSorted { $0.1[1] > $1.1[1] }.map { name, r in
                var o = JSONObject(["name": .string(name)])
                for (k, v) in bucket(r).pairs { o[k] = v }
                return .object(o)
            })
        }
        let top = sessionRows.compactMap { sid, row in row.map { (sid, $0) } }.stableSorted { $0.1[1] > $1.1[1] }.prefix(10)
        var sessionJSON: [JSON] = []
        for (sid, row) in top {
            sessionJSON.append(["id": .string(sid), "name": .string(await title(sid)), "output": .int(row[1]),
                                "responses": .int(row[0])])
        }
        guard case .object(var o) = header else { return Data() }
        o["days"] = .array(wanted.map { d in
            var b = bucket(days[d]!)
            b["day"] = .string(d)
            b["today"] = .int(0)
            return .object(b)
        })
        o["projects"] = named(projects)
        o["models"] = named(models)
        o["sessions"] = .array(sessionJSON)
        return JSON.object(o).serialized()
    }
}
