import Foundation
import Testing
@testable import HiveCore

final class RecordingActions: ActionHandler, @unchecked Sendable {
    let lock = NSLock()
    private(set) var opened: [String] = []
    private(set) var revealed: [URL] = []
    private(set) var antigravity: [(sessionId: String, cwd: String?)] = []
    func open(hostSessionId: String) -> Bool { lock.withLock { opened.append(hostSessionId) }; return true }
    func reveal(folder: URL) -> Bool { lock.withLock { revealed.append(folder) }; return true }
    func openAntigravity(sessionId: String, cwd: String?) async -> (ok: Bool, message: String) {
        lock.withLock { antigravity.append((sessionId, cwd)) }
        return (true, "Opened session in Antigravity.")
    }
    var calls: Int { lock.withLock { opened.count + revealed.count + antigravity.count } }
}

@Suite struct HiveAPITests {
    static func api(actions: RecordingActions = RecordingActions(), web: URL? = nil,
                    classroom: ClassroomStore? = nil) async throws -> HiveAPI {
        let (paths, procs) = try BoardTests.liveHome()
        let board = Board(paths: paths, processes: procs, now: { Fixture.nowDate })
        await board.refresh()
        let usage = UsageCounter(paths: paths, now: { Fixture.nowDate })
        return HiveAPI(board: board, usage: usage, skills: SkillsReader(paths: paths),
                       jobs: SkillsJobs(paths: paths, runner: FakeRunner()), system: SystemReport(paths: paths),
                       classroom: classroom ?? ClassroomStore(paths: paths), actions: actions, pages: web)
    }

    static func post(_ api: HiveAPI, _ path: String, _ body: String) async -> (Int, JSON?) {
        let r = await api.handle(method: "POST", path: path, body: Data(body.utf8))
        return (r.status, try? JSON.parse(r.body))
    }

    @Test func boardIsJSON() async throws {
        let r = try await Self.api().handle(method: "GET", path: "/api/board", body: nil)
        #expect(r.status == 200)
        #expect(r.contentType.hasPrefix("application/json"))
        #expect(try JSON.parse(r.body)["sessions"]?.array?.isEmpty == false)
    }

    @Test func unknownPathIs404() async throws {
        let api = try await Self.api()
        #expect(await api.handle(method: "GET", path: "/api/nope", body: nil).status == 404)
        #expect(await api.handle(method: "GET", path: "/api/session/missing-session", body: nil).status == 404)
        #expect(await api.handle(method: "GET", path: "/api/session/a%2F..%2Fb/live", body: nil).status == 404)
        #expect(await api.handle(method: "POST", path: "/api/nope", body: Data("{}".utf8)).status == 404)
        #expect(await api.handle(method: "DELETE", path: "/api/board", body: nil).status == 405)
    }

    @Test func everyGetRouteAnswers() async throws {
        let api = try await Self.api()
        for path in ["/api/activity", "/api/usage", "/api/system", "/api/skills", "/api/session/sess-main-0001",
                     "/api/session/sess-main-0001/live", "/api/session/sess-main-0001/agent/a1b2c3d4"] {
            let r = await api.handle(method: "GET", path: path, body: nil)
            #expect(r.status == 200, "\(path)")
            #expect((try? JSON.parse(r.body))?.object != nil, "\(path)")
        }
        let skills = try JSON.parse(await api.handle(method: "GET", path: "/api/skills", body: nil).body)
        #expect(skills["job"]?["running"] == false)
        #expect(skills["plugins"]?.array != nil)
        let health = await api.handle(method: "GET", path: "/healthz", body: nil)
        #expect(String(decoding: health.body, as: UTF8.self) == "ok")
    }

