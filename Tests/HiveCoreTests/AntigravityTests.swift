import Foundation
import Testing
@testable import HiveCore

/// Google Antigravity against the contract fixtures written by scripts/make_contract_fixtures.py: its
/// conversation database, transcripts, live feed, background task logs, tokens and board rows.
@Suite struct AntigravityContractTests {
    static let utc = TimeZone(identifier: "UTC")!

    static func board(_ home: URL = Fixture.shared, expected: String = "board-antigravity.json") throws -> Board {
        let table = Fixture.processes(try Fixture.expected(expected, home: home))
        return Board(paths: Fixture.paths(home), processes: FixedProcesses(table: table), now: { Fixture.nowDate },
                     pidAlive: Fixture.pidAlive)
    }

    @Test func boardRowsMatchServer() async throws {
        let expected = try Fixture.expected("board-antigravity.json")
        let board = try Self.board()
        await board.refresh()
        let payload = try JSON.parse(await board.payload())
        let sessions = try #require(payload["sessions"]?.array)
        let rows = sessions.filter { $0["provider"] == "google" }
        let diff = contractDiff(.array(rows), expected["rows"])
        #expect(diff.isEmpty, "\(diff.prefix(12).joined(separator: "\n"))")
        // The whole board in server.py's order: Antigravity rows sorted in with Claude's.
        #expect(JSON.array(sessions.compactMap { $0["id"] }) == expected["ids"])
        // Every Antigravity row has doing, even when it ended, as server.py writes it.
        #expect(rows.allSatisfy { $0.object?.keys.contains("doing") == true })
        #expect(rows.allSatisfy { $0["canReply"] == false && $0["replyNote"] == .null })
    }

    @Test func readerMatchesServer() throws {
        let expected = try Fixture.expected("antigravity-sessions.json")
        let paths = Fixture.paths()
        let transcripts = TranscriptReader(paths: paths)
        let reader = AntigravityReader(paths: paths, transcripts: transcripts, locator: TranscriptLocator(paths: paths),
                                       now: { Fixture.nowDate }, pidAlive: Fixture.pidAlive)
        let pairs = reader.sessions(Fixture.processes(expected))
        // build_board adds canReply and replyNote afterwards.
        let diff = contractDiff(.array(pairs.map(\.row.json)), expected["rows"], ignoring: ["canReply", "replyNote"])
        #expect(diff.isEmpty, "\(diff.prefix(12).joined(separator: "\n"))")
        let raws = try #require(expected["raws"]?.array)
        #expect(pairs.count == raws.count)
        for (pair, raw) in zip(pairs, raws) {
            #expect(pair.raw.sessionId == raw["sessionId"]?.string)
            #expect(pair.raw.pid == raw["pid"]?.int)
            #expect(pair.raw.status == raw["status"]?.string)
            #expect(pair.raw.entrypoint == "antigravity")
            #expect(pair.raw.updatedAt.map(Int.init) == raw["updatedAt"]?.int)
            #expect(pair.raw.cwd == raw["cwd"]?.string)
        }
        #expect(reader.project(of: "agy-run-0001") == "gemini app")
        #expect(reader.project(of: "agy-ancient-0006") == nil, "older than 48 hours, so never listed")
    }

