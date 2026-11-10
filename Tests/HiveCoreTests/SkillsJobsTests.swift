import Foundation
import Testing
@testable import HiveCore

/// Records what a skills job would run; `hold` keeps a run going until released.
final class FakeRunner: JobRunner, @unchecked Sendable {
    let lock = NSLock()
    private(set) var runs: [(tool: String, args: [String], env: [String: String])] = []
    let hold = DispatchSemaphore(value: 0)
    var holding = false

    func find(_ tool: String) -> URL? { URL(filePath: "/fake/bin/\(tool)") }

    func run(_ executable: URL, _ args: [String], environment: [String: String], directory: URL,
             timeout: TimeInterval, line: (String) -> Void) -> Int32 {
        lock.lock()
        runs.append((executable.lastPathComponent, args, environment))
        let wait = holding
        lock.unlock()
        line("working on it")
        if wait { hold.wait() }
        return 0
    }

    var argv: [[String]] { lock.lock(); defer { lock.unlock() }; return runs.map { [$0.tool] + $0.args } }
}

@Suite struct SkillsJobsTests {
    static func jobs(_ runner: FakeRunner) -> SkillsJobs {
        SkillsJobs(paths: Fixture.paths(), runner: runner,
                   environment: ["PATH": "/usr/bin", "CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "x", "HOME": "/h"])
    }

    func waitUntilIdle(_ jobs: SkillsJobs) async {
        for _ in 0..<200 where jobs.status()["running"] == true { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func rejectsAPluginThatIsNotInstalled() async {
        let runner = FakeRunner()
        let jobs = Self.jobs(runner)
        let (status, body) = jobs.start(action: "update", plugin: "x; rm -rf /")
        #expect(status == 400)
        #expect((try? JSON.parse(body))?["error"] == "Unknown update request.")
        await waitUntilIdle(jobs)
        #expect(runner.argv.isEmpty)
    }

    @Test func unknownAction() {
        let (status, _) = Self.jobs(FakeRunner()).start(action: "rm", plugin: nil)
        #expect(status == 400)
    }

    @Test func oneJobAtATime() async throws {
        let runner = FakeRunner()
        runner.holding = true
        let jobs = Self.jobs(runner)
        #expect(jobs.start(action: "check", plugin: nil).status == 200)
        let (status, body) = jobs.start(action: "check", plugin: nil)
        #expect(status == 409)
        #expect((try? JSON.parse(body))?["error"] == "An update is already running.")
        runner.hold.signal()
        await waitUntilIdle(jobs)
        #expect(runner.argv == [["claude", "plugin", "marketplace", "update"]])
        #expect(jobs.status()["ok"] == true)
    }

    @Test func updateAllRunsTheFixedCommands() async {
        let runner = FakeRunner()
        let jobs = Self.jobs(runner)
        #expect(jobs.start(action: "update-all", plugin: nil).status == 200)
        await waitUntilIdle(jobs)
        #expect(runner.argv == [
            ["claude", "plugin", "marketplace", "update"],
            ["claude", "plugin", "update", "empty@market"],
            ["claude", "plugin", "update", "solo@market"],
            ["claude", "plugin", "update", "toolkit@market"],
            ["openclaw", "skills", "update", "--all"],
        ])
        let env = runner.runs.first?.env ?? [:]
        #expect(env.keys.allSatisfy { !$0.hasPrefix("CLAUDE") })
        #expect(env["PATH"]?.hasSuffix("/usr/bin") == true)
        let log = jobs.status()["log"]?.array?.compactMap { $0.string } ?? []
        #expect(log.first == "$ claude plugin marketplace update")
        #expect(log.contains("working on it"))
        #expect(log.contains("Done."))
    }

    @Test func updateOnePlugin() async {
        let runner = FakeRunner()
        let jobs = Self.jobs(runner)
        let (status, body) = jobs.start(action: "update", plugin: "toolkit@market")
        #expect(status == 200)
        #expect((try? JSON.parse(body))?["message"] == "Updating toolkit.")
        await waitUntilIdle(jobs)
        #expect(runner.argv == [["claude", "plugin", "marketplace", "update"], ["claude", "plugin", "update", "toolkit@market"]])
    }
}