    @Test func actionForASessionNotOnTheBoardRunsNothing() async throws {
        let actions = RecordingActions()
        let api = try await Self.api(actions: actions)
        let (status, body) = await Self.post(api, "/api/action", #"{"sessionId": "not-on-board-1", "action": "open"}"#)
        #expect(status == 404)
        #expect(body?["error"] == "This session is no longer on the board.")
        let (status2, _) = await Self.post(api, "/api/action", #"{"sessionId": "../../etc", "action": "reveal"}"#)
        #expect(status2 == 404)
        #expect(actions.calls == 0)
    }

    @Test func nonJSONBodyIs400() async throws {
        let actions = RecordingActions()
        let api = try await Self.api(actions: actions)
        #expect(await Self.post(api, "/api/action", "not json").0 == 400)
        #expect(await Self.post(api, "/api/skills/run", "{oops").0 == 400)
        #expect(await Self.post(api, "/api/action", "[1, 2]").0 == 404)
        #expect(actions.calls == 0)
    }

    @Test func openAndReveal() async throws {
        let actions = RecordingActions()
        let api = try await Self.api(actions: actions)
        let (s1, b1) = await Self.post(api, "/api/action", #"{"sessionId": "sess-main-0001", "action": "open"}"#)
        #expect(s1 == 200)
        #expect(b1?["message"] == "Opened in Claude.")
        #expect(actions.opened == ["local_abc123def"])
        // The folder comes from the session's data, never the request; it doesn't exist in the fixture.
        let (s2, b2) = await Self.post(api, "/api/action", #"{"sessionId": "sess-main-0001", "action": "reveal", "cwd": "/"}"#)
        #expect(s2 == 409)
        #expect(b2?["error"] == "That folder no longer exists.")
        #expect(actions.revealed.isEmpty)
        let (s3, _) = await Self.post(api, "/api/action", #"{"sessionId": "sess-asked-0002", "action": "open"}"#)
        #expect(s3 == 409)
        #expect(await Self.post(api, "/api/action", #"{"sessionId": "sess-main-0001", "action": "delete"}"#).0 == 400)
    }

    @Test func skillsJobValidation() async throws {
        let api = try await Self.api()
        #expect(await Self.post(api, "/api/skills/run", #"{"action": "update", "plugin": "x; rm -rf /"}"#).0 == 400)
    }

    @Test func pagesAreServedFromTheWebFolder() async throws {
        let web = FileManager.default.temporaryDirectory.appending(path: "hive-web-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try Data("<html>hi</html>".utf8).write(to: web.appending(path: "index.html"))
        for name in HiveAPI.pageScripts {
            try Data("var x = 1;".utf8).write(to: web.appending(path: name))
        }
        try Data("var y = 2;".utf8).write(to: web.appending(path: "other.js"))
        let api = try await Self.api(web: web)
        let index = await api.handle(method: "GET", path: "/", body: nil)
        #expect(index.status == 200)
        #expect(index.contentType.hasPrefix("text/html"))
        for name in HiveAPI.pageScripts {
            let js = await api.handle(method: "GET", path: "/" + name, body: nil)
            #expect(js.status == 200, "\(name)")
            #expect(js.contentType.hasPrefix("text/javascript"), "\(name)")
        }
        // Only the files server.py serves: index.html and its PAGE_SCRIPTS.
        #expect(await api.handle(method: "GET", path: "/other.js", body: nil).status == 404)
        #expect(await api.handle(method: "GET", path: "/SOURCE", body: nil).status == 404)
        #expect(await api.handle(method: "GET", path: "/../secret.js", body: nil).status == 404)
        #expect(await api.handle(method: "GET", path: "/missing.js", body: nil).status == 404)
    }

    /// The pages bundled with the app: every script server.py serves, every script index.html loads,
    /// and SOURCE naming the agent-dashboard commit they were copied from.
    @Test func bundledPagesMatchThePageScripts() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let web = root.appending(path: "Sources/HiveApp/Resources/web")
        for name in ["index.html"] + HiveAPI.pageScripts {
            #expect(FileManager.default.fileExists(atPath: web.appending(path: name).path), "\(name)")
        }
        let index = try String(contentsOf: web.appending(path: "index.html"), encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"<script src="/([^"]+)""#)
        let loaded = regex.matches(in: index, range: NSRange(index.startIndex..., in: index))
            .map { (index as NSString).substring(with: $0.range(at: 1)) }
        #expect(!loaded.isEmpty)
        #expect(Set(loaded).isSubset(of: Set(HiveAPI.pageScripts)), "\(loaded)")
        let source = try String(contentsOf: web.appending(path: "SOURCE"), encoding: .utf8)
        #expect(source.range(of: #"commit [0-9a-f]{40}\b"#, options: .regularExpression) != nil, "\(source)")
    }
}

@Suite struct HiveAPIStartupTests {
    @Test func viewsWaitForTheFirstRefresh() async throws {
        let (paths, procs) = try BoardTests.liveHome()
        let board = Board(paths: paths, processes: procs, now: { Fixture.nowDate })
        let api = HiveAPI(board: board, usage: UsageCounter(paths: paths), skills: SkillsReader(paths: paths),
                          jobs: SkillsJobs(paths: paths, runner: FakeRunner()), system: SystemReport(paths: paths),
                          classroom: ClassroomStore(paths: paths), actions: RecordingActions())
        await board.start()
        let r = await api.handle(method: "GET", path: "/api/activity", body: nil)
        await board.stop()
        #expect((try JSON.parse(r.body))["items"]?.array?.isEmpty == false)
    }
}
