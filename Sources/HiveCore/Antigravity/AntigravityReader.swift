import Foundation
import SQLite3

/// The running Antigravity app's daemon file (`daemon/hub_<port>.json`). Only the pid and the two ports are kept;
/// nothing else in the file is used, stored or served.
public struct AntigravityHub: Sendable, Equatable {
    public var pid: Int
    public var httpPort: JSON
    public var httpsPort: JSON
}

/// Google Antigravity conversations as board rows, as server.py's `read_antigravity_sessions` builds them: from
/// `conversation_summaries.db` (opened read-only), each conversation's transcript, and the running app's process.
/// Every live conversation shares the app's process. A conversation counts as live while the app runs and it's
/// busy or was used in the last 24 hours; older ones (up to 48 hours) are ended.
final class AntigravityReader: @unchecked Sendable {
    static let runningStatus = "CASCADE_RUN_STATUS_RUNNING"
    static let liveWindow: TimeInterval = 86_400
    static let listWindow: TimeInterval = 48 * 3600
    static let quietWarning: TimeInterval = 30 * 60

    let paths: HivePaths
    let naming: Naming
    let transcripts: TranscriptReader
    let locator: TranscriptLocator
    let now: @Sendable () -> Date
    let pidAlive: @Sendable (Int32) -> Bool
    private let lock = NSLock()
    private var projects: [String: String] = [:]
    private var cachedVersion: String??

    init(paths: HivePaths, transcripts: TranscriptReader, locator: TranscriptLocator,
         now: @escaping @Sendable () -> Date, pidAlive: @escaping @Sendable (Int32) -> Bool) {
        self.paths = paths
        naming = Naming(paths: paths)
        self.transcripts = transcripts
        self.locator = locator
        self.now = now
        self.pidAlive = pidAlive
    }

    /// The project a conversation was filed under when it was last listed (`_agy_projects`), for token counts.
    func project(of id: String) -> String? {
        lock.withLock { projects[id] }
    }

    /// `antigravity_version`: the app's version, read once.
    func version() -> String? {
        if let cached = lock.withLock({ cachedVersion }) { return cached }
        let url = paths.antigravityApp.appending(path: "Contents/Info.plist")
        let plist = (try? Data(contentsOf: url)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        }
        let version = plist?["CFBundleShortVersionString"] as? String
        lock.withLock { cachedVersion = .some(version) }
        return version
    }

    func alive(_ pid: Int) -> Bool {
        pid > 0 && pid <= Int(Int32.max) && pidAlive(Int32(pid))
    }

    /// `antigravity_hub`: the running Antigravity's daemon file. Old hub files stay behind and their pid can be
    /// reused by another program, so once a process list is known only a pid that is the Antigravity app or its
    /// command-line hub (`agy --hub`) counts, the app first, newest file first. With no process list yet, the
    /// newest file with a live pid.
    func hub(_ table: [Int32: ProcRecord] = [:]) -> AntigravityHub? { Self.hub(paths: paths, pidAlive: pidAlive, table: table) }

