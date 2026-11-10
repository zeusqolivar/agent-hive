import Foundation
import Testing
@testable import HiveCore

/// `/api/classroom`: the cases of agent-dashboard's tests/test_classroom_api.py, against a temporary home.
/// The Host, Origin and content-type cases don't apply: the app's pages reach the API only through the
/// `hive://` scheme handler, with no network listener.
@Suite struct ClassroomTests {
    static func room(_ over: KeyValuePairs<String, JSON> = [:]) -> JSON {
        var o = JSONObject([
            "version": 1, "cols": 24, "rows": 18,
            "floor": ["style": "tile", "color": nil], "wall": ["color": nil],
            "items": [
                ["id": "d1", "kind": "desk", "x": 10, "y": 6],
                ["id": "m1", "kind": "machine", "x": 20, "y": 5],
                ["id": "door", "kind": "door", "x": 20, "y": 0],
            ],
        ])
        for (k, v) in over { o[k] = v }
        return .object(o)
    }

    static func items(plus extra: JSON) -> JSON {
        .array((room()["items"]?.array ?? []) + [extra])
    }

    /// A store in a fresh temporary home, so the owner's real classroom.json is never touched.
    static func store() -> ClassroomStore {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "hive-classroom-\(UUID().uuidString)", directoryHint: .isDirectory)
        return ClassroomStore(paths: HivePaths(home: home, uid: 501))
    }

    static func api(_ store: ClassroomStore) async throws -> HiveAPI {
        try await HiveAPITests.api(classroom: store)
    }

    static func request(_ api: HiveAPI, _ method: String, _ body: JSON? = nil, raw: Data? = nil) async -> (Int, JSON?) {
        let data = raw ?? body.map { $0.serialized() }
        let r = await api.handle(method: method, path: "/api/classroom", body: data)
        #expect(r.contentType.hasPrefix("application/json"))
        return (r.status, try? JSON.parse(r.body))
    }

    @Test func fileLivesInApplicationSupport() {
        let paths = HivePaths(home: URL(filePath: "/tmp/h"), uid: 501)
        #expect(paths.classroomFile.path == "/tmp/h/Library/Application Support/Agent Hive/classroom.json")
    }

    @Test func missingFileIsAutomatic() async throws {
        let api = try await Self.api(Self.store())
        let (status, body) = await Self.request(api, "GET")
        #expect(status == 200)
        #expect(body == ["room": nil])
    }

    @Test func saveThenLoad() async throws {
        let store = Self.store()
        let api = try await Self.api(store)
        let (status, body) = await Self.request(api, "POST", ["room": Self.room()])
        #expect(status == 200)
        #expect(body == ["ok": true])
        #expect(FileManager.default.fileExists(atPath: store.file.path))
        let (s2, b2) = await Self.request(api, "GET")
        #expect(s2 == 200)
        #expect(b2 == ["room": Self.room()])
        #expect(store.load() == Self.room())
    }

    /// Written as server.py writes it, `json.dump(room, ensure_ascii=False, indent=1)`, so the browser
    /// version and the app leave the same file.
    @Test func writtenLikeServerPy() throws {
        let store = Self.store()
        var room = Self.room().object!
        room["items"] = [["id": "d1", "kind": "desk", "x": 10, "y": 6], ["id": "door", "kind": "door", "x": 20, "y": 0]]
        room["extra"] = ["e": [], "o": .object(JSONObject()), "f": 1.5, "s": "é\n"]
        #expect(store.save(["room": .object(room)]).status == 200)
        let text = try String(contentsOf: store.file, encoding: .utf8)
        let python = "{\n \"version\": 1,\n \"cols\": 24,\n \"rows\": 18,\n \"floor\": {\n  \"style\": \"tile\",\n  \"color\": null\n },\n \"wall\": {\n  \"color\": null\n },\n \"items\": [\n  {\n   \"id\": \"d1\",\n   \"kind\": \"desk\",\n   \"x\": 10,\n   \"y\": 6\n  },\n  {\n   \"id\": \"door\",\n   \"kind\": \"door\",\n   \"x\": 20,\n   \"y\": 0\n  }\n ],\n \"extra\": {\n  \"e\": [],\n  \"o\": {},\n  \"f\": 1.5,\n  \"s\": \"é\\n\"\n }\n}"
        #expect(text == python)
    }

    @Test func nullDeletesTheFile() async throws {
        let store = Self.store()
        let api = try await Self.api(store)
        _ = await Self.request(api, "POST", ["room": Self.room()])
        let (status, body) = await Self.request(api, "POST", ["room": nil])
        #expect(status == 200)
        #expect(body == ["ok": true])
        #expect(!FileManager.default.fileExists(atPath: store.file.path))
        #expect(await Self.request(api, "GET").1 == ["room": nil])
        let again = await Self.request(api, "POST", ["room": nil])
        #expect(again.0 == 200, "deleting twice is fine")
        #expect(again.1 == ["ok": true])
    }

    @Test func noTempFilesLeftBehind() throws {
        let store = Self.store()
        #expect(store.save(["room": Self.room()]).status == 200)
        let names = try FileManager.default.contentsOfDirectory(atPath: store.file.deletingLastPathComponent().path)
        #expect(names == ["classroom.json"])
    }

    /// Saves a good room, sends `body`, and checks it is a 400 with a reason and the file is untouched.
    static func expectRejected(_ body: JSON? = nil, raw: Data? = nil, _ comment: Comment? = nil) async throws {
        let store = Self.store()
        let api = try await Self.api(store)
        #expect(await Self.request(api, "POST", ["room": Self.room()]).0 == 200)
        let before = try Data(contentsOf: store.file)
        let (status, payload) = await Self.request(api, "POST", body, raw: raw)
        #expect(status == 400, comment)
        #expect(payload?["error"]?.string?.isEmpty == false, comment)
        #expect(try Data(contentsOf: store.file) == before, "the saved file is untouched")
    }

    @Test func rejectsColsOutOfRange() async throws {
        try await Self.expectRejected(["room": Self.room(["cols": 99])])
    }

    @Test func rejectsUnknownKind() async throws {
        try await Self.expectRejected(["room": Self.room(["items": Self.items(plus: ["id": "t1", "kind": "throne", "x": 4, "y": 8])])])
    }

    @Test func rejectsFloatCoordinate() async throws {
        try await Self.expectRejected(["room": Self.room(["items": Self.items(plus: ["id": "p1", "kind": "plant", "x": 4.5, "y": 8])])])
    }

    @Test func rejectsTooManyItems() async throws {
        let items: [JSON] = (0..<401).map { ["id": .string("p\($0)"), "kind": "plant", "x": .int($0 % 24), "y": .int(4 + $0 % 8)] }
        try await Self.expectRejected(["room": Self.room(["items": .array(items)])])
    }

    @Test func rejectsBigBody() async throws {
        let body: JSON = ["room": Self.room(), "pad": .string(String(repeating: "x", count: 70_000))]
        try await Self.expectRejected(raw: body.serialized())
    }

    @Test func rejectsOtherShapes() async throws {
        try await Self.expectRejected(["nothing": true], "no room")
        try await Self.expectRejected(raw: Data("not json".utf8), "not JSON")
        try await Self.expectRejected(raw: Data("[1, 2]".utf8), "not an object")
        try await Self.expectRejected(["room": Self.room(["version": 2])], "version")
        try await Self.expectRejected(["room": Self.room(["floor": ["style": "lava", "color": nil]])], "floor")
        try await Self.expectRejected(["room": Self.room(["items": Self.items(plus: ["id": "p1", "kind": "plant", "x": 30, "y": 8])])], "outside")
        try await Self.expectRejected(["room": Self.room(["items": Self.items(plus: ["id": "p1", "kind": "plant", "x": true, "y": 8])])], "bool")
    }

    @Test func corruptFileLoadsAsNone() async throws {
        let store = Self.store()
        try FileManager.default.createDirectory(at: store.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: store.file)
        #expect(store.load() == .null)
        let api = try await Self.api(store)
        #expect(await Self.request(api, "GET").1 == ["room": nil])
        try Data("[1]".utf8).write(to: store.file)
        #expect(store.load() == .null, "a file that isn't an object counts as none")
    }

    /// `check_classroom`, with server.py's messages.
    @Test func checkClassroom() {
        #expect(ClassroomStore.check(Self.room()) == nil)
        #expect(ClassroomStore.check(Self.room(["rows": 11])) == "The room must be 16 to 48 tiles wide and 12 to 36 deep.")
        #expect(ClassroomStore.check([]) == "The room must be an object.")
        #expect(ClassroomStore.check(Self.room(["version": 2])) == "Unknown room version.")
        #expect(ClassroomStore.check(Self.room(["cols": 24.0])) != nil, "whole numbers only")
        #expect(ClassroomStore.check(Self.room(["floor": ["style": "wood", "color": "#a0B1c2"]])) == nil)
        #expect(ClassroomStore.check(Self.room(["floor": ["style": "wood", "color": "red"]])) == "Unknown floor style or colour.")
        #expect(ClassroomStore.check(Self.room(["floor": "tile"])) == "Unknown floor style or colour.")
        #expect(ClassroomStore.check(Self.room(["wall": ["color": "#12345"]])) == "Unknown wall colour.")
        #expect(ClassroomStore.check(Self.room(["wall": nil])) == "Unknown wall colour.")
        #expect(ClassroomStore.check(Self.room(["items": nil])) == "The room has no item list.")
        let many: [JSON] = (0..<401).map { _ in ["id": "p", "kind": "plant", "x": 1, "y": 5] }
        #expect(ClassroomStore.check(Self.room(["items": .array(many)])) == "At most 400 items.")
        #expect(ClassroomStore.check(Self.room(["items": [["id": "", "kind": "plant", "x": 1, "y": 5]]])) == "Every item needs an id.")
        #expect(ClassroomStore.check(Self.room(["items": [["id": .string(String(repeating: "a", count: 41)), "kind": "plant", "x": 1, "y": 5]]])) == "Every item needs an id.")
        #expect(ClassroomStore.check(Self.room(["items": [["id": 7, "kind": "plant", "x": 1, "y": 5]]])) == "Every item needs an id.")
        #expect(ClassroomStore.check(Self.room(["items": ["plant"]])) == "Every item needs an id.")
        #expect(ClassroomStore.check(Self.room(["items": [["id": "t1", "kind": "throne", "x": 1, "y": 5]]])) == "Item t1 is of an unknown kind.")
        #expect(ClassroomStore.check(Self.room(["items": [["id": "p1", "kind": "plant", "x": 24, "y": 5]]])) == "Item p1 must be on whole tiles inside the room.")
        #expect(ClassroomStore.check(Self.room(["items": [["id": "p1", "kind": "plant", "x": 0, "y": -1]]])) == "Item p1 must be on whole tiles inside the room.")
        #expect(ClassroomStore.check(Self.room(["items": [["id": "p1", "kind": "plant", "x": 0, "y": 17]]])) == nil)
        for kind in ClassroomStore.kinds {
            #expect(ClassroomStore.check(Self.room(["items": [["id": "k", "kind": .string(kind), "x": 0, "y": 0]]])) == nil, "\(kind)")
        }
    }

    @Test func emptyBodyAsksForARoom() async throws {
        let api = try await Self.api(Self.store())
        let (status, body) = await Self.request(api, "POST", raw: Data())
        #expect(status == 400)
        #expect(body?["error"] == "Send {room}.")
    }

    @Test func savingCreatesTheFolder() throws {
        let store = Self.store()
        #expect(!FileManager.default.fileExists(atPath: store.file.deletingLastPathComponent().path))
        let r = store.save(["room": Self.room()])
        #expect(r.status == 200)
        #expect(r.body == ["ok": true])
    }
}
