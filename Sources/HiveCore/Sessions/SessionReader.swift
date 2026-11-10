import Foundation

/// The fields of `~/.claude/sessions/<pid>.json` that Agent Hive uses. Claude Code writes the file.
public struct SessionFile: Codable, Sendable, Equatable {
    public var pid: Int?
    public var sessionId: String?
    public var cwd: String?
    public var status: String?
    public var waitingFor: String?
    public var name: String?
    public var hostSessionId: String?
    public var entrypoint: String?
    public var version: String?
    public var startedAt: Double?
    public var statusUpdatedAt: Double?
    public var updatedAt: Double?
    public var formerNames: [String]?

    public init() {}

    /// Reads the fields leniently: a field of an unexpected type is treated as missing.
    public init(json o: JSONObject) {
        func s(_ k: String) -> String? {
            guard let v = o[k], v.truthy else { return nil }
            return Py.str(v)
        }
        pid = o["pid"]?.int ?? o["pid"]?.string.flatMap { Int($0) }
        sessionId = s("sessionId")
        cwd = s("cwd")
        status = o["status"]?.string
        waitingFor = s("waitingFor")
        name = s("name")
        hostSessionId = s("hostSessionId")
        entrypoint = s("entrypoint")
        version = s("version")
        startedAt = o["startedAt"]?.number
        statusUpdatedAt = o["statusUpdatedAt"]?.number
        updatedAt = o["updatedAt"]?.number
        if let names = o["formerNames"]?.array {
            formerNames = names.map { $0["name"].map { $0.isNull ? "" : Py.str($0) } ?? "" }
        }
    }
}

public enum SessionReader {
    /// Session files whose process is alive. Only `*.json` files are opened; the `.key` files beside them
    /// are never read. A pid that is alive but whose process isn't Claude (the pid was reused after the
    /// session ended) doesn't count. A pid missing from the process list still counts, because a slow
    /// `ps` says nothing about what's alive.
    public static func liveSessions(paths: HivePaths, processes: [Int32: ProcRecord]) -> [SessionFile] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: paths.sessions.path) else { return [] }
        var out: [SessionFile] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            let url = paths.sessions.appending(path: name, directoryHint: .notDirectory)
            guard let data = try? Data(contentsOf: url), let o = (try? JSON.parse(data))?.object else { continue }
            let raw = SessionFile(json: o)
            guard raw.sessionId != nil, let pid = raw.pid, pid > 0, pid <= Int(Int32.max), pidAlive(Int32(pid)) else { continue }
            if let p = processes[Int32(pid)], !p.cmd.lowercased().contains("claude") { continue }
            out.append(raw)
        }
        return out
    }

    /// `kill(pid, 0)`: alive unless the process doesn't exist. EPERM means it exists.
    public static func pidAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