    static let agyHub = try! NSRegularExpression(pattern: #"(^|/)agy\s.*--hub\b"#)

    static func hub(paths: HivePaths, pidAlive: @Sendable (Int32) -> Bool, table: [Int32: ProcRecord] = [:]) -> AntigravityHub? {
        let dir = paths.antigravity.appending(path: "daemon", directoryHint: .isDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var found: [(isApp: Bool, mtime: Date, hub: AntigravityHub)] = []
        for name in names where name.hasPrefix("hub_") && name.hasSuffix(".json") {
            let file = dir.appending(path: name)
            guard let data = try? Data(contentsOf: file),
                  let info = (try? JSON.parse(data))?.object, let pid = info["pid"]?.int,
                  pid > 0, pid <= Int(Int32.max), pidAlive(Int32(pid)) else { continue }
            let cmd = table[Int32(pid)]?.cmd ?? ""
            let isApp = cmd.contains("/Antigravity.app/")
            let isCLI = agyHub.firstMatch(in: cmd, range: NSRange(cmd.startIndex..., in: cmd)) != nil
            if !table.isEmpty && !(isApp || isCLI) { continue }
            let mtime = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? .distantPast
            found.append((isApp, mtime, AntigravityHub(pid: pid, httpPort: info["httpPort"] ?? .null,
                                                        httpsPort: info["httpsPort"] ?? .null)))
        }
        return found.max { ($0.isApp ? 1 : 0, $0.mtime) < ($1.isApp ? 1 : 0, $1.mtime) }?.hub
    }

    /// `antigravity_pid`: the hub's pid, else the language server's, else the app's.
    func pid(_ table: [Int32: ProcRecord]) -> Int? {
        if let hub = hub(table) { return hub.pid }
        let procs = table.values.sorted { $0.pid < $1.pid }
        if let p = procs.first(where: { $0.cmd.contains("Antigravity") && $0.cmd.contains("language_server") && alive(Int($0.pid)) }) {
            return Int(p.pid)
        }
        if let p = procs.first(where: { $0.cmd.contains("/Applications/Antigravity.app/Contents/MacOS/Antigravity") && alive(Int($0.pid)) }) {
            return Int(p.pid)
        }
        return nil
    }

    /// The 40 most recently changed conversations that weren't killed, as `read_antigravity_sessions` selects them.
    func conversations() -> [JSONObject]? {
        let path = paths.antigravityDB.path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let db = try? ReadonlyDatabase.open(path) else { return nil }
        defer { sqlite3_close(db) }
        return try? OpenClawReader.query(db, "SELECT conversation_id, title, status, last_modified_time, not_fully_idle, "
                                         + "killed, workspace_uris, last_user_input_time FROM conversation_summaries "
                                         + "WHERE killed = 0 ORDER BY last_modified_time DESC LIMIT 40")
    }

    /// The first workspace folder: a `file://` URI's path, or the URI as it is.
    static func folder(_ uris: JSON?) -> String? {
        let text = uris.truthy ? Py.str(uris!) : "[]"
        guard let first = (try? JSON.parse(text))?.array?.first?.string else { return nil }
        guard first.hasPrefix("file://") else { return first }
        let rest = String(first.dropFirst(7))
        return rest.removingPercentEncoding ?? rest
    }

    func sessions(_ table: [Int32: ProcRecord]) -> [(row: BoardRow, raw: SessionFile)] {
        guard let records = conversations() else { return [] }
        let hub = hub(table)
        let appPid = hub?.pid ?? pid(table)
        let httpPort = hub?.httpPort ?? .null
        let liveApp = appPid.map(alive) ?? false
        let proc = liveApp ? appPid.flatMap { table[Int32($0)] } : nil
        let nowTs = now().timeIntervalSince1970
        var out: [(BoardRow, SessionFile)] = []
        for r in records {
            guard let sid = r["conversation_id"]?.string, let lastTs = Epoch.parse(r["last_modified_time"]), lastTs != 0
            else { continue }
            let age = nowTs - TimeInterval(lastTs)
            if age > Self.listWindow { continue }
            let cwd = Self.folder(r["workspace_uris"])
            let (project, worktree) = naming.projectOf(cwd)
            lock.withLock { projects[sid] = project }

            let log = paths.antigravityTranscript(sid)
            var tail: TranscriptTail?
            if FileManager.default.fileExists(atPath: log.path) {
                locator.remember(sid, log)
                tail = transcripts.read(log)
            }
            let notIdle = r["not_fully_idle"].truthy || r["status"]?.string == Self.runningStatus
            let live = liveApp && (notIdle || age < Self.liveWindow)

            var group: String, reason: String?, headline: String, doing: String?
            let title = r["title"].truthy ? Py.str(r["title"]!) : nil
            if !live {
                group = "ended"
                headline = Text.firstSentence(nonEmpty(tail?.lastText) ?? title ?? "Ended")
            } else if let ask = nonEmpty(tail?.ask) {
                group = "needs"
                reason = "question"
                headline = "Asked: " + Text.oneLine(ask, 160)
            } else if notIdle {
                group = "working"
                if let last = tail?.pending.last {
                    let verb = last.verb ?? "tool"
                    doing = ["run": "run", "read": "read", "write": "write", "web": "web"][verb] ?? "tool"
                    headline = last.title.isEmpty ? "Using \(last.tool ?? "None")" : last.title
                } else {
                    doing = "think"
                    headline = "Thinking"
                }
            } else {
                group = "idle"
                if let text = nonEmpty(tail?.lastText) {
                    headline = Text.firstSentence(text)
                } else if let prompt = nonEmpty(tail?.prompt) {
                    headline = Text.oneLine(prompt, 70)
                } else {
                    headline = title ?? "Idle"
                }
            }
            let prompt = Text.oneLine(tail?.prompt, 60)
            let name = title ?? (prompt.isEmpty ? "Antigravity \(project)" : prompt)
            let webUrl = httpPort.truthy ? "http://127.0.0.1:\(Py.str(httpPort))/c/\(sid)" : nil
            let started = Epoch.parse(r["last_user_input_time"]).flatMap { $0 == 0 ? nil : $0 } ?? lastTs
            var row = BoardRow(
                id: sid, pid: live ? appPid : nil, name: name, project: project, worktree: worktree,
                branch: tail?.branch, cwd: cwd, webUrl: webUrl, group: group, reason: reason, headline: headline,
                doing: doing, statusSince: lastTs, lastTs: max(lastTs, tail?.lastTs ?? 0),
                model: nonEmpty(tail?.model) ?? AntigravityTranscript.model, effort: nil,
                subagentsRunning: 0, subagentsTotal: 0, helpers: [], questions: [], plan: .null,
                hostId: "antigravity", entry: "antigravity", provider: "google", version: version(),
                startedAt: started, uptime: live ? proc?.uptime : nil, live: live)
            if group == "working", nowTs - TimeInterval(lastTs) > Self.quietWarning { row.quiet = true }

            var raw = SessionFile()
            raw.sessionId = sid
            raw.pid = live ? appPid : nil
            raw.name = name
            raw.cwd = cwd
            raw.entrypoint = "antigravity"
            raw.status = group == "working" ? "busy" : group == "needs" ? "waiting" : "idle"
            raw.updatedAt = Double(lastTs) * 1000
            raw.startedAt = Double(lastTs) * 1000
            out.append((row, raw))
        }
        return out
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
