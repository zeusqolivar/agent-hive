import Foundation

/// Builds board refreshes. Everything here is thread-safe and runs off the main thread.
final class BoardBuilder: @unchecked Sendable {
    static let quietWarning: TimeInterval = 30 * 60

    let paths: HivePaths
    let naming: Naming
    let processes: ProcessTable
    let transcripts: TranscriptReader
    let subagents: SubagentReader
    let liveFeed: LiveFeed
    let locator: TranscriptLocator
    let ended: EndedSessions
    let antigravity: AntigravityReader
    let now: @Sendable () -> Date

    init(paths: HivePaths, processes: ProcessSource, now: @escaping @Sendable () -> Date,
         pidAlive: @escaping @Sendable (Int32) -> Bool = SessionReader.pidAlive) {
        self.paths = paths
        naming = Naming(paths: paths)
        self.processes = ProcessTable(source: processes)
        transcripts = TranscriptReader(paths: paths)
        subagents = SubagentReader(transcripts: transcripts, now: now)
        liveFeed = LiveFeed(paths: paths, now: now)
        locator = TranscriptLocator(paths: paths)
        ended = EndedSessions(paths: paths, transcripts: transcripts, subagents: subagents, locator: locator, now: now)
        antigravity = AntigravityReader(paths: paths, transcripts: transcripts, locator: locator, now: now, pidAlive: pidAlive)
        self.now = now
    }

    func build(capabilities: JSON, replies: ReplyPolicy?) -> BoardState {
        let table = processes.refresh()
        var rows: [BoardRow] = []
        var raws: [String: SessionFile] = [:]
        for raw in SessionReader.liveSessions(paths: paths, processes: table) {
            guard let row = sessionRow(raw, table) else { continue }
            if raws[row.id] != nil { continue }
            rows.append(row)
            raws[row.id] = raw
        }
        // Google Antigravity's conversations, unless a Claude session has the same id.
        for (row, raw) in antigravity.sessions(table) where raws[row.id] == nil {
            rows.append(row)
            raws[row.id] = raw
        }
        rows += ended.rows(excluding: Set(raws.keys))
        let order = ["needs": 0, "working": 1, "idle": 2, "ended": 3]
        let reasonOrder = ["permission": 0, "plan": 0, "question": 1]
        rows = rows.stableSorted { a, b in
            let ka = (order[a.group] ?? 4, reasonOrder[a.reason ?? ""] ?? 2, -(a.lastTs ?? 0))
            let kb = (order[b.group] ?? 4, reasonOrder[b.reason ?? ""] ?? 2, -(b.lastTs ?? 0))
            return ka < kb
        }
        if let replies {
            for n in rows.indices {
                let verdict = replies.canReply(rows[n], processes: table)
                rows[n].canReply = verdict.allowed
                rows[n].replyNote = verdict.note
            }
        }
        var state = BoardState()
        state.ready = true
        state.rows = rows
        state.raws = raws
        state.processes = table
        state.mac = MacSummary.make(table)
        state.generatedAt = Int(now().timeIntervalSince1970)
        state.capabilities = capabilities
        return state
    }

    func sessionRow(_ raw: SessionFile, _ table: [Int32: ProcRecord]) -> BoardRow? {
        guard let sid = raw.sessionId else { return nil }
        let url = locator.find(sid)
        let tail = url.flatMap { transcripts.read($0) }
        let subs = url.map { subagents.list(transcript: $0) } ?? []
        let running = subs.filter { $0.state == "running" }.count
        let pid = raw.pid.map { Int32(truncatingIfNeeded: $0) }
        let proc = pid.flatMap { table[$0] }
        let tree = proc.map { _ in ProcessTable.sessionProcesses(table, pid: pid!, naming: naming) }
        let commands = tree?.commands ?? []
        let (group, reason, headline) = Describer.describe(raw: raw, tail: tail, subsRunning: running, commands: commands)
        let cwd = tail?.cwd ?? raw.cwd
        let (project, worktree) = naming.projectOf(cwd)
        var lastTs = tail?.lastTs
        if let tail { lastTs = [lastTs, tail.mtime].compactMap { $0 }.filter { $0 != 0 }.max() }
        let since = raw.statusUpdatedAt.flatMap { $0 == 0 ? nil : $0 } ?? raw.updatedAt
        let started = Int((raw.startedAt ?? 0) / 1000)
        var row = BoardRow(
            id: sid, pid: raw.pid, name: raw.name ?? project, project: project, worktree: worktree,
            branch: tail?.branch, cwd: cwd, group: group, reason: reason, headline: headline,
            doing: Describer.doing(group: group, tail: tail, subsRunning: running, commands: commands),
            statusSince: since.flatMap { $0 == 0 ? nil : Int($0 / 1000) }, lastTs: lastTs,
            model: tail?.model, effort: tail?.effort, subagentsRunning: running, subagentsTotal: subs.count,
            helpers: subagents.helpers(subs), questions: reason == "questions" ? OpenQuestions.of(tail) : [],
            plan: tail.map { Describer.planSummary($0.plan) } ?? .null,
            hostId: raw.hostSessionId, entry: raw.entrypoint, version: raw.version,
            startedAt: started == 0 ? nil : started, uptime: proc?.uptime, live: true)
        if reason == "questions", let asked = tail?.lastTextTs, asked != 0 {
            row.statusSince = asked    // waiting since the message that asked
        }
        if group == "working", let lastTs, now().timeIntervalSince1970 - TimeInterval(lastTs) > Self.quietWarning,
           running == 0, tree == nil || tree!.cpu < 2 {
            row.quiet = true
        }
        return row
    }
}

