import Foundation
import Testing
@testable import HiveCore

/// Hermes Agent's sessions, from a fixture database with the same shape as the real `state.db`.
@Suite struct HermesTests {
    static let now = Date(timeIntervalSince1970: 1_794_320_000)

    static func paths() throws -> HivePaths {
        let root = try #require(Bundle.module.url(forResource: "Fixtures/hermes-home", withExtension: nil))
        var paths = HivePaths(home: root, uid: 501)
        paths.hermesDBs = [root.appending(path: "state.db", directoryHint: .notDirectory)]
        return paths
    }

    static func reader() throws -> HermesReader {
        HermesReader(paths: try paths(), now: { now })
    }

    @Test func sessionsBecomeBoardRows() throws {
        let rows = try Self.reader().sessions()
        #expect(rows.map(\.id) == ["hermes-busy-0001", "hermes-idle-0002", "hermes-ended-0003"])

        let busy = try #require(rows.first)
        #expect(busy.group == "working")
        #expect(busy.name == "Port the board to Windows")
        #expect(busy.headline == "receiving stream response")
        #expect(busy.model == "deepseek-flash")
        #expect(busy.provider == "hermes")
        #expect(busy.entry == "hermes")
        #expect(busy.branch == "windows-port")
        #expect(busy.project == "agent-hive")
        #expect(busy.cwd == #"C:\Users\me\projects\agent-hive"#)
        #expect(busy.live == false)          // the reader doesn't claim to know Hermes's processes
        #expect(busy.hostId == nil)
        #expect(busy.doing != nil)           // a working row says what it is doing
    }

    @Test func aQuietSessionIsIdleAndUsesItsLastAnswer() throws {
        let rows = try Self.reader().sessions()
        let idle = try #require(rows.first { $0.id == "hermes-idle-0002" })
        #expect(idle.group == "idle")
        #expect(idle.name == "Weekly review")          // the title, not the display name
        #expect(idle.headline == "The week is planned: three posts and one review.")
        #expect(idle.doing == nil)
        #expect(idle.project == "Hermes")              // no folder recorded
    }

    @Test func anEndedSessionSaysSo() throws {
        let rows = try Self.reader().sessions()
        let ended = try #require(rows.first { $0.id == "hermes-ended-0003" })
        #expect(ended.group == "ended")
        #expect(ended.doing == nil)
        #expect(ended.headline == "Subagent: check the fixtures")   // nothing said, so the title
    }

    @Test func hiddenSessionsAreLeftOut() throws {
        let ids = try Self.reader().sessions().map(\.id)
        #expect(!ids.contains("hermes-hidden-0004"))
    }

    @Test func noDatabaseMeansNoRows() {
        var paths = HivePaths(home: URL(filePath: "/nowhere"), uid: 501)
        paths.hermesDBs = [URL(filePath: "/nowhere/state.db")]
        let reader = HermesReader(paths: paths, now: { Self.now })
        #expect(reader.sessions().isEmpty)
        #expect(!reader.isInstalled)
    }

    @Test func theBoardShowsHermesSessionsBesideClaudes() async throws {
        // The board builds its own reader from the paths it is given, so the fixture home is enough.
        let board = Board(paths: try Self.paths(), processes: FixedProcesses(table: [:]), now: { Self.now })
        await board.refresh()
        let rows = await board.snapshot().rows
        #expect(rows.contains { $0.provider == "hermes" })
        #expect(rows.filter { $0.provider == "hermes" }.map(\.id).sorted()
            == ["hermes-busy-0001", "hermes-ended-0003", "hermes-idle-0002"])
    }
}