    @Test func detailsMatchServer() async throws {
        let board = try Self.board()
        await board.refresh()
        let usage = UsageCounter(paths: Fixture.paths(), now: { Fixture.nowDate }, timeZone: Self.utc,
                                 antigravityProject: { board.antigravityProject($0) })
        usage.scan()
        for (name, sid) in [("detail-agy-run.json", "agy-run-0001"), ("detail-agy-idle.json", "agy-idle-0003")] {
            let expected = try Fixture.expected(name)
            let got = try JSON.parse(try #require(await board.sessionDetail(sid, tokens: { usage.forSession($0) })))
            let diff = contractDiff(got, expected)
            #expect(diff.isEmpty, "\(name): \(diff.prefix(12).joined(separator: "\n"))")
        }
    }

    @Test func liveReportMatchesServer() async throws {
        let expected = try Fixture.expected("live-report-agy-run.json")
        let board = try Self.board()
        await board.refresh()
        let got = try JSON.parse(try #require(await board.live("agy-run-0001")))
        let diff = contractDiff(got, expected)
        #expect(diff.isEmpty, "\(diff.prefix(12).joined(separator: "\n"))")
        #expect(got["tasks"]?.array?.map { $0["id"] } == ["task-7"], "the empty log is skipped")
    }

    @Test func activityMatchesServer() async throws {
        let expected = try Fixture.expected("activity.json")
        let board = try Self.board()
        await board.refresh()
        let got = try JSON.parse(await board.activity())
        let diff = contractDiff(got, expected)
        #expect(diff.isEmpty, "\(diff.prefix(12).joined(separator: "\n"))")
    }

    @Test func liveFeedMatchesServer() throws {
        let feed = LiveFeed(paths: Fixture.paths(), now: { Fixture.nowDate })
        let log = Fixture.paths().antigravityTranscript("agy-run-0001")
        for (name, sub) in [("live-agy-run.json", nil), ("live-agy-sub.json", "A helper")] as [(String, String?)] {
            let expected = try Fixture.expected(name)
            let diff = contractDiff(feed.items(transcript: log, sub: sub).json, expected["items"])
            #expect(diff.isEmpty, "\(name): \(diff.prefix(12).joined(separator: "\n"))")
        }
    }

    @Test func transcriptsAreFoundAndParsedAsAntigravity() throws {
        let paths = Fixture.paths()
        let locator = TranscriptLocator(paths: paths)
        let url = try #require(locator.find("agy-run-0001"))
        #expect(url.path == paths.antigravityTranscript("agy-run-0001").path)
        #expect(paths.isAntigravity(url))
        let tail = try #require(TranscriptReader(paths: paths).read(url))
        #expect(tail.model == "Gemini")
        #expect(tail.pending.map(\.tool) == ["run_command"])
        #expect(SubagentReader(transcripts: TranscriptReader(paths: paths), now: { Fixture.nowDate }).list(transcript: url).isEmpty)
        #expect(locator.find("agy-missing-0000") == nil)
    }
}

@Suite struct AntigravityReaderTests {
    static func reader(_ paths: HivePaths, alive: @escaping @Sendable (Int32) -> Bool = Fixture.pidAlive) -> AntigravityReader {
        AntigravityReader(paths: paths, transcripts: TranscriptReader(paths: paths), locator: TranscriptLocator(paths: paths),
                          now: { Fixture.nowDate }, pidAlive: alive)
    }

    @Test func hubNeedsALivePid() throws {
        let paths = Fixture.paths()
        #expect(Self.reader(paths).hub()?.pid == 424_242)
        #expect(Self.reader(paths).hub()?.httpPort == .int(50001))
        #expect(Self.reader(paths, alive: { _ in false }).hub() == nil)
    }

    @Test func pidFallsBackToTheLanguageServerThenTheApp() throws {
        let home = try Fixture.prepare()
        let paths = Fixture.paths(home)
        try FileManager.default.removeItem(at: paths.antigravity.appending(path: "daemon"))
        let me = getpid()
        let server = ProcRecord(pid: me, ppid: 1, uptime: 5, rssMB: 1, cpu: 0,
                                cmd: "/Applications/Antigravity.app/Contents/Resources/bin/language_server --x")
        let app = ProcRecord(pid: 1, ppid: 0, uptime: 5, rssMB: 1, cpu: 0,
                             cmd: "/Applications/Antigravity.app/Contents/MacOS/Antigravity")
        let reader = Self.reader(paths, alive: SessionReader.pidAlive)
        #expect(reader.pid([me: server, 1: app]) == Int(me))
        #expect(reader.pid([1: app]) == 1)
        #expect(reader.pid([:]) == nil)
        // With no live app every conversation has ended, and none has a web address.
        let rows = reader.sessions([:]).map(\.row)
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0.group == "ended" && !$0.live && $0.pid == nil && $0.webUrl == nil && $0.uptime == nil })
    }

    @Test func noDatabaseMeansNoRows() throws {
        let paths = HivePaths(home: URL(filePath: "/nonexistent-\(UUID().uuidString)"), uid: 501)
        #expect(Self.reader(paths).sessions([:]).isEmpty)
    }

    @Test func versionComesFromTheAppBundle() {
        #expect(Self.reader(Fixture.paths()).version() == "1.2.3")
        var paths = Fixture.paths()
        paths.antigravityApp = URL(filePath: "/nonexistent/Antigravity.app")
        #expect(Self.reader(paths).version() == nil)
    }

    @Test func appNames() {
        #expect(MacSummary.appName("/Applications/Antigravity.app/Contents/Frameworks/Antigravity Helper.app/x") == "Google Antigravity")
        #expect(MacSummary.appName("/Applications/Gemini.app/Contents/MacOS/Gemini") == "Google Gemini")
        func label(_ cmd: String) -> String? { SystemReport.otherAgents.first { Text.matches($0.pattern, cmd) }?.label }
        #expect(label("/Applications/Antigravity.app/Contents/MacOS/Antigravity") == "Google Antigravity")
        #expect(label("/Applications/Antigravity.app/Contents/Resources/bin/language_server --port 1") == "Google Antigravity language server")
        #expect(label("/Applications/Antigravity.app/Contents/Frameworks/Antigravity Helper.app/Contents/MacOS/Antigravity Helper") == "skip")
        #expect(label("/Applications/Gemini.app/Contents/MacOS/Gemini") == "Google Gemini")
    }

