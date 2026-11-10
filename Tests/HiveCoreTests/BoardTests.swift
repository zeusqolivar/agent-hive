import Foundation
import Testing
@testable import HiveCore

struct FixedProcesses: ProcessSource {
    var table: [Int32: ProcRecord]
    func snapshot() throws -> [Int32: ProcRecord] { table }
}

@Suite struct BoardTests {
    /// A fixture home where the test process stands in for a live Claude session on sess-main-0001.
    static func liveHome() throws -> (HivePaths, FixedProcesses) {
        let home = try Fixture.prepare()
        let me = getpid()
        let session = #"{"pid": \#(me), "sessionId": "sess-main-0001", "cwd": "\#(home.path)/Projects/demo", "#
            + #""status": "busy", "name": "Parser work", "hostSessionId": "local_abc123def", "entrypoint": "claude-desktop", "#
            + #""version": "2.1.300", "startedAt": 1794308000000, "statusUpdatedAt": 1794311000000}"#
        try Data(session.utf8).write(to: home.appending(path: ".claude/sessions/\(me).json"))
        let table: [Int32: ProcRecord] = [
            me: proc(me, 1, "/Applications/Claude.app/Contents/MacOS/claude --resume sess-main-0001", cpu: 3, rss: 300, uptime: 4000),
            me + 100_000: proc(me + 100_000, me, "/bin/zsh -c swift build", cpu: 40, rss: 50),
        ]
        return (Fixture.paths(home), FixedProcesses(table: table))
    }

    static func board(_ paths: HivePaths, _ procs: ProcessSource) -> Board {
        Board(paths: paths, processes: procs, now: { Fixture.nowDate })
    }

    @Test func liveRowWithGroupAndHeadline() async throws {
        let (paths, procs) = try Self.liveHome()
        let board = Self.board(paths, procs)
        await board.refresh()
        let payload = try JSON.parse(await board.payload())
        let sessions = try #require(payload["sessions"]?.array)
        let live = sessions.filter { $0["live"] == .bool(true) }
        #expect(live.count == 1)
        let row = try #require(live.first)
        #expect(row["id"] == "sess-main-0001")
        #expect(row["group"] == "working")
        #expect(row["headline"] == "Running Build the package")
        #expect(row["doing"] == "subagents")
        #expect(row["name"] == "Parser work")
        #expect(row["project"] == "demo")
        #expect(row["subagents"] == ["running": 1, "total": 2])
        #expect(row["helpers"]?.array?.count == 1)
        #expect(row["plan"]?["current"] == "Run the full suite")
        #expect(row["statusSince"] == 1_794_311_000)
        #expect(row["startedAt"] == 1_794_308_000)
        #expect(row["uptime"] == 4000)
        #expect(row["canReply"] == false)
        #expect(payload["ready"] == true)
        #expect(payload["capabilities"]?["reply"] == false)
        #expect(payload["cores"]?.int ?? 0 > 0)
    }

