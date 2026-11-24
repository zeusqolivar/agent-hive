import Foundation
import Testing
@testable import HiveCore

/// Codex threads from the made-up rollouts in `Fixtures/codex-home` (written by hand for these tests, not by
/// scripts/make_contract_fixtures.py, so the contract home stays free of Codex sessions).
@Suite struct CodexReaderTests {
    static func id(_ n: Int) -> String { "019a0000-0000-7000-8000-00000000c00\(n)" }

    /// How long before `Fixture.now` each rollout last changed.
    static let ages: [Int: TimeInterval] = [1: 60, 2: 1800, 3: 20, 4: 1700, 5: 800, 6: 30 * 3600, 7: 72 * 3600, 8: 300]

    static let appServer = ProcRecord(pid: 4242, ppid: 1, uptime: 3600, rssMB: 120, cpu: 1.5,
        cmd: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex app-server --listen stdio://")
    static let helpers = [
        ProcRecord(pid: 4243, ppid: 1, uptime: 3600, rssMB: 80, cpu: 0,
                   cmd: "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Helpers/Codex (Aperitif).app/Contents/MacOS/Codex (Aperitif) --type=gpu-process"),
        ProcRecord(pid: 4244, ppid: 4242, uptime: 3500, rssMB: 10, cpu: 0,
                   cmd: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex-code-mode-host --listen grpc+stdio://"),
    ]
    static var table: [Int32: ProcRecord] {
        Dictionary(uniqueKeysWithValues: ([appServer] + helpers).map { ($0.pid, $0) })
    }

    /// A private copy of the Codex home with each rollout's mtime set from `ages`.
    static func home(ages: [Int: TimeInterval] = ages) throws -> URL {
        let home = try Fixture.prepare("codex-home")
        let root = home.appending(path: ".codex/sessions", directoryHint: .isDirectory)
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let url as URL in e where url.pathExtension == "jsonl" {
            guard let n = ages.keys.first(where: { url.lastPathComponent.hasSuffix(id($0) + ".jsonl") }) else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(Fixture.now) - ages[n]!)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        return home
    }

    static func board(_ home: URL, table: [Int32: ProcRecord] = table) -> Board {
        Board(paths: Fixture.paths(home), processes: FixedProcesses(table: table), now: { Fixture.nowDate })
    }

    static func rows(_ board: Board) async throws -> [String: JSON] {
        await board.refresh()
        let payload = try JSON.parse(await board.payload())
        let sessions = try #require(payload["sessions"]?.array)
        var out: [String: JSON] = [:]
        for row in sessions where row["provider"] == "openai" { out[row["id"]!.string!] = row }
        return out
    }

    @Test func groupsAndHeadlines() async throws {
        let home = try Self.home()
        let rows = try await Self.rows(Self.board(home))
        #expect(Set(rows.keys) == Set((1...6).map(Self.id)), "older than 48 hours and subagent threads aren't listed")

        let working = try #require(rows[Self.id(1)])
        #expect(working["group"] == "working")
        #expect(working["headline"] == "Running xcodebuild -scheme Demo build")
        #expect(working["doing"] == "run")
        #expect(working["name"] == "Demo build")
        #expect(working["project"] == "demo-app")
        #expect(working["branch"] == "feature/login")
        #expect(working["cwd"]?.string == home.path + "/Projects/demo-app")
        #expect(working["model"] == "gpt-test-1")
        #expect(working["effort"] == "high")
        #expect(working["plan"] == ["done": 1, "total": 3, "current": "Fix the warnings"])
        #expect(working["statusSince"]?.int == Fixture.now - 3600 + 2, "since the turn started")
        #expect(working["pid"]?.int == 4242)
        #expect(working["uptime"]?.int == 3600)
        #expect(working["version"] == "0.99.0-test")
        #expect(working["entry"] == "codex")
        #expect(working["hostId"] == .null)
        #expect(working["live"] == true)

        let idle = try #require(rows[Self.id(2)])
        #expect(idle["group"] == "idle", "the escalated command got its output, so nothing is waiting")
        #expect(idle["headline"] == "Added the settings screen.")
        #expect(idle["name"] == "Settings screen", "the later index line wins")
        #expect(idle["statusSince"]?.int == Fixture.now - 7200 + 11, "since the turn completed")

        let permission = try #require(rows[Self.id(3)])
        #expect(permission["group"] == "needs")
        #expect(permission["reason"] == "permission")
        #expect(permission["headline"] == "Needs your OK to run git push origin release")
        #expect(permission["statusSince"]?.int == Fixture.now - 600 + 4)

        let questions = try #require(rows[Self.id(4)])
        #expect(questions["group"] == "needs")
        #expect(questions["reason"] == "questions")
        #expect(questions["headline"] == "1 open question: Should I also update the docs?")
        #expect(questions["questions"] == ["Should I also update the docs?"])
        #expect(questions["name"] == "helper-kit", "no index entry, so the folder's name")

        let asked = try #require(rows[Self.id(5)])
        #expect(asked["group"] == "needs")
        #expect(asked["reason"] == "question")
        #expect(asked["headline"] == "Asked: Which accent color should the theme use?")
        #expect(asked["questions"] == ["Which accent color should the theme use?"])

        let ended = try #require(rows[Self.id(6)])
        #expect(ended["group"] == "ended")
        #expect(ended["live"] == false)
        #expect(ended["pid"] == .null)
        #expect(ended["headline"] == "Tidied the readme. Nothing else changed.", "too short to cut at the first sentence")

        for row in rows.values {
            #expect(row["canReply"] == false)
            #expect(row["webUrl"] == .null)
        }
    }

    @Test func orderAndCounts() async throws {
        let board = Self.board(try Self.home())
        await board.refresh()
        let payload = try JSON.parse(await board.payload())
        #expect(payload["counts"] == ["needs": 3, "working": 1, "idle": 1, "ended": 1])
        let ids = payload["sessions"]?.array?.compactMap { $0["id"]?.string } ?? []
        #expect(ids == [3, 5, 4, 1, 2, 6].map(Self.id), "permission first, then question, then questions")
    }

    @Test func withoutCodexRunningEverythingEnded() async throws {
        let rows = try await Self.rows(Self.board(try Self.home(), table: [:]))
        #expect(rows.count == 6)
        #expect(rows.values.allSatisfy { $0["group"] == "ended" && $0["pid"] == .null && $0["live"] == false })
    }

    /// A turn that started but whose rollout stopped changing 10 minutes ago isn't working any more.
    @Test func staleTurnIsIdle() async throws {
        var ages = Self.ages
        ages[1] = 20 * 60
        let rows = try await Self.rows(Self.board(try Self.home(ages: ages)))
        let row = try #require(rows[Self.id(1)])
        #expect(row["group"] == "idle")
        #expect(row["doing"] == .null)
        #expect(row["headline"] == "Build the demo app and fix any warnings.")
    }

    /// With the approval policy `never`, Codex doesn't ask, so an escalated call isn't waiting on you.
    @Test func neverPolicyMeansNoPermission() throws {
        let lines = [
            #"{"timestamp":"2026-11-10T11:00:00Z","type":"turn_context","payload":{"approval_policy":"never","model":"m"}}"#,
            #"{"timestamp":"2026-11-10T11:00:01Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t"}}"#,
            #"{"timestamp":"2026-11-10T11:00:02Z","type":"response_item","payload":{"type":"function_call","call_id":"c","name":"exec_command","arguments":"{\"cmd\":\"ls\",\"sandbox_permissions\":\"require_escalated\"}"}}"#,
        ].map { ArraySlice(Array($0.utf8)) }
        let tail = CodexTranscript.scan(lines, naming: Naming(home: "/h"))
        #expect(tail.codex?.running == true)
        #expect(tail.codex?.approval == nil)
        #expect(tail.pending.map(\.title) == ["Run ls"])
    }

    @Test func transcriptTail() throws {
        let home = try Self.home()
        let paths = Fixture.paths(home)
        let url = try #require(CodexReader(paths: paths, transcripts: TranscriptReader(paths: paths),
                                           locator: TranscriptLocator(paths: paths), now: { Fixture.nowDate })
            .recentRollouts().first { $0.url.lastPathComponent.hasSuffix(Self.id(1) + ".jsonl") }?.url)
        #expect(paths.isCodex(url))
        let tail = try #require(TranscriptReader(paths: paths).read(url))
        // The malformed line is skipped; the call after it still counts.
        #expect(tail.pending.map(\.title) == ["Run xcodebuild -scheme Demo build"])
        #expect(tail.events.filter { $0.k == "you" }.map(\.title) == ["Build the demo app and fix any warnings."],
                "your message is recorded twice and the environment context isn't yours")
        #expect(tail.events.filter { $0.k == "tool" }.map(\.title) == ["Run swift build", "Run xcodebuild -scheme Demo build"])
        #expect(tail.events.first { $0.title == "Run swift build" }?.out == "Build complete")
        #expect(tail.plan.map(\.state) == ["completed", "in_progress", "pending"])
        #expect(tail.contextTokens == 4200)
        #expect(tail.codex?.running == true)
        #expect(tail.codex?.approvalPolicy == "never")
    }

    @Test func detailActivityAndLive() async throws {
        let board = Self.board(try Self.home())
        await board.refresh()
        let detail = try JSON.parse(try #require(await board.sessionDetail(Self.id(1), tokens: { _ in .null })))
        #expect(detail["provider"] == "openai")
        #expect(detail["resumeCommand"] == .null)
        #expect(detail["planItems"]?.array?.count == 3)
        #expect(detail["prompt"] == "Build the demo app and fix any warnings.")
        #expect(detail["events"]?.array?.first?["title"] == "Run xcodebuild -scheme Demo build", "newest first")

        let activity = try JSON.parse(await board.activity())
        let names = Set(activity["items"]?.array?.compactMap { $0["sid"]?.string } ?? [])
        #expect(names.isSuperset(of: [Self.id(1), Self.id(2)]))

        let live = try JSON.parse(try #require(await board.live(Self.id(1))))
        let items = live["items"]?.array ?? []
        #expect(items.contains { $0["k"] == "cmd" && $0["text"] == "xcodebuild -scheme Demo build" && $0["open"] == true })
        #expect(items.contains { $0["k"] == "cmd" && $0["text"] == "swift build" && $0["out"] == "Build complete" })
        #expect(items.contains { $0["k"] == "you" })
        #expect(!items.contains { $0["text"]?.string?.hasPrefix("<environment_context") == true })
    }

    @Test func noReplies() async throws {
        let runner = FakeReplyRunner()
        let board = Self.board(try Self.home())
        let sender = ReplySender(paths: Fixture.paths(), runner: runner)
        await board.setReplies(sender, capabilities: ["reply": true])
        await board.refresh()
        let state = await board.snapshot()
        let rows = state.rows.filter { $0.provider == "openai" }
        #expect(rows.count == 6)
        #expect(rows.allSatisfy { !$0.canReply && $0.replyNote == nil })
        let r = await sender.reply(sessionId: Self.id(6), text: "hello", state: state)
        #expect(r.status == 409)
        #expect(runner.count == 0)
    }

    @Test func openIsRefused() async throws {
        let board = Self.board(try Self.home())
        await board.refresh()
        let actions = RecordingActions()
        let (status, _) = await HiveAPITests.post(AntigravityActionTests.api(board, actions: actions), "/api/action",
                                                  #"{"sessionId": "\#(Self.id(1))", "action": "open"}"#)
        #expect(status == 409)
        #expect(actions.opened.isEmpty && actions.antigravity.isEmpty)
    }

    @Test func processAndNames() {
        #expect(CodexReader.codexProcess(Self.table)?.pid == 4242)
        #expect(CodexReader.codexProcess(Dictionary(uniqueKeysWithValues: Self.helpers.map { ($0.pid, $0) })) == nil)
        let cli = ProcRecord(pid: 7, ppid: 1, uptime: 10, rssMB: 1, cpu: 0, cmd: "node /opt/homebrew/bin/codex resume")
        #expect(CodexReader.codexProcess([7: cli])?.pid == 7)
        let url = URL(filePath: "/h/.codex/sessions/2026/11/10/rollout-2026-11-10T11-00-00-\(Self.id(1)).jsonl")
        #expect(CodexReader.idFromName(url) == Self.id(1))
        #expect(CodexReader.ongoing("Run swift test") == "Running swift test")
        #expect(CodexReader.ongoing("Wait for a running command") == "Waiting for a running command")
    }

    @Test func codeModeCommands() {
        let code = #"const a = await tools.exec_command({cmd: "git status", yield_time_ms: 100}); await tools.exec_command({ "cmd": `ls -la` });"#
        #expect(CodexTranscript.commands(inCode: code) == ["git status", "ls -la"])
        let (verb, title, _) = CodexTranscript.label(name: "exec", namespace: nil, args: JSONObject(),
                                                     input: "text(await tools.view_image({path: 'a.png'}))", naming: Naming(home: "/h"))
        #expect(verb == "read" && title == "View an image")
        let patch = CodexTranscript.label(name: "apply_patch", namespace: nil, args: JSONObject(),
                                          input: "*** Begin Patch\n*** Update File: /h/x/a.swift\n@@\n-a\n+b\n*** End Patch",
                                          naming: Naming(home: "/h"))
        #expect(patch.0 == "edit" && patch.1 == "Edit ~/x/a.swift")
    }
}