    @Test func resumeCommandOpensTheFolderInAntigravity() async throws {
        let board = try AntigravityContractTests.board()
        await board.refresh()
        let detail = try JSON.parse(try #require(await board.sessionDetail("agy-run-0001")))
        #expect(detail["resumeCommand"] == "open -a Antigravity '/fixture/Projects/gemini app'")
        #expect(detail["webUrl"] == "http://127.0.0.1:50001/c/agy-run-0001")
    }
}

final class RecordingLauncher: AppLauncher, @unchecked Sendable {
    let lock = NSLock()
    private(set) var runs: [[String]] = []
    func run(_ program: String, _ arguments: [String]) { lock.withLock { runs.append([program] + arguments) } }
}

final class FakeDevTools: DevToolsClient, @unchecked Sendable {
    let lock = NSLock()
    var pages: JSON = []
    var failList = false
    private(set) var gets: [String] = []
    private(set) var navigations: [(socket: String, url: String)] = []

    func get(_ url: URL) async throws -> Data {
        lock.withLock { gets.append(url.absoluteString) }
        if failList, url.path.hasSuffix("/json/list") { throw URLError(.cannotConnectToHost) }
        return url.path.hasSuffix("/json/list") ? pages.serialized() : Data("{}".utf8)
    }

    func navigate(webSocket: URL, to url: String) async throws {
        lock.withLock { navigations.append((webSocket.absoluteString, url)) }
    }
}

/// `open_antigravity_session`: brings Antigravity forward and, through its DevTools port, switches the window
/// to the conversation. Only fakes here; nothing is sent to a real Antigravity.
@Suite struct AntigravityOpenerTests {
    static let open = ["/usr/bin/open", "-a", "Antigravity"]
    static let activate = ["/usr/bin/osascript", "-e", "tell application \"Antigravity\" to activate"]

    static func setUp(port: Bool = true, hub: Bool = true) throws -> (HivePaths, RecordingLauncher, FakeDevTools, AntigravityOpener) {
        let home = try Fixture.prepare()
        let paths = Fixture.paths(home)
        if !hub { try FileManager.default.removeItem(at: paths.antigravity.appending(path: "daemon")) }
        if port {
            let file = paths.antigravityDevToolsPorts[0]
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("9333\n/devtools/browser/abc\n".utf8).write(to: file)
        }
        let launcher = RecordingLauncher(), devtools = FakeDevTools()
        let appProcess = ProcRecord(pid: Fixture.antigravityPID, ppid: 1, uptime: 1, rssMB: 1, cpu: 0,
                                    cmd: "/Applications/Antigravity.app/Contents/Resources/bin/language_server --x")
        let opener = AntigravityOpener(paths: paths, launcher: launcher, devtools: devtools, pidAlive: Fixture.pidAlive,
                                       pause: { _ in }, processes: { [Fixture.antigravityPID: appProcess] })
        return (paths, launcher, devtools, opener)
    }

    static func page(_ url: String, id: String = "P1") -> JSON {
        ["id": .string(id), "type": "page", "url": .string(url),
         "webSocketDebuggerUrl": .string("ws://127.0.0.1:9333/devtools/page/\(id)")]
    }

    @Test func withoutADevToolsPortItLaunchesTheApp() async throws {
        let (_, launcher, devtools, opener) = try Self.setUp(port: false)
        let r = await opener.open(sessionId: "agy-run-0001", cwd: "/nonexistent/folder")
        #expect(r.ok)
        #expect(r.message == "Launched Antigravity.")
        #expect(launcher.runs == [Self.open, Self.open])
        #expect(devtools.gets.isEmpty)
        let (_, launcher2, _, opener2) = try Self.setUp(port: false)
        let folder = FileManager.default.temporaryDirectory.path
        _ = await opener2.open(sessionId: "agy-run-0001", cwd: folder)
        #expect(launcher2.runs == [Self.open, Self.open + [folder]])
    }

    @Test func switchesThePageToTheConversation() async throws {
        let (_, launcher, devtools, opener) = try Self.setUp()
        devtools.pages = [["id": "W", "type": "service_worker", "url": "http://127.0.0.1:50001/sw.js"],
                          Self.page("https://127.0.0.1:50002/c/other-0001?tab=1")]
        let r = await opener.open(sessionId: "agy-run-0001", cwd: nil)
        #expect(r.ok)
        #expect(r.message == "Opened session in Antigravity.")
        #expect(devtools.gets == ["http://127.0.0.1:9333/json/list", "http://127.0.0.1:9333/json/activate/P1"])
        #expect(devtools.navigations.map(\.socket) == ["ws://127.0.0.1:9333/devtools/page/P1"])
        #expect(devtools.navigations.map(\.url) == ["https://127.0.0.1:50002/c/agy-run-0001"])
        #expect(launcher.runs == [Self.open, Self.activate])
    }

