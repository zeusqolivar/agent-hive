import Foundation
import Testing
@testable import HiveCore

@Suite struct DescriberContractTests {
    static let names = (try? Fixture.expectedNames(prefix: "describe-")) ?? []

    /// The transcript file each fixture name stands for, from the transcript expectations.
    static func transcriptFile(_ name: String) throws -> URL {
        let expected = try Fixture.expected("transcript-\(name).json")
        return URL(filePath: try #require(expected["file"]?.string))
    }

    @Test(arguments: names)
    func matchesServer(_ name: String) throws {
        let expected = try Fixture.expected(name)
        let input = try #require(expected["input"]?.object)
        let raw = SessionFile(json: try #require(input["raw"]?.object))
        var tail: TranscriptTail?
        if let t = input["transcript"]?.string {
            tail = TranscriptReader(paths: Fixture.paths()).read(try Self.transcriptFile(t))
            #expect(tail != nil)
        }
        let subs = input["subsRunning"]?.int ?? 0
        let commands = (input["commands"]?.array ?? []).compactMap { $0.object }.map(SessionCommand.init(json:))
        let got = Describer.describe(raw: raw, tail: tail, subsRunning: subs, commands: commands)
        #expect(got.group == expected["group"]?.string, "\(name)")
        #expect(got.reason == expected["reason"]?.string, "\(name)")
        #expect(got.headline == expected["headline"]?.string, "\(name)")
        let doing = Describer.doing(group: got.group, tail: tail, subsRunning: subs, commands: commands)
        #expect(doing == expected["doing"]?.string, "\(name)")
        let questions = OpenQuestions.of(tail).map(JSON.string)
        #expect(JSON.array(questions) == (expected["questions"] ?? []), "\(name)")
    }

    @Test func allFixturesFound() { #expect(Self.names.count >= 15) }

    @Test func friendlyCommandDropsTheShell() {
        #expect(Describer.friendlyCommand("/bin/zsh -c -l /private/tmp/perf/waitpid.sh 30514") == "waitpid.sh 30514")
        #expect(Describer.friendlyCommand("/usr/bin/swift build") == "swift build")
    }
}
