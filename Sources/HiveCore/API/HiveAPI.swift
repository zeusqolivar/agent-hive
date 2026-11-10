import Foundation

/// The native actions the pages can ask for.
public protocol ActionHandler: Sendable {
    /// Opens a Claude desktop session by its host id (`claude://code/continue?session=<id>`).
    func open(hostSessionId: String) -> Bool
    /// Shows a folder in Finder.
    func reveal(folder: URL) -> Bool
    /// Brings Antigravity forward on a conversation (`AntigravityOpener`).
    func openAntigravity(sessionId: String, cwd: String?) async -> (ok: Bool, message: String)
}

/// Sends a reply to a session. Set when the app supports replies.
public protocol ReplyHandler: Sendable {
    func reply(sessionId: String, text: String, state: BoardState) async -> (status: Int, body: JSON)
}

/// Answers the same paths as server.py, for the pages running inside the app.
public struct HiveAPI: Sendable {
    public struct Response: Sendable {
        public var status: Int
        public var contentType: String
        public var body: Data
    }

    static let json = "application/json; charset=utf-8"
    static let maxBody = 10_000

    let board: Board
    let usage: UsageCounter
    let skills: SkillsReader
    let jobs: SkillsJobs
    let system: SystemReport
    let classroom: ClassroomStore
    let actions: ActionHandler
    let pages: URL?
    let replies: ReplyHandler?

    public init(board: Board, usage: UsageCounter, skills: SkillsReader, jobs: SkillsJobs, system: SystemReport,
                classroom: ClassroomStore, actions: ActionHandler, pages: URL? = nil, replies: ReplyHandler? = nil) {
        self.board = board
        self.usage = usage
        self.skills = skills
        self.jobs = jobs
        self.system = system
        self.classroom = classroom
        self.actions = actions
        self.pages = pages
        self.replies = replies
    }

    static func reply(_ status: Int, _ body: JSON) -> Response {
        Response(status: status, contentType: json, body: body.serialized())
    }

    static func error(_ status: Int, _ message: String) -> Response {
        reply(status, ["error": .string(message)])
    }