    @Test func aPageAlreadyOnTheConversationIsOnlyBroughtForward() async throws {
        let (_, launcher, devtools, opener) = try Self.setUp()
        devtools.pages = [Self.page("https://127.0.0.1:50002/c/agy-run-0001")]
        let r = await opener.open(sessionId: "agy-run-0001", cwd: nil)
        #expect(r == (true, "Opened session in Antigravity."))
        #expect(devtools.navigations.isEmpty)
        #expect(launcher.runs == [Self.open, Self.activate])
    }

    @Test func aPageWithoutTheAppAddressUsesTheHub() async throws {
        let (_, _, devtools, opener) = try Self.setUp()
        devtools.pages = [Self.page("chrome://workbench?host=127.0.0.1")]
        _ = await opener.open(sessionId: "agy-run-0001", cwd: nil)
        #expect(devtools.navigations.map(\.url) == ["https://127.0.0.1:50002/c/agy-run-0001"])

        let (_, launcher2, devtools2, opener2) = try Self.setUp(hub: false)
        devtools2.pages = [Self.page("chrome://workbench?host=127.0.0.1")]
        let r = await opener2.open(sessionId: "agy-run-0001", cwd: nil)
        #expect(r == (false, "Brought Antigravity forward, but couldn't find the session's address."))
        #expect(devtools2.navigations.isEmpty)
        #expect(launcher2.runs == [Self.open])
    }

    @Test func noAppPageBringsItToFront() async throws {
        let (_, launcher, devtools, opener) = try Self.setUp()
        devtools.pages = [["id": "X", "type": "page", "url": "about:blank"]]
        let r = await opener.open(sessionId: "agy-run-0001", cwd: nil)
        #expect(r == (true, "Brought Antigravity to front."))
        #expect(launcher.runs == [Self.open])
    }

    @Test func aFailureStillBringsItForward() async throws {
        let (_, launcher, devtools, opener) = try Self.setUp()
        devtools.failList = true
        let r = await opener.open(sessionId: "agy-run-0001", cwd: nil)
        #expect(!r.ok)
        #expect(r.message.hasPrefix("Brought Antigravity forward, but couldn't switch to the session: "))
        #expect(launcher.runs == [Self.open])
    }
}

@Suite struct AntigravityActionTests {
    static func api(_ board: Board, actions: RecordingActions, replies: ReplySender? = nil) -> HiveAPI {
        let paths = Fixture.paths()
        return HiveAPI(board: board, usage: UsageCounter(paths: paths), skills: SkillsReader(paths: paths),
                       jobs: SkillsJobs(paths: paths, runner: FakeRunner()), system: SystemReport(paths: paths),
                       classroom: ClassroomStore(paths: HivePaths(home: URL(filePath: "/nonexistent-\(UUID().uuidString)"), uid: 501)),
                       actions: actions, replies: replies)
    }

    /// `run_action` sends Antigravity rows to `open_antigravity_session` and answers with the web address too.
    @Test func openGoesToAntigravity() async throws {
        let board = try AntigravityContractTests.board()
        await board.refresh()
        let actions = RecordingActions()
        let (status, body) = await HiveAPITests.post(Self.api(board, actions: actions), "/api/action",
                                                     #"{"sessionId": "agy-run-0001", "action": "open"}"#)
        #expect(status == 200)
        #expect(body == ["ok": true, "message": "Opened session in Antigravity.", "url": "http://127.0.0.1:50001/c/agy-run-0001"])
        #expect(actions.antigravity.map(\.sessionId) == ["agy-run-0001"])
        #expect(actions.antigravity.map(\.cwd) == ["/fixture/Projects/gemini app"])
        #expect(actions.opened.isEmpty, "never sent to Claude, although its hostId looks like an id")
    }

    /// Replies are for Claude Code sessions: an Antigravity row, even an ended one, gets no reply box.
    @Test func antigravityRowsTakeNoReplies() async throws {
        let runner = FakeReplyRunner()
        let sender = ReplySender(paths: Fixture.paths(), runner: runner)
        let board = try AntigravityContractTests.board()
        await board.setReplies(sender, capabilities: ["reply": true])
        await board.refresh()
        let state = await board.snapshot()
        let rows = state.rows.filter { $0.provider == "google" }
        #expect(rows.contains { !$0.live })
        #expect(rows.allSatisfy { !$0.canReply && $0.replyNote == nil })
        let r = await sender.reply(sessionId: "agy-old-0004", text: "hello", state: state)
        #expect(r.status == 409)
        #expect(runner.count == 0)
    }
}
