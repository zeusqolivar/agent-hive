import Foundation
import Testing
@testable import HiveCore

@Suite struct LiveFeedTests {
    static func feed(_ home: URL = Fixture.shared) -> LiveFeed {
        LiveFeed(paths: Fixture.paths(home), now: { Fixture.nowDate })
    }

    @Test func mainMatchesServer() throws {
        let expected = try Fixture.expected("live-main.json")
        let items = Self.feed().items(transcript: try SubagentContractTests.transcript("main"), sub: nil)
        let diff = contractDiff(items.json, expected["items"])
        #expect(diff.isEmpty, "\(diff.joined(separator: "\n"))")
    }

    @Test func subagentMatchesServer() throws {
        let expected = try Fixture.expected("live-agent.json")
        let items = Self.feed().items(transcript: try SubagentContractTests.transcript("agent-running"),
                                      sub: "Find the parser callers")
        let diff = contractDiff(items.json, expected["items"])
        #expect(diff.isEmpty, "\(diff.joined(separator: "\n"))")
    }

    @Test func thinkingCommandsAndPendingCalls() throws {
        let items = Self.feed().items(transcript: try SubagentContractTests.transcript("main"), sub: nil)
        #expect(items.contains { $0.k == "think" && $0.hidden == true && $0.text.isEmpty })
        #expect(items.contains { $0.k == "think" && $0.hidden == false && !$0.text.isEmpty })
        let tests = try #require(items.first { $0.k == "cmd" && $0.text.hasPrefix("swift test") })
        #expect(tests.out?.hasPrefix("error: 2 tests failed") == true)
        #expect(tests.err == true)
        #expect(tests.open == nil)
        let build = try #require(items.first { $0.k == "cmd" && $0.text.hasPrefix("swift build") })
        #expect(build.open == true)
        #expect(build.out == nil)
    }

    @Test func clipKeepsTheEnd() {
        let long = String(repeating: "a", count: 5000) + "END"
        let clipped = LiveFeed.clipOutput(.string(long))
        #expect(clipped.hasPrefix("[1,003 earlier characters not shown]\n"))
        #expect(clipped.hasSuffix("END"))
    }

    @Test func backgroundTasks() throws {
        let home = try Fixture.prepare()
        let paths = Fixture.paths(home)
        let fm = FileManager.default
        let dir = paths.tasksRoot.appending(path: "some-project/sess-main-0001/tasks")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let fresh = dir.appending(path: "bg1.output")
        try Data("\u{1b}[32mok\u{1b}[0m line\n".utf8).write(to: fresh)
        let old = dir.appending(path: "bg2.output")
        try Data("old".utf8).write(to: old)
        try Data().write(to: dir.appending(path: "bg3.output"))
        let stamp = Fixture.nowDate.addingTimeInterval(-30)
        try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: fresh.path)
        try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: dir.appending(path: "bg3.output").path)
        try fm.setAttributes([.modificationDate: Fixture.nowDate.addingTimeInterval(-16 * 60)], ofItemAtPath: old.path)
        let tasks = LiveFeed(paths: paths, now: { Fixture.nowDate }).backgroundTasks(sessionId: "sess-main-0001")
        #expect(tasks.map(\.id) == ["bg1"])
        #expect(tasks.first?.tail == "ok line\n")
        #expect(tasks.first?.mtime == Fixture.now - 30)
    }
}
