import Foundation
import SQLite3

/// OpenClaw's running tasks, recent problems, routines and schedules from `openclaw.sqlite`, opened
/// read-only, as server.py's `openclaw_summary` reads them.
public struct OpenClawReader: Sendable {
    public struct DatabaseError: Error, Sendable { public var message: String }

    let paths: HivePaths
    let now: @Sendable () -> Date

    public init(paths: HivePaths, now: @escaping @Sendable () -> Date = Date.init) {
        self.paths = paths
        self.now = now
    }

    /// `.null` when OpenClaw isn't installed; throws when the database can't be read.
    public func summary() throws -> JSON {
        let path = paths.openclawDB.path
        guard FileManager.default.fileExists(atPath: path) else { return .null }
        let db = try ReadonlyDatabase.open(path)
        defer { sqlite3_close(db) }
        let nowMs = now().timeIntervalSince1970 * 1000
        func secs(_ v: JSON) -> JSON {
            guard let n = v.number, n != 0 else { return .null }
            let s = Int(n / 1000)
            return s == 0 ? .null : .int(s)
        }

        var running: [JSON] = []
        for r in try Self.query(db, "select label, task, status, runtime, agent_id, started_at, last_event_at, "
                           + "last_tool_name, progress_summary from task_runs "
                           + "where ended_at is null and status not in ('succeeded','failed','timed_out','cancelled') "
                           + "order by coalesce(last_event_at, created_at) desc limit 12") {
            running.append(["label": .string(Text.oneLine(r["label"].truthy ? r["label"] : r["task"], 90)),
                            "status": r["status"] ?? .null, "runtime": r["runtime"] ?? .null,
                            "startedAt": secs(r["started_at"] ?? .null), "lastTool": r["last_tool_name"] ?? .null,
                            "progress": .string(Text.oneLine(r["progress_summary"], 140))])
        }
        var problems: [JSON] = []
        for r in try Self.query(db, "select label, task, status, ended_at, error, terminal_summary from task_runs "
                           + "where status in ('failed','timed_out') and coalesce(ended_at, created_at) > ? "
                           + "order by coalesce(ended_at, created_at) desc limit 8", [nowMs - 7 * 86_400_000]) {
            problems.append(["label": .string(Text.oneLine(r["label"].truthy ? r["label"] : r["task"], 90)),
                             "status": r["status"] ?? .null, "at": secs(r["ended_at"] ?? .null),
                             "why": .string(Text.oneLine(r["error"].truthy ? r["error"] : r["terminal_summary"], 180))])
        }
        var routines: [JSON] = []
        for r in try Self.query(db, "select coalesce(label, task) name, count(*) n, max(coalesce(ended_at, created_at)) last, "
                           + "sum(status in ('failed','timed_out')) bad from task_runs "
                           + "where coalesce(ended_at, created_at) > ? group by 1 order by n desc limit 12",
                           [nowMs - 86_400_000]) {
            routines.append(["name": .string(Text.oneLine(r["name"], 80)), "count": r["n"] ?? .null,
                             "last": secs(r["last"] ?? .null), "failed": r["bad"].truthy ? r["bad"]! : .int(0)])
        }
        var schedules: [JSON] = []
        for r in try Self.query(db, "select name, enabled, job_json, state_json from cron_jobs order by enabled desc, name") {
            let job = Self.parse(r["job_json"]), state = Self.parse(r["state_json"])
            let ok = job != nil && state != nil
            let j = ok ? job! : JSONObject(), s = ok ? state! : JSONObject()
            schedules.append(["name": r["name"] ?? .null, "enabled": .bool(r["enabled"].truthy),
                              "cron": j["schedule"]?["expr"] ?? .null, "next": secs(s["nextRunAtMs"] ?? .null),
                              "last": secs(s["lastRunAtMs"] ?? .null), "lastStatus": s["lastStatus"] ?? .null])
        }
        return ["running": .array(running), "problems": .array(problems), "routines": .array(routines),
                "schedules": .array(schedules)]
    }

    /// `json.loads(text or "{}")` that returns nil where Python would raise.
    static func parse(_ v: JSON?) -> JSONObject? {
        guard let v, v.truthy else { return JSONObject() }
        guard case .string(let s) = v, let parsed = try? JSON.parse(s) else { return nil }
        return parsed.object ?? JSONObject()
    }

    static func query(_ db: OpaquePointer, _ sql: String, _ args: [Double] = []) throws -> [JSONObject] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, a) in args.enumerated() { sqlite3_bind_double(stmt, Int32(i + 1), a) }
        var rows: [JSONObject] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw DatabaseError(message: String(cString: sqlite3_errmsg(db))) }
            var o = JSONObject()
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: o[name] = .int(Int(sqlite3_column_int64(stmt, c)))
                case SQLITE_FLOAT: o[name] = .double(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT: o[name] = .string(String(cString: sqlite3_column_text(stmt, c)))
                case SQLITE_NULL: o[name] = .null
                default: o[name] = .null
                }
            }
            rows.append(o)
        }
        return rows
    }
}