    /// A finished turn with plain-text questions: needs you, reason `questions`, the list on the row, and
    /// waiting since the message that asked.
    @Test func openQuestionsRow() async throws {
        let (paths, procs) = try Self.liveHome()
        let me = getpid()
        let session = #"{"pid": \#(me), "sessionId": "sess-questions-0011", "status": "busy", "name": "Dark mode", "#
            + #""statusUpdatedAt": 1794311000000}"#
        try Data(session.utf8).write(to: paths.sessions.appending(path: "q-\(me).json"))
        let board = Self.board(paths, procs)
        await board.refresh()
        let payload = try JSON.parse(await board.payload())
        let sessions = try #require(payload["sessions"]?.array)
        let row = try #require(sessions.first { $0["id"] == "sess-questions-0011" })
        #expect(row["group"] == "needs")
        #expect(row["reason"] == "questions")
        #expect(row["headline"] == "4 open questions: Whether it should follow the system setting by default.")
        #expect(row["questions"] == ["Whether it should follow the system setting by default.",
                                     "The contrast of the disabled buttons", "Ship it behind a flag?",
                                     "Want me to add a screenshot to the README?"])
        let expected = try Fixture.expected("transcript-questions.json", home: paths.home)
        #expect(row["statusSince"] == expected["tail"]?["lastTextTs"])
        #expect(row["statusSince"] != 1_794_311_000, "not the status file's time")
        #expect(sessions.first?["id"] == "sess-questions-0011", "needs you sorts first")
        let main = try #require(sessions.first { $0["id"] == "sess-main-0001" })
        #expect(main["questions"] == [], "live rows without open questions have an empty list")
        let detail = try JSON.parse(try #require(await board.sessionDetail("sess-questions-0011")))
        #expect(detail["questions"]?.array?.count == 4)
    }

    @Test func endedRowsForRecentTranscripts() async throws {
        let (paths, procs) = try Self.liveHome()
        let board = Self.board(paths, procs)
        await board.refresh()
        let payload = try JSON.parse(await board.payload())
        let ended = (payload["sessions"]?.array ?? []).filter { $0["group"] == "ended" && $0["provider"] == nil }
        let ids = Set(ended.compactMap { $0["id"]?.string })
        #expect(ids == ["sess-asked-0002", "sess-done-0003", "sess-big-0004", "sess-usage-0005",
                        "sess-question-0006", "sess-plan-0007", "sess-planned-0009", "sess-questions-0011"])
        #expect(ended.allSatisfy { $0["questions"] == nil }, "ended rows have no questions field, as in server.py")
        let done = try #require(ended.first { $0["id"] == "sess-done-0003" })
        #expect(done["name"] == "Release notes")
        #expect(done["headline"] == "Shipped the release notes for version 2.0.")
        #expect(done["live"] == false)
        let asked = try #require(ended.first { $0["id"] == "sess-asked-0002" })
        #expect(asked["name"] == "Make the release build work.")
    }

    @Test func endedWindowIs48Hours() async throws {
        let (paths, procs) = try Self.liveHome()
        let board = Board(paths: paths, processes: procs, now: { Fixture.nowDate.addingTimeInterval(49 * 3600) })
        await board.refresh()
        let payload = try JSON.parse(await board.payload())
        let ended = (payload["sessions"]?.array ?? []).filter { $0["group"] == "ended" }
        #expect(ended.count == 0)
    }

    @Test func countsMatchRows() async throws {
        let (paths, procs) = try Self.liveHome()
        let board = Self.board(paths, procs)
        await board.refresh()
        let payload = try JSON.parse(await board.payload())
        let sessions = payload["sessions"]?.array ?? []
        for group in ["needs", "working", "idle", "ended"] {
            #expect(payload["counts"]?[group]?.int == sessions.filter { $0["group"]?.string == group }.count)
        }
        // Sorted: needs, working, idle, ended; newest first inside a group.
        let order = sessions.compactMap { $0["group"]?.string }
        #expect(order.first == "working")
    }

    @Test func sessionDetailAndMissing() async throws {
        let (paths, procs) = try Self.liveHome()
        let board = Self.board(paths, procs)
        await board.refresh()
        #expect(await board.sessionDetail("missing-id-000") == nil)
        let detail = try JSON.parse(try #require(await board.sessionDetail("sess-main-0001")))
        #expect(detail["events"]?.array?.first?["title"] == "Run Build the package")
        #expect(detail["planItems"]?.array?.count == 3)
        #expect(detail["subagentList"]?.array?.count == 2)
        #expect(detail["subagentList"]?.array?.first?["state"] == "running")
        #expect(detail["resumeCommand"] == .string("cd \(paths.home.path)/Projects/demo && claude --resume sess-main-0001"))
        #expect(detail["shortCwd"] == "~/Projects/demo")
        #expect(detail["processes"]?["commands"]?.array?.count == 1)
        #expect(detail["mode"] == "acceptEdits")
    }

    @Test func liveFeedAndAgentDetail() async throws {
        let (paths, procs) = try Self.liveHome()
        let board = Self.board(paths, procs)
        await board.refresh()
        let live = try JSON.parse(try #require(await board.live("sess-main-0001")))
        let items = live["items"]?.array ?? []
        #expect(items.contains { $0["sub"] == "Find the parser callers" })
        #expect(live["group"] == "working")
        #expect(await board.live("nope-nope-nope") == nil)
        let agent = try JSON.parse(try #require(await board.agentDetail("sess-main-0001", agentId: "a1b2c3d4")))
        #expect(agent["brief"] == "List every caller of Parser.")
        #expect(agent["last"] == "Read main.swift")
        #expect(await board.agentDetail("sess-main-0001", agentId: "../../etc") == nil)
    }

    @Test func activityAcrossSessions() async throws {
        let (paths, procs) = try Self.liveHome()
        let board = Self.board(paths, procs)
        await board.refresh()
        let items = try JSON.parse(await board.activity())["items"]?.array ?? []
        #expect(!items.isEmpty)
        let times = items.compactMap { $0["t"]?.int }
        #expect(times == times.sorted(by: >))
        #expect(items.allSatisfy { $0["sid"]?.string != nil && $0["err"]?.bool != nil })
    }

    @Test func newUserWithNoClaudeFolder() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "hive-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let board = Self.board(HivePaths(home: home, uid: 501), FixedProcesses(table: [:]))
        await board.refresh()
        let payload = try JSON.parse(await board.payload())
        #expect(payload["ready"] == true)
        #expect(payload["sessions"]?.array?.isEmpty == true)
        #expect(payload["counts"]?["ended"] == 0)
    }

    @Test func notReadyBeforeTheFirstBuild() async throws {
        let (paths, procs) = try Self.liveHome()
        let payload = try JSON.parse(await Self.board(paths, procs).payload())
        #expect(payload["ready"] == false)
        #expect(payload["sessions"]?.array?.isEmpty == true)
    }

    @Test func macSummaryGroupsByApp() {
        let table: [Int32: ProcRecord] = [
            1: proc(1, 0, "/Applications/Safari.app/Contents/MacOS/Safari", cpu: 10, rss: 100),
            2: proc(2, 1, "/Applications/Safari.app/Contents/XPCServices/x", cpu: 5, rss: 50),
            3: proc(3, 0, "/usr/bin/quiet", cpu: 0.5, rss: 5),
            4: proc(4, 0, "/Users/x/.local/bin/claude --model opus", cpu: 2, rss: 300),
        ]
        let mac = MacSummary.make(table)
        let top = mac["top"]?.array ?? []
        #expect(top.first?["name"] == "Safari")
        #expect(top.first?["cpu"] == 15)
        #expect(top.first?["count"] == 2)
        #expect(top.map { $0["name"]?.string ?? "" } == ["Safari", "Claude Code"])
    }

    @Test func shellQuote() {
        #expect(Shell.quote("/Users/a/Projects/demo") == "/Users/a/Projects/demo")
        #expect(Shell.quote("/Users/a/My Project") == "'/Users/a/My Project'")
        #expect(Shell.quote("it's") == #"'it'"'"'s'"#)
        #expect(Shell.quote("") == "''")
    }
}
