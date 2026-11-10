import Foundation
import Testing
@testable import HiveCore

@Suite struct TranscriptContractTests {
    static let names = (try? Fixture.expectedNames(prefix: "transcript-")) ?? []

    @Test(arguments: names)
    func matchesServer(_ name: String) throws {
        let expected = try Fixture.expected(name)
        let file = try #require(expected["file"]?.string)
        let reader = TranscriptReader(paths: Fixture.paths())
        let tail = try #require(reader.read(URL(filePath: file)))
        let diff = contractDiff(tail.json, expected["tail"], ignoring: ["size", "mtime"])
        #expect(diff.isEmpty, "\(name): \(diff.prefix(12).joined(separator: "\n"))")
    }

    @Test func allFixturesFound() {
        #expect(Self.names.count >= 10)
    }

    @Test func cutOffLastLineIsSkipped() throws {
        let tail = try #require(TranscriptReader(paths: Fixture.paths()).read(
            Fixture.shared.appending(path: ".claude/projects/-fixture-Projects-demo/sess-main-0001.jsonl")))
        #expect(tail.lastText == "The tests fail because the input is never stored.")
        #expect(tail.pending.map(\.tool) == ["Agent", "Bash"])
    }

    @Test func missingFileIsNil() {
        #expect(TranscriptReader(paths: Fixture.paths()).read(URL(filePath: "/nonexistent/x.jsonl")) == nil)
    }

    @Test func cachedUntilTheFileChanges() throws {
        let home = try Fixture.prepare()
        let url = home.appending(path: ".claude/projects/-fixture-Projects-demo/sess-asked-0002.jsonl")
        let reader = TranscriptReader(paths: Fixture.paths(home))
        let first = try #require(reader.read(url))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"type":"user","timestamp":"2026-11-10T11:59:00.000Z","message":{"content":"One more thing"}}"#.utf8 + [10]))
        try handle.close()
        let second = try #require(reader.read(url))
        #expect(first.prompt == "Make the release build work.")
        #expect(second.prompt == "One more thing")
    }
}

@Suite struct TranscriptCacheTests {
    @Test func cacheStaysBounded() throws {
        let home = try Fixture.prepare()
        let dir = home.appending(path: ".claude/projects/-many")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = #"{"type":"user","timestamp":"2026-11-10T11:00:00.000Z","message":{"content":"hi"}}"# + "\n"
        let reader = TranscriptReader(paths: Fixture.paths(home))
        for n in 0..<(TranscriptReader.cacheLimit + 50) {
            let url = dir.appending(path: "s\(n).jsonl")
            try Data(line.utf8).write(to: url)
            _ = reader.read(url)
        }
        #expect(reader.cachedCount <= TranscriptReader.cacheLimit)
    }
}
