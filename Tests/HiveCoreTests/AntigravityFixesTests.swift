import Foundation
import SQLite3
import Testing
@testable import HiveCore

@Suite struct ReadonlyDatabaseTests {
    static func makeDB() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appending(path: "t.db").path
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "create table t(x); insert into t values (1);", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        return path
    }

    static func value(_ db: OpaquePointer) -> Int {
        (try? OpenClawReader.query(db, "select x from t"))?.first?["x"]?.int ?? -1
    }

    @Test func readsANormalDatabase() throws {
        let db = try ReadonlyDatabase.open(try Self.makeDB())
        defer { sqlite3_close(db) }
        #expect(Self.value(db) == 1)
    }

    @Test func fallsBackToImmutableWhenAReadOnlyOpenFails() throws {
        let path = try Self.makeDB()
        var names: [String] = []
        let db = try ReadonlyDatabase.open(path) { name, flags in
            names.append(name)
            return name.contains("immutable=1") ? ReadonlyDatabase.attempt(name, flags) : nil
        }
        defer { sqlite3_close(db) }
        #expect(Self.value(db) == 1)
        #expect(names.count == 2)
        #expect(names[1].hasPrefix("file:") && names[1].hasSuffix("?mode=ro&immutable=1"))
    }

    @Test func missingFileStillFails() {
        #expect(throws: OpenClawReader.DatabaseError.self) {
            try ReadonlyDatabase.open(FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID()).db").path)
        }
    }
}

@Suite struct AntigravityHubTests {
    static func home(_ hubs: [(name: String, pid: Int32, age: TimeInterval)]) throws -> HivePaths {
        let home = FileManager.default.temporaryDirectory.appending(path: "agy-\(UUID().uuidString)")
        let paths = HivePaths(home: home, uid: 501)
        let dir = paths.antigravity.appending(path: "daemon")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for hub in hubs {
            let file = dir.appending(path: hub.name)
            try Data("{\"pid\": \(hub.pid), \"httpPort\": \(1000 + hub.pid % 1000)}".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-hub.age)], ofItemAtPath: file.path)
        }
        return paths
    }

    static func proc(_ pid: Int32, _ cmd: String) -> ProcRecord {
        ProcRecord(pid: pid, ppid: 1, uptime: 1, rssMB: 1, cpu: 0, cmd: cmd)
    }

    static let app = "/Applications/Antigravity.app/Contents/Resources/bin/language_server --x"
    static let alive: @Sendable (Int32) -> Bool = { _ in true }

    @Test func staleHubWhosePidIsNowAnotherProgramIsSkipped() throws {
        let paths = try Self.home([("hub_1.json", 11, 10), ("hub_2.json", 22, 100)])
        let table: [Int32: ProcRecord] = [11: Self.proc(11, "python3 -m unittest"), 22: Self.proc(22, Self.app)]
        #expect(AntigravityReader.hub(paths: paths, pidAlive: Self.alive, table: table)?.pid == 22)
    }

    @Test func theCommandLineHubCountsButTheAppComesFirst() throws {
        let paths = try Self.home([("hub_1.json", 11, 10), ("hub_2.json", 22, 100)])
        var table: [Int32: ProcRecord] = [11: Self.proc(11, "/Users/someone/.gemini/bin/agy --hub --hub-port=56041"), 22: Self.proc(22, Self.app)]
        #expect(AntigravityReader.hub(paths: paths, pidAlive: Self.alive, table: table)?.pid == 22)
        table[22] = Self.proc(22, "zsh")
        #expect(AntigravityReader.hub(paths: paths, pidAlive: Self.alive, table: table)?.pid == 11)
    }

    @Test func noRunningAntigravityMeansNoHub() throws {
        let paths = try Self.home([("hub_1.json", 11, 10)])
        #expect(AntigravityReader.hub(paths: paths, pidAlive: Self.alive, table: [11: Self.proc(11, "python3")]) == nil)
    }

    @Test func beforeTheFirstProcessListTheNewestLiveHubWins() throws {
        let paths = try Self.home([("hub_1.json", 22, 100), ("hub_2.json", 11, 10), ("hub_3.json", 33, 1)])
        let alive: @Sendable (Int32) -> Bool = { $0 != 33 }
        #expect(AntigravityReader.hub(paths: paths, pidAlive: alive)?.pid == 11)
    }
}
