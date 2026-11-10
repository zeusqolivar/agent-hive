import Foundation
import Testing
@testable import HiveCore

/// Records reply commands instead of running them; `finish` completes the one in flight.
final class FakeReplyRunner: ReplyRunner, @unchecked Sendable {
    struct Run { var executable: URL; var args: [String]; var stdin: String; var env: [String: String]; var dir: URL }
    let lock = NSLock()
    private(set) var runs: [Run] = []
    private var completions: [@Sendable (Int32, String) -> Void] = []
    var installed = true
    var loggedIn = true
    private(set) var signInChecks = 0

    func find(_ tool: String) -> URL? { installed ? URL(filePath: "/fake/bin/\(tool)") : nil }

    func signedIn(_ executable: URL, environment: [String: String]) -> Bool {
        lock.withLock { signInChecks += 1; return loggedIn }
    }

    func start(_ executable: URL, _ args: [String], stdin: Data, environment: [String: String], directory: URL,
               completion: @escaping @Sendable (Int32, String) -> Void) throws {
        lock.withLock {
            runs.append(Run(executable: executable, args: args, stdin: String(decoding: stdin, as: UTF8.self),
                            env: environment, dir: directory))
            completions.append(completion)
        }
    }

    func finish(_ status: Int32 = 0, _ output: String = "{}") {
        let c = lock.withLock { completions.isEmpty ? nil : completions.removeFirst() }
        c?(status, output)
    }

    var count: Int { lock.withLock { runs.count } }
}

