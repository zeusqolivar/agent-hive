import Foundation
import Testing
@testable import HiveCore

@Suite struct UsageContractTests {
    static let utc = TimeZone(identifier: "UTC")!

    static func counter(_ home: URL = Fixture.shared) -> UsageCounter {
        UsageCounter(paths: Fixture.paths(home), now: { Fixture.nowDate }, timeZone: utc)
    }

    /// The contract script lists Antigravity's conversations before the scan, so their tokens go under their
    /// projects; the report names sessions from their transcripts, as with no board.
    @Test func matchesServer() async throws {
        let expected = try Fixture.expected("usage.json")
        let listed = try AntigravityContractTests.board()
        await listed.refresh()
        let counter = UsageCounter(paths: Fixture.paths(), now: { Fixture.nowDate }, timeZone: Self.utc,
                                   antigravityProject: { listed.antigravityProject($0) })
        counter.scan()
        let board = Board(paths: Fixture.paths(), processes: FixedProcesses(table: [:]), now: { Fixture.nowDate })
        var report = try JSON.parse(await counter.report(title: { await board.title($0) }))
        guard case .object(var o) = report else { Issue.record("not an object"); return }
        var per = JSONObject()
        for sid in ["sess-main-0001", "sess-usage-0005", "sess-missing-0000", "agy-run-0001", "agy-ancient-0006"] {
            per[sid] = counter.forSession(sid)
        }
        o["perSession"] = .object(per)
        report = .object(o)
        let diff = contractDiff(report, expected)
        #expect(diff.isEmpty, "\(diff.prefix(12).joined(separator: "\n"))")
    }

    @Test func secondScanReadsOnlyNewLines() throws {
        let home = try Fixture.prepare()
        let counter = Self.counter(home)
        counter.scan()
        let before = counter.forSession("sess-usage-0005")
        let url = home.appending(path: ".claude/projects/-fixture-Projects-other/sess-usage-0005.jsonl")
        let line = #"{"type":"assistant","timestamp":"2026-11-10T11:50:00.000Z","cwd":"/x/Projects/other","message":{"id":"msg_new","model":"claude-haiku-5","usage":{"output_tokens":5,"input_tokens":1}}}"#
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        try handle.close()
        counter.scan()
        let after = counter.forSession("sess-usage-0005")
        #expect(after["responses"]?.int == (before["responses"]?.int ?? 0) + 1)
        #expect(after["output"]?.int == (before["output"]?.int ?? 0) + 5)
    }

    @Test func missingProjectsFolder() async throws {
        let paths = HivePaths(home: URL(filePath: "/nonexistent-\(UUID().uuidString)"), uid: 501)
        let counter = UsageCounter(paths: paths, now: { Fixture.nowDate }, timeZone: Self.utc)
        counter.scan()
        let report = try JSON.parse(await counter.report(title: { $0 }))
        #expect(report["ready"] == true)
        #expect(report["days"]?.array?.count == 7)
    }
}
