import Foundation

/// Codex threads as board rows, from the rollouts under `~/.codex/sessions` and the thread names in
/// `~/.codex/session_index.jsonl`. Nothing else under `~/.codex` is read: not `auth.json`, not the databases.
///
/// Codex doesn't record which process runs a thread, so every live thread shares the running Codex process
/// (the ChatGPT app's `codex app-server`, or a `codex` command). A thread counts as live while Codex runs and
/// it was used in the last 24 hours; older ones (up to 48 hours) are ended, as Antigravity's are.
final class CodexReader: @unchecked Sendable {
    static let listWindow: TimeInterval = 48 * 3600
    static let liveWindow: TimeInterval = 86_400
    /// A turn that started but hasn't finished counts as working only while its rollout keeps changing.
    static let workingWindow: TimeInterval = 10 * 60
    /// When the tail shows neither the start nor the end of a turn, a rollout changed this recently is working.
    static let busyWindow: TimeInterval = 2 * 60
    /// How often the whole sessions folder is listed again; the newest day folders are listed every refresh.
    static let walkEvery: TimeInterval = 30
    static let maxRows = 40
    /// `session_meta` is the first line; it carries Codex's base instructions, so it can be tens of kilobytes.
    static let headLimit = 2_000_000

    static let process = try! NSRegularExpression(pattern: #"(^|/)codex(\s|$)"#)
    static let uuid = try! NSRegularExpression(pattern: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#)

    /// What the first line says about a thread.
    struct Head: Sendable {
        var id: String?
        var cwd: String?
        var branch: String?
        var version: String?
        var startedAt: Int?
        /// Threads Codex starts for its own subagents (`source: {subagent: …}`) aren't shown as rows.
        var subagent = false
    }

    let paths: HivePaths
    let naming: Naming
    let transcripts: TranscriptReader
    let locator: TranscriptLocator
    let now: @Sendable () -> Date
    private let lock = NSLock()
    private var walkedAt: TimeInterval = -.infinity
    private var walked: [URL] = []
    private var heads: [String: Head] = [:]
    private var index: (size: Int, mtime: TimeInterval, names: [String: String])?

    init(paths: HivePaths, transcripts: TranscriptReader, locator: TranscriptLocator, now: @escaping @Sendable () -> Date) {
        self.paths = paths
        naming = Naming(paths: paths)
        self.transcripts = transcripts
        self.locator = locator
        self.now = now
    }

    // MARK: - Files

    private static func children(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    /// The day folders (`YYYY/MM/DD`), newest first.
    func dayFolders() -> [URL] {
        let root = paths.codexSessions
        var out: [URL] = []
        for year in Self.children(root).sorted(by: >) {
            let y = root.appending(path: year, directoryHint: .isDirectory)
            for month in Self.children(y).sorted(by: >) {
                let m = y.appending(path: month, directoryHint: .isDirectory)
                for day in Self.children(m).sorted(by: >) { out.append(m.appending(path: day, directoryHint: .isDirectory)) }
            }
        }
        return out
    }

    static func rollouts(in day: URL) -> [URL] {
        children(day).filter { $0.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") }
            .map { day.appending(path: $0, directoryHint: .notDirectory) }
    }

    static func mtime(_ url: URL) -> TimeInterval? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)?.timeIntervalSince1970
    }

    /// Rollouts changed in the last 48 hours, newest first. A rollout is named for the day its thread started, so
    /// a thread started a week ago and used today is in an old folder: the whole tree is listed every 30 seconds,
    /// and the two newest day folders on every refresh so new threads show up at once.
    func recentRollouts() -> [(url: URL, mtime: TimeInterval)] {
        let nowTs = now().timeIntervalSince1970
        let cutoff = nowTs - Self.listWindow
        lock.lock()
        let fresh = nowTs - walkedAt < Self.walkEvery && nowTs >= walkedAt
        var candidates = walked
        lock.unlock()
        let days = dayFolders()
        if !fresh {
            candidates = days.flatMap(Self.rollouts).filter { (Self.mtime($0) ?? 0) >= cutoff }
            lock.withLock {
                walkedAt = nowTs
                walked = candidates
            }
        }
        var seen = Set(candidates.map(\.path))
        for day in days.prefix(2) {
            for url in Self.rollouts(in: day) where !seen.contains(url.path) {
                seen.insert(url.path)
                candidates.append(url)
            }
        }
        return candidates.compactMap { url in Self.mtime(url).map { (url, $0) } }
            .filter { $0.1 >= cutoff }
            .stableSorted { $0.1 > $1.1 }
    }

    /// The thread id in a rollout's name: `rollout-<time>-<uuid>.jsonl`.
    static func idFromName(_ url: URL) -> String {
        let stem = String(url.lastPathComponent.dropLast(".jsonl".count))
        let ns = stem as NSString
        if let m = uuid.firstMatch(in: stem, range: NSRange(location: 0, length: ns.length)) { return ns.substring(with: m.range) }
        return stem
    }

    /// The rollout's first line, read once per file.
    func head(_ url: URL) -> Head {
        if let hit = lock.withLock({ heads[url.path] }) { return hit }
        var head = Head()
        if let line = Self.firstLine(url), let d = (try? JSON.parse(line))?.object, d["type"]?.string == "session_meta",
           let p = d["payload"]?.object {
            head.id = p["id"]?.string
            head.cwd = p["cwd"]?.string
            if let branch = p["git"]?["branch"]?.string, !branch.isEmpty, branch != "HEAD" { head.branch = branch }
            head.version = p["cli_version"]?.string
            head.startedAt = Epoch.parse(p["timestamp"] ?? d["timestamp"])
            head.subagent = p["source"]?["subagent"] != nil
        }
        lock.withLock {
            if heads.count > 2000 { heads.removeAll() }
            heads[url.path] = head
        }
        return head
    }

    static func firstLine(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var data = Data()
        while data.count < headLimit {
            guard let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty else { break }
            if let nl = chunk.firstIndex(of: 0x0A) {
                data.append(chunk[chunk.startIndex..<nl])
                return data
            }
            data.append(chunk)
        }
        return data.isEmpty || data.count >= headLimit ? nil : data
    }

    /// Thread names from `session_index.jsonl`; a later line for the same id wins.
    func threadNames() -> [String: String] {
        let url = paths.codexIndex
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { return [:] }
        if let hit = lock.withLock({ index }), hit.size == size, hit.mtime == mtime { return hit.names }
        var names: [String: String] = [:]
        let data = (try? Data(contentsOf: url)) ?? Data()
        for line in data.split(separator: 0x0A) {
            guard let o = (try? JSON.parse(Data(line)))?.object, let id = o["id"]?.string else { continue }
            let name = Text.strip(o["thread_name"]?.string ?? "")
            if !name.isEmpty { names[id] = name }
        }
        lock.withLock { index = (size, mtime, names) }
        return names
    }

    // MARK: - Process

    /// The running Codex: the app's `codex app-server` first, else any `codex` command, longest running first.
    static func codexProcess(_ table: [Int32: ProcRecord]) -> ProcRecord? {
        let found = table.values.filter { Text.matches(process, $0.cmd) }
        return found.max { a, b in
            let ka = (a.cmd.contains(" app-server") ? 1 : 0, a.uptime, -Int(a.pid))
            let kb = (b.cmd.contains(" app-server") ? 1 : 0, b.uptime, -Int(b.pid))
            return ka < kb
        }
    }

    // MARK: - Rows

    /// `Running xcodebuild …` from a call titled `Run xcodebuild …`.
    static func ongoing(_ title: String) -> String {
        let forms = ["Run": "Running", "Read": "Reading", "View": "Viewing", "Edit": "Editing", "Search": "Searching",
                     "Use": "Using", "Ask": "Asking", "Wait": "Waiting"]
        let parts = title.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, let form = forms[String(first)] else { return title }
        return parts.count > 1 ? "\(form) \(parts[1])" : form
    }

    static func doing(_ event: TranscriptEvent?) -> String {
        guard let event else { return "think" }
        return ["run": "run", "read": "read", "edit": "write", "search": "web"][event.verb ?? ""] ?? "tool"
    }

    func sessions(_ table: [Int32: ProcRecord]) -> [(row: BoardRow, raw: SessionFile)] {
        let files = recentRollouts()
        guard !files.isEmpty else { return [] }
        let proc = Self.codexProcess(table)
        let appPid = proc.map { Int($0.pid) }
        let names = threadNames()
        let nowTs = now().timeIntervalSince1970
        var out: [(BoardRow, SessionFile)] = []
        var ids = Set<String>()
        for (url, mtime) in files {
            if out.count >= Self.maxRows { break }
            let head = head(url)
            if head.subagent { continue }
            let sid = head.id ?? Self.idFromName(url)
            guard Patterns.isID(sid), !ids.contains(sid) else { continue }
            ids.insert(sid)
            locator.remember(sid, url)
            let tail = transcripts.read(url)
            let turn = tail?.codex ?? CodexTurn()
            let age = nowTs - mtime
            let cwd = tail?.cwd ?? head.cwd
            let (project, worktree) = naming.projectOf(cwd)
            let running = turn.running ?? (age < Self.busyWindow)
            let working = proc != nil && running && age < Self.workingWindow
            let live = proc != nil && (working || age < Self.liveWindow)
            let fileTs = Int(mtime.rounded(.down))
            let lastTs = max(tail?.lastTs ?? 0, fileTs)
            let pending = working ? tail?.pending.last : nil
            let asked = turn.questions.isEmpty ? (tail?.ask).map { [$0] } ?? [] : turn.questions
            let openQuestions = live && !working ? OpenQuestions.of(tail) : []

            var group: String, reason: String?, headline: String, doing: String?, since: Int?
            var questions: [String] = []
            if !live {
                group = "ended"
                headline = Text.firstSentence(nonEmpty(tail?.lastText) ?? names[sid] ?? "Ended")
                since = lastTs
            } else if working, let approval = turn.approval {
                group = "needs"
                reason = "permission"
                let title = approval.title
                headline = title.isEmpty ? "Waiting for your permission"
                    : "Needs your OK to " + title.prefix(1).lowercased() + title.dropFirst()
                since = approval.t ?? lastTs
            } else if working, pending?.tool == "request_user_input", let ask = nonEmpty(tail?.ask) {
                group = "needs"
                reason = "question"
                headline = "Asked: " + Text.oneLine(ask, 160)
                questions = asked
                since = tail?.askTs ?? lastTs
            } else if working {
                group = "working"
                if let pending {
                    doing = Self.doing(pending)
                    headline = Self.ongoing(pending.title)
                } else {
                    doing = "think"
                    let current = tail.map { Describer.planSummary($0.plan) }?["current"]?.string
                    headline = nonEmpty(current) ?? "Thinking"
                }
                since = turn.startedTs ?? lastTs
            } else if let ask = nonEmpty(tail?.ask) {
                group = "needs"
                reason = "question"
                headline = "Asked: " + Text.oneLine(ask, 160)
                questions = asked
                since = tail?.askTs ?? lastTs
            } else if let first = openQuestions.first {
                group = "needs"
                reason = "questions"
                headline = "\(openQuestions.count) open question\(openQuestions.count != 1 ? "s" : ""): \(Text.oneLine(first, 140))"
                questions = openQuestions
                since = tail?.lastTextTs ?? lastTs
            } else {
                group = "idle"
                if let text = nonEmpty(tail?.lastText) {
                    headline = Text.firstSentence(text)
                } else if turn.failed {
                    headline = "The last turn stopped with an error"
                } else if let prompt = nonEmpty(tail?.prompt) {
                    headline = Text.oneLine(prompt, 70)
                } else {
                    headline = "Idle"
                }
                since = turn.endedTs ?? tail?.lastTextTs ?? lastTs
            }

            let folder = cwd.map(Text.basename).flatMap(nonEmpty)
            let name = names[sid] ?? folder ?? "Codex"
            let row = BoardRow(
                id: sid, pid: live ? appPid : nil, name: name, project: project, worktree: worktree,
                branch: tail?.branch ?? head.branch, cwd: cwd, webUrl: nil, group: group, reason: reason,
                headline: headline, doing: doing, statusSince: since, lastTs: lastTs, model: tail?.model,
                effort: tail?.effort, subagentsRunning: 0, subagentsTotal: 0, helpers: [], questions: questions,
                plan: tail.map { Describer.planSummary($0.plan) } ?? .null, hostId: nil, entry: "codex",
                provider: "openai", version: head.version, startedAt: head.startedAt ?? fileTs,
                uptime: live ? proc?.uptime : nil, live: live)

            var raw = SessionFile()
            raw.sessionId = sid
            raw.pid = live ? appPid : nil
            raw.name = name
            raw.cwd = cwd
            raw.entrypoint = "codex"
            raw.version = head.version
            raw.status = group == "working" ? "busy" : group == "needs" ? "waiting" : "idle"
            raw.updatedAt = Double(lastTs) * 1000
            raw.startedAt = Double(head.startedAt ?? fileTs) * 1000
            out.append((row, raw))
        }
        return out
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