@Suite struct ReplySenderTests {
    static func setup(_ runner: FakeReplyRunner = FakeReplyRunner(), extra: [Int32: ProcRecord] = [:])
        async throws -> (HiveAPI, Board, FakeReplyRunner, HivePaths) {
        var (paths, procs) = try BoardTests.liveHome()
        for (k, v) in extra { procs.table[k] = v }
        // Ended sessions in the fixture live in <home>/Projects/demo; make the folder exist.
        try FileManager.default.createDirectory(at: paths.home.appending(path: "Projects/demo"),
                                                withIntermediateDirectories: true)
        let sender = ReplySender(paths: paths, runner: runner,
                                 environment: ["PATH": "/usr/bin", "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "x"])
        let board = Board(paths: paths, processes: procs, now: { Fixture.nowDate })
        await board.setReplies(sender, capabilities: ["reply": true])
        await board.refresh()
        let api = HiveAPI(board: board, usage: UsageCounter(paths: paths), skills: SkillsReader(paths: paths),
                          jobs: SkillsJobs(paths: paths, runner: FakeRunner()), system: SystemReport(paths: paths),
                          classroom: ClassroomStore(paths: paths), actions: RecordingActions(), replies: sender)
        return (api, board, runner, paths)
    }

    static func reply(_ api: HiveAPI, _ id: String, _ text: String) async -> (Int, JSON?) {
        let body = JSON.object(JSONObject(["sessionId": .string(id), "text": .string(text)])).serializedString
        let r = await api.handle(method: "POST", path: "/api/reply", body: Data(body.utf8))
        return (r.status, try? JSON.parse(r.body))
    }

    @Test func signedOutCLIGetsNoReplyBoxAndNothingRuns() async throws {
        let runner = FakeReplyRunner()
        runner.loggedIn = false
        let (api, board, _, _) = try await Self.setup(runner)
        let payload = try JSON.parse(await board.payload())
        let rows = payload["sessions"]?.array ?? []
        // The fixture's not-running session with an existing folder would be offered a reply if signed in.
        #expect(!rows.contains { $0["canReply"] == true })
        let row = try #require(rows.first { $0["replyNote"]?.string == ReplySender.signedOutNote })
        let id = try #require(row["id"]?.string)
        let (status, body) = await Self.reply(api, id, "hello")
        #expect(status == 409)
        #expect(body?["error"]?.string == ReplySender.signedOutNote)
        #expect(runner.count == 0)
    }

    @Test func signInIsCheckedAgainRightBeforeSending() async throws {
        let runner = FakeReplyRunner()
        let (api, board, _, _) = try await Self.setup(runner)
        let payload = try JSON.parse(await board.payload())
        let id = try #require((payload["sessions"]?.array ?? []).first { $0["canReply"] == true }?["id"]?.string)
        let before = runner.signInChecks
        runner.loggedIn = false
        let (status, _) = await Self.reply(api, id, "hello")
        #expect(status == 409)
        #expect(runner.signInChecks == before + 1)
        #expect(runner.count == 0)
    }

    @Test func boardOffersRepliesOnlyForSessionsWithNoProcess() async throws {
        let (_, board, _, _) = try await Self.setup()
        let payload = try JSON.parse(await board.payload())
        #expect(payload["capabilities"]?["reply"] == true)
        let rows = payload["sessions"]?.array ?? []
        let live = try #require(rows.first { $0["id"] == "sess-main-0001" })
        #expect(live["canReply"] == false)
        #expect(live["replyNote"]?.string?.isEmpty == false)
        let ended = try #require(rows.first { $0["id"] == "sess-asked-0002" })
        #expect(ended["canReply"] == true)
        #expect(ended["replyNote"] == .null)
    }

    @Test func liveSessionIsRefusedAndNothingRuns() async throws {
        let (api, _, runner, _) = try await Self.setup()
        let (status, body) = await Self.reply(api, "sess-main-0001", "hello")
        #expect(status == 409)
        #expect(body?["error"]?.string?.isEmpty == false)
        #expect(runner.count == 0)
    }

    @Test func allowedSessionRunsTheS1CommandInItsFolder() async throws {
        let (api, _, runner, paths) = try await Self.setup()
        let (status, body) = await Self.reply(api, "sess-asked-0002", "--dangerously-skip-permissions please push")
        #expect(status == 202)
        #expect(body?["ok"] == true)
        let run = try #require(runner.runs.first)
        #expect(run.executable.lastPathComponent == "claude")
        #expect(run.args == ["--resume", "sess-asked-0002", "-p", "--output-format", "json"])
        #expect(run.stdin == "--dangerously-skip-permissions please push")
        #expect(run.dir.path == paths.home.appending(path: "Projects/demo").path)
        #expect(run.env.keys.allSatisfy { !$0.hasPrefix("CLAUDE") })
        #expect(!run.args.contains { $0.contains("dangerously") || $0.contains("permission") })
    }

    @Test func emptyTextIs400() async throws {
        let (api, _, runner, _) = try await Self.setup()
        #expect(await Self.reply(api, "sess-asked-0002", "  \n ").0 == 400)
        #expect(runner.count == 0)
    }

    @Test func unknownSessionIs404() async throws {
        let (api, _, runner, _) = try await Self.setup()
        #expect(await Self.reply(api, "not-on-board-0", "hi").0 == 404)
        #expect(runner.count == 0)
    }

    @Test func oneReplyAtATimePerSession() async throws {
        let (api, board, runner, _) = try await Self.setup()
        #expect(await Self.reply(api, "sess-asked-0002", "first").0 == 202)
        #expect(await Self.reply(api, "sess-asked-0002", "second").0 == 409)
        await board.refresh()
        let row = try JSON.parse(await board.payload())["sessions"]?.array?.first { $0["id"] == "sess-asked-0002" }
        #expect(row?["canReply"] == false)
        runner.finish()
        #expect(await Self.reply(api, "sess-asked-0002", "third").0 == 202)
        #expect(runner.count == 2)
    }

    @Test func anotherProcessResumingTheSessionBlocksReplies() async throws {
        let other = proc(4242, 1, "/Users/x/.local/bin/claude --resume sess-asked-0002 -p go")
        let (api, _, runner, _) = try await Self.setup(extra: [4242: other])
        #expect(await Self.reply(api, "sess-asked-0002", "hi").0 == 409)
        #expect(runner.count == 0)
    }

    @Test func noClaudeCommandBlocksReplies() async throws {
        let runner = FakeReplyRunner()
        runner.installed = false
        let (api, _, _, _) = try await Self.setup(runner)
        let (status, body) = await Self.reply(api, "sess-asked-0002", "hi")
        #expect(status == 409)
        #expect(body?["error"]?.string?.contains("claude") == true)
    }
}