    private static let sessionPath = try! NSRegularExpression(pattern: #"^/api/session/([A-Za-z0-9_-]+)(?:/agent/([A-Za-z0-9_-]+))?$"#)
    private static let livePath = try! NSRegularExpression(pattern: #"^/api/session/([A-Za-z0-9_-]+)/live$"#)

    public func handle(method: String, path rawPath: String, body: Data?) async -> Response {
        let path = rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rawPath
        switch method {
        case "GET": return await get(path)
        case "POST": return await post(path, body ?? Data())
        default: return Self.error(405, "Method not allowed")
        }
    }

    private func get(_ path: String) async -> Response {
        if path.hasPrefix("/api/"), path != "/api/board", path != "/api/classroom" { await board.waitUntilReady() }
        switch path {
        case "/healthz":
            return Response(status: 200, contentType: "text/plain", body: Data("ok".utf8))
        case "/api/board":
            return Response(status: 200, contentType: Self.json, body: await board.payload())
        case "/api/activity":
            return Response(status: 200, contentType: Self.json, body: await board.activity())
        case "/api/usage":
            let board = self.board
            return Response(status: 200, contentType: Self.json, body: await usage.report(title: { await board.title($0) }))
        case "/api/system":
            return Response(status: 200, contentType: Self.json, body: system.make(state: await board.snapshot()))
        case "/api/skills":
            guard case .object(var o) = skills.report() else { return Self.error(500, "No skills report") }
            o["job"] = jobs.status()
            return Self.reply(200, .object(o))
        case "/api/classroom":
            return Self.reply(200, ["room": classroom.load()])
        default:
            break
        }
        if let m = Self.match(Self.livePath, path) {
            guard let data = await board.live(m[0]) else { return Self.error(404, "Not found") }
            return Response(status: 200, contentType: Self.json, body: data)
        }
        if let m = Self.match(Self.sessionPath, path) {
            let data: Data?
            if m.count > 1, let agent = m[1] as String?, !agent.isEmpty {
                data = await board.agentDetail(m[0], agentId: agent)
            } else {
                let usage = self.usage
                data = await board.sessionDetail(m[0], tokens: { usage.forSession($0) })
            }
            guard let data else { return Self.error(404, "Not found") }
            return Response(status: 200, contentType: Self.json, body: data)
        }
        if path.hasPrefix("/api/") { return Self.error(404, "Not found") }
        return page(path)
    }

    private func post(_ path: String, _ body: Data) async -> Response {
        guard ["/api/action", "/api/skills/run", "/api/reply", "/api/classroom"].contains(path) else {
            return Self.error(404, "Not found")
        }
        if path == "/api/classroom" { return saveClassroom(body) }
        let parsed: JSON
        do {
            parsed = try JSON.parse(body.isEmpty ? Data("{}".utf8) : body.prefix(Self.maxBody))
        } catch {
            return Self.error(400, "The request body isn't valid JSON.")
        }
        let request = parsed.object ?? JSONObject()
        switch path {
        case "/api/action":
            return await action(request)
        case "/api/skills/run":
            let r = jobs.start(action: request["action"]?.string, plugin: request["plugin"]?.string)
            return Response(status: r.status, contentType: Self.json, body: r.body)
        default:
            guard let replies else { return Self.error(404, "Not found") }
            let state = await board.snapshot()
            let text = request["text"]?.string ?? ""
            let r = await replies.reply(sessionId: Py.str(orEmpty: request["sessionId"]), text: text, state: state)
            return Self.reply(r.status, r.body)
        }
    }

    /// `POST /api/classroom`: `{room}` saves the arrangement, `{room: null}` deletes it; 400 with the reason
    /// for a body over 64 KB, one without `room`, or a room whose structure is wrong.
    private func saveClassroom(_ body: Data) -> Response {
        if body.count > ClassroomStore.maxBody { return Self.error(400, "The room is larger than 64 KB.") }
        guard let parsed = try? JSON.parse(body.isEmpty ? Data("{}".utf8) : body) else {
            return Self.error(400, "The request body isn't valid JSON.")
        }
        let r = classroom.save(parsed)
        return Self.reply(r.status, r.body)
    }

    private func action(_ request: JSONObject) async -> Response {
        let sid = Py.str(orEmpty: request["sessionId"])
        let state = await board.snapshot()
        guard let row = state.row(sid) else { return Self.error(404, "This session is no longer on the board.") }
        switch request["action"]?.string {
        case "reveal":
            var isDir: ObjCBool = false
            guard let cwd = row.cwd, FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
                return Self.error(409, "That folder no longer exists.")
            }
            guard actions.reveal(folder: URL(filePath: cwd, directoryHint: .isDirectory)) else {
                return Self.error(500, "Couldn't open the folder.")
            }
            return Self.reply(200, ["ok": true, "message": "Opened the folder in Finder."])
        case "open":
            if row.provider == "google" || row.entry == "antigravity" {
                let r = await actions.openAntigravity(sessionId: sid, cwd: row.cwd)
                return Self.reply(200, ["ok": .bool(r.ok), "message": .string(r.message), "url": JSON(row.webUrl)])
            }
            guard let host = row.hostId, Patterns.isID(host) else {
                return Self.error(409, "This session isn't running in the Claude app.")
            }
            guard actions.open(hostSessionId: host) else { return Self.error(500, "Couldn't open Claude.") }
            return Self.reply(200, ["ok": true, "message": "Opened in Claude."])
        default:
            return Self.error(400, "Unknown action.")
        }
    }

    static let types = ["html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8",
                        "css": "text/css; charset=utf-8", "json": "application/json; charset=utf-8",
                        "svg": "image/svg+xml", "png": "image/png", "ico": "image/x-icon"]

    /// The scripts served beside `index.html`: server.py's `PAGE_SCRIPTS`.
    public static let pageScripts = ["room.js", "classroom-layout.js", "sample-board.js", "room-path.js",
                                     "room-model.js", "room-editor.js"]

    /// A file from the bundled web folder: `/` is `index.html`, plus the page scripts, as server.py serves.
    private func page(_ path: String) -> Response {
        let name = path == "/" ? "index.html" : String(path.dropFirst())
        guard let pages, name == "index.html" || Self.pageScripts.contains(name),
              let data = FileManager.default.contents(atPath: pages.appending(path: name).path) else {
            return Self.error(404, "Not found")
        }
        let ext = (name as NSString).pathExtension.lowercased()
        return Response(status: 200, contentType: Self.types[ext] ?? "application/octet-stream", body: data)
    }

    static func match(_ regex: NSRegularExpression, _ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }
}
