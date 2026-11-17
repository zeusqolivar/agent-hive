import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// Hermes Agent's own sessions, from its `state.db`.
///
/// Hermes keeps one row per session in `sessions` and every message in `messages`, with the title, model,
/// token counts and last activity already computed. That is enough for a board row without reading any
/// message text except, for a session with nothing better, the last assistant line as the headline.
///
/// The database belongs to another program and is open and being written while this runs, so it is opened
/// read-only and every failure is "no sessions" rather than an error the board has to handle.
public struct HermesReader: Sendable {
    /// Sessions touched in the last week, which is what the Usage view counts too.
    static let window: TimeInterval = 7 * 24 * 3600
    /// A session with activity this recent is still working; older and not ended is idle.
    static let workingWindow: TimeInterval = 120
    static let limit = 40

    let paths: HivePaths
    let now: @Sendable () -> Date

    public init(paths: HivePaths, now: @escaping @Sendable () -> Date = Date.init) {
        self.paths = paths
        self.now = now
    }

    /// The rows the board shows, newest first.
    public func sessions() -> [BoardRow] {
        guard let database = open() else { return [] }
        defer { sqlite3_close(database) }

        let nowTs = now().timeIntervalSince1970
        let cutoff = nowTs - Self.window
        var rows: [BoardRow] = []
        for session in read(database, since: cutoff) {
            var row = BoardRow(
                id: session.id, pid: nil, name: session.name, project: session.project, worktree: nil,
                branch: session.branch, cwd: session.cwd, webUrl: nil, group: session.group, reason: nil,
                headline: session.headline, doing: session.group == "working" ? session.headline : nil,
                statusSince: session.lastTs, lastTs: session.lastTs,
                model: session.model, effort: nil, subagentsRunning: 0, subagentsTotal: 0, helpers: [],
                questions: [], plan: .null, hostId: nil, entry: "hermes", provider: "hermes",
                version: nil, startedAt: session.startedAt, uptime: nil, live: false)
            // A working session that has gone quiet for a while says so, as the Claude rows do.
            if row.group == "working", nowTs - TimeInterval(session.lastTs) > 5 * 60 { row.quiet = true }
            rows.append(row)
        }
        return rows
    }

    /// Whether this PC has Hermes at all, so the board can say nothing was found rather than nothing is running.
    public var isInstalled: Bool { open() != nil }

    private func open() -> OpaquePointer? {
        for candidate in paths.hermesDBs where FileManager.default.fileExists(atPath: candidate.path) {
            if let database = try? ReadonlyDatabase.open(candidate.path) { return database }
        }
        return nil
    }

    struct Session: Equatable {
        var id: String
        var name: String
        var project: String
        var branch: String?
        var cwd: String?
        var model: String?
        var startedAt: Int?
        var lastTs: Int
        var group: String
        var headline: String
    }

    private func read(_ database: OpaquePointer, since cutoff: TimeInterval) -> [Session] {
        let sql = """
            select id, title, display_name, model, started_at, ended_at, last_activity_at,
                   last_activity_description, message_count, cwd, git_branch
            from sessions
            where coalesce(archived, 0) = 0 and coalesce(hidden, 0) = 0
              and coalesce(last_activity_at, 0) >= ?
            order by coalesce(last_activity_at, 0) desc
            limit \(Self.limit)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff)

        let nowTs = now().timeIntervalSince1970
        var out: [Session] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ column: Int32) -> String? {
                guard let raw = sqlite3_column_text(statement, column) else { return nil }
                let value = String(cString: raw)
                return value.isEmpty ? nil : value
            }
            func number(_ column: Int32) -> Double? {
                guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
                return sqlite3_column_double(statement, column)
            }

            guard let id = text(0) else { continue }
            let title = text(1), display = text(2)
            let cwd = text(9)
            let lastActivity = number(6) ?? number(4) ?? 0
            let ended = number(5) != nil
            let working = !ended && nowTs - lastActivity < Self.workingWindow
            let homeFolder = paths.home.path
            let project = cwd
                .flatMap { value -> String? in
                    let name = Text.windowsBaseName(value)
                    // A session run from the home folder has no project of its own.
                    return name.isEmpty || Self.samePath(value, homeFolder) ? nil : name
                } ?? "Hermes"
            let description = text(7)
            // A last answer that is really a JSON payload or a bare file path makes a poor headline; the title
            // reads better in the list.
            let lastAnswer = lastAssistantLine(database, session: id).flatMap { Self.isProse($0) ? $0 : nil }
            let headline = description ?? lastAnswer ?? title ?? display ?? "Hermes session"

            out.append(Session(
                id: id,
                name: title ?? display ?? project,
                project: project,
                branch: text(10),
                cwd: cwd,
                model: text(3),
                startedAt: number(4).map { Int($0) },
                lastTs: Int(lastActivity),
                group: ended ? "ended" : (working ? "working" : "idle"),
                headline: Text.firstSentence(headline)))
        }
        return out
    }

    /// Whether two paths name the same folder, whatever the separator style or letter case. Windows paths are
    /// compared this way because a tool may write `C:\Users\me`, `c:/users/me` or one with a trailing slash.
    static func samePath(_ one: String, _ other: String) -> Bool {
        func normalised(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "/")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .lowercased()
        }
        return normalised(one) == normalised(other)
    }

    /// Whether a line reads like a sentence rather than a payload: no leading brace, bracket or fence, and not a
    /// single token such as a path.
    static func isProse(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, !"{[`#<".contains(first) else { return false }
        if trimmed.hasPrefix("json") || trimmed.hasPrefix("MEDIA:") { return false }
        return trimmed.contains(" ") && trimmed.count > 12
    }

    /// The last thing Hermes said in a session, for a headline when it isn't still describing what it is doing.
    private func lastAssistantLine(_ database: OpaquePointer, session: String) -> String? {
        let sql = """
            select content from messages
            where session_id = ? and role = 'assistant' and coalesce(content, '') <> ''
            order by timestamp desc, id desc limit 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, session, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else { return nil }
        return Text.oneLine(String(cString: raw), 90)
    }
}
