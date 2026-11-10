import Foundation
import Testing
@testable import HiveCore

@Suite struct SubagentContractTests {
    static func reader(_ home: URL = Fixture.shared) -> SubagentReader {
        SubagentReader(transcripts: TranscriptReader(paths: Fixture.paths(home)), now: { Fixture.nowDate })
    }

    static func transcript(_ name: String) throws -> URL {
        URL(filePath: try #require(Fixture.expected("transcript-\(name).json")["file"]?.string))
    }

    @Test func listMatchesServer() throws {
        let expected = try Fixture.expected("subagents-main.json")
        let agents = Self.reader().list(transcript: try Self.transcript("main"))
        let diff = contractDiff(agents.json, expected["list"], ignoring: ["startedAt"])
        #expect(diff.isEmpty, "\(diff.joined(separator: "\n"))")
        #expect(agents.map(\.state).sorted() == ["done", "running"])
    }

    @Test func helpersMatchServer() throws {
        let expected = try Fixture.expected("subagents-main.json")
        let reader = Self.reader()
        let helpers = reader.helpers(reader.list(transcript: try Self.transcript("main")))
        let diff = contractDiff(helpers.json, expected["helpers"])
        #expect(diff.isEmpty, "\(diff.joined(separator: "\n"))")
    }

    @Test func viewsMatchServer() throws {
        let expected = try Fixture.expected("subagents-main.json")
        let reader = Self.reader()
        let views = reader.list(transcript: try Self.transcript("main")).map { reader.view($0, withLast: true) }
        let diff = contractDiff(.array(views), expected["views"], ignoring: ["startedAt"])
        #expect(diff.isEmpty, "\(diff.joined(separator: "\n"))")
    }

    @Test func noSubagentFolderIsEmpty() throws {
        #expect(Self.reader().list(transcript: try Self.transcript("asked")).isEmpty)
    }

    @Test func quietLogCountsAsStalled() throws {
        let reader = SubagentReader(transcripts: TranscriptReader(paths: Fixture.paths()),
                                    now: { Fixture.nowDate.addingTimeInterval(31 * 60) })
        let agents = reader.list(transcript: try Self.transcript("main"))
        #expect(agents.map(\.state).sorted() == ["done", "stalled"])
        #expect(reader.helpers(agents).isEmpty)
    }

    @Test func briefIsTheFirstMessage() throws {
        let agents = Self.reader().list(transcript: try Self.transcript("main"))
        let running = try #require(agents.first { $0.state == "running" })
        #expect(SubagentReader.brief(URL(filePath: running.path)) == "List every caller of Parser.")
    }
}
