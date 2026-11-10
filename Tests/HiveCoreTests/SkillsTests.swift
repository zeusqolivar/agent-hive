import Foundation
import Testing
@testable import HiveCore

@Suite struct SkillsTests {
    @Test func reportMatchesServer() throws {
        let expected = try Fixture.expected("skills.json")
        let report = SkillsReader(paths: Fixture.paths()).report()
        let diff = contractDiff(report, expected)
        #expect(diff.isEmpty, "\(diff.prefix(12).joined(separator: "\n"))")
    }

    @Test func frontMatter() throws {
        let root = Fixture.shared.appending(path: ".claude/skills")
        let demo = try #require(SkillsReader.skillInfo(root.appending(path: "demo-skill")))
        #expect(demo["name"] == "demo-skill")
        #expect(demo["description"] == "Says hello to the user.")
        #expect(demo["version"] == "1.4.2")
        let plain = try #require(SkillsReader.skillInfo(root.appending(path: "no-front-matter")))
        #expect(plain["description"] == "")
        #expect(plain["version"] == .null)
        #expect(SkillsReader.skillInfo(root.appending(path: "not-a-skill")) == nil)
    }

    @Test func versionCompare() {
        #expect(SkillsReader.versionTuple("1.9.9").lexicographicallyPrecedes(SkillsReader.versionTuple("1.10.0")))
        #expect(SkillsReader.versionTuple("v2") == [2])
    }

    @Test func openclawMatchesServer() throws {
        let expected = try Fixture.expected("openclaw.json")
        let summary = try OpenClawReader(paths: Fixture.paths(), now: { Fixture.nowDate }).summary()
        let diff = contractDiff(summary, expected)
        #expect(diff.isEmpty, "\(diff.prefix(12).joined(separator: "\n"))")
    }

    @Test func noOpenClawDatabase() throws {
        let paths = HivePaths(home: URL(filePath: "/nonexistent-\(UUID().uuidString)"), uid: 501)
        #expect(try OpenClawReader(paths: paths, now: { Fixture.nowDate }).summary() == .null)
    }

    @Test func systemListsOtherAgentApps() {
        let me = getpid()
        let table: [Int32: ProcRecord] = [
            10: proc(10, 1, "/Applications/Claude.app/Contents/MacOS/Claude"),
            11: proc(11, 10, "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/x"),
            12: proc(12, 10, "/Users/x/Library/Application Support/Claude/claude-code/2.1/claude.app/Contents/MacOS/claude --resume a"),
            13: proc(13, 1, "node /opt/homebrew/lib/node_modules/openclaw/dist/index.js gateway"),
            14: proc(14, 1, "/usr/bin/codex --full-auto"),
            15: proc(15, 1, "/bin/ls"),
            me: proc(me, 1, "/Users/x/.local/bin/claude"),
        ]
        var state = BoardState()
        state.processes = table
        state.rows = []
        let apps = SystemReport.apps(state: state, naming: Naming(home: "/Users/x"), skipping: [12])
        #expect(apps.compactMap { $0["name"]?.string } == ["Claude desktop app", "Codex", "OpenClaw gateway"])
    }
}