/// Decides, per row, whether the app may send a reply. Set by the reply feature.
public protocol ReplyPolicy: Sendable {
    func canReply(_ row: BoardRow, processes: [Int32: ProcRecord]) -> (allowed: Bool, note: String?)
}

/// The live board: refreshed in the background every couple of seconds, read by the API.
public actor Board {
    let builder: BoardBuilder
    private var state = BoardState.empty
    private var loop: Task<Void, Never>?
    private let pageVersion: Int
    private let host: String
    private var capabilities: JSON = ["reply": false]
    private var replies: ReplyPolicy?
    private var usageLookup: (@Sendable (String) -> JSON)?

    public init(paths: HivePaths, processes: ProcessSource, now: @escaping @Sendable () -> Date = Date.init,
                pageVersion: Int = 0, replies: ReplyPolicy? = nil,
                pidAlive: @escaping @Sendable (Int32) -> Bool = SessionReader.pidAlive) {
        builder = BoardBuilder(paths: paths, processes: processes, now: now, pidAlive: pidAlive)
        self.pageVersion = pageVersion
        self.replies = replies
        if replies != nil { capabilities = ["reply": true] }
        var name = utsname()
        uname(&name)
        host = withUnsafeBytes(of: &name.nodename) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
    }

    /// Starts refreshing: build, wait a second, build again, as server.py's `board_loop` does.
    public func start() {
        guard loop == nil else { return }
        loop = Task.detached(priority: .medium) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Builds one refresh now, off the actor so readers aren't held up while it runs.
    public func refresh() async {
        let caps = capabilities, policy = replies, builder = builder
        let started = Date()
        let next = await Task.detached(priority: .medium) { builder.build(capabilities: caps, replies: policy) }.value
        state = next
        let took = Date().timeIntervalSince(started)
        if took > 15 || ProcessInfo.processInfo.environment["HIVE_DEBUG_TIMING"] != nil {
            FileHandle.standardError.write(Data("board refresh: \(String(format: "%.2f", took))s, load \(MacSummary.loadAverage())\n".utf8))
        }
    }

    public func setReplies(_ policy: ReplyPolicy?, capabilities: JSON) {
        replies = policy
        self.capabilities = capabilities
    }

    public func setUsageLookup(_ lookup: @escaping @Sendable (String) -> JSON) {
        usageLookup = lookup
    }

    public func snapshot() -> BoardState { state }

    /// The project an Antigravity conversation was last listed under, for filing its tokens.
    public nonisolated func antigravityProject(_ id: String) -> String? {
        builder.antigravity.project(of: id)
    }

    /// Waits, up to `timeout` seconds, for the first refresh. The app opens its page as it starts, so
    /// views that read the board once would otherwise see an empty one.
    public func waitUntilReady(timeout: Double = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !state.ready, loop != nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    var usage: (@Sendable (String) -> JSON)? { usageLookup }

    /// `/api/board`.
    public func payload() -> Data {
        var o = JSONObject()
        o["ready"] = .bool(state.ready)
        o["sessions"] = state.rows.json
        o["counts"] = state.counts
        o["generatedAt"] = .int(state.generatedAt)
        if state.ready {
            o["capabilities"] = state.capabilities
            o["mac"] = state.mac
            o["page"] = .int(pageVersion)
            o["host"] = .string(host)
        }
        o["loadNow"] = .double(MacSummary.loadAverage())
        o["cores"] = .int(ProcessInfo.processInfo.processorCount)
        return JSON.object(o).serialized()
    }

    public nonisolated func sessionDetail(_ id: String, tokens: (@Sendable (String) -> JSON)? = nil) async -> Data? {
        let state = await snapshot()
        let stored = await self.usage
        let usage = tokens ?? stored
        return BoardViews(builder: builder, state: state).sessionDetail(id, usage: usage)?.serialized()
    }

    public nonisolated func agentDetail(_ id: String, agentId: String) async -> Data? {
        let state = await snapshot()
        return BoardViews(builder: builder, state: state).agentDetail(id, agentId: agentId)?.serialized()
    }

    public nonisolated func live(_ id: String) async -> Data? {
        let state = await snapshot()
        return BoardViews(builder: builder, state: state).live(id)?.serialized()
    }

    public nonisolated func activity() async -> Data {
        let state = await snapshot()
        return JSON.object(JSONObject(["items": BoardViews(builder: builder, state: state).activity()])).serialized()
    }

    /// The display name of a session, for the usage report.
    public nonisolated func title(_ id: String) async -> String {
        let state = await snapshot()
        if let row = state.row(id) { return row.name }
        let tail = builder.locator.find(id).flatMap { builder.transcripts.read($0) }
        if let title = tail?.title, !title.isEmpty { return title }
        let prompt = Text.oneLine(tail?.prompt, 60)
        return prompt.isEmpty ? Text.prefix(id, 8) : prompt
    }
}
