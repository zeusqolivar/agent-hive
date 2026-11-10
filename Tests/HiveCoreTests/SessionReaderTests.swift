import Foundation
import Testing
@testable import HiveCore

@Suite struct SessionReaderTests {
    func write(_ home: URL, _ name: String, _ json: String) throws {
        try Data(json.utf8).write(to: home.appending(path: ".claude/sessions/\(name)"))
    }

    @Test func findsLiveClaudeSessionsOnly() throws {
        let home = try Fixture.prepare()
        let me = getpid(), parent = getppid()
        try write(home, "\(me).json", #"{"pid": \#(me), "sessionId": "sess-live-0001", "status": "busy", "name": "Live"}"#)
        try write(home, "\(parent).json", #"{"pid": \#(parent), "sessionId": "sess-reused-0002", "status": "idle"}"#)
        try write(home, "\(me).feedface.key", #"{"pid": \#(me), "sessionId": "sess-from-key-0003"}"#)
        try write(home, "broken.json", "{not json")
        try write(home, "noid.json", #"{"pid": \#(me)}"#)
        let table: [Int32: ProcRecord] = [
            me: proc(me, parent, "/Users/x/.local/bin/claude --model opus"),
            parent: proc(parent, 1, "/usr/bin/python3 -m http.server"),
        ]
        let live = SessionReader.liveSessions(paths: Fixture.paths(home), processes: table)
        #expect(live.map(\.sessionId) == ["sess-live-0001"])
        #expect(live.first?.name == "Live")
        #expect(live.first?.status == "busy")
    }

    @Test func alivePidMissingFromTheProcessListStillCounts() throws {
        let home = try Fixture.prepare()
        let me = getpid()
        try write(home, "\(me).json", #"{"pid": \#(me), "sessionId": "sess-live-0001"}"#)
        let live = SessionReader.liveSessions(paths: Fixture.paths(home), processes: [:])
        #expect(live.map(\.sessionId) == ["sess-live-0001"])
    }

    @Test func missingClaudeFolderIsEmpty() {
        let paths = HivePaths(home: URL(filePath: "/nonexistent-home-\(UUID().uuidString)"), uid: 501)
        #expect(SessionReader.liveSessions(paths: paths, processes: [:]).isEmpty)
    }

    @Test func pidAlive() {
        #expect(SessionReader.pidAlive(getpid()))
        #expect(SessionReader.pidAlive(1))            // launchd: EPERM counts as alive
        #expect(!SessionReader.pidAlive(999_999))
        #expect(!SessionReader.pidAlive(0))
    }
}
