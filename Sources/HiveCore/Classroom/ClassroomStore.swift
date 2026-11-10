import Foundation

/// The saved classroom arrangement behind `/api/classroom`: `~/Library/Application Support/Agent Hive/classroom.json`,
/// the same file server.py's `load_classroom` and `save_classroom` use. Only the structure is checked here
/// (`check_classroom`); overlaps, zones, the single door and reachability are the page's job.
public struct ClassroomStore: Sendable {
    /// `CLASSROOM_KINDS`, which is `RoomModel.CATALOGUE` in room-model.js.
    public static let kinds = ["desk", "shelf", "globe", "machine", "rug", "beanbag", "couch", "plant", "fountain",
                               "lamp", "window", "board", "door", "poster", "clock"]
    public static let maxBody = 64 * 1024
    public static let maxItems = 400

    public let file: URL

    public init(paths: HivePaths) {
        file = paths.classroomFile
    }

    /// The saved room, or `null` when there is none or it can't be read.
    public func load() -> JSON {
        guard let data = FileManager.default.contents(atPath: file.path),
              let room = try? JSON.parse(data), room.object != nil else { return .null }
        return room
    }

    /// `save_classroom`: `{room}` saves it, `{room: null}` deletes the file. Returns the status and body.
    public func save(_ body: JSON) -> (status: Int, body: JSON) {
        guard let request = body.object, let room = request["room"] else { return (400, ["error": "Send {room}."]) }
        let fm = FileManager.default
        if room.isNull {
            do {
                try fm.removeItem(at: file)
            } catch {
                // Already gone is fine; anything else is an error, as os.remove's would be.
                if fm.fileExists(atPath: file.path) { return (400, ["error": .string(error.localizedDescription)]) }
            }
            return (200, ["ok": true])
        }
        if let problem = Self.check(room) { return (400, ["error": .string(problem)]) }
        let folder = file.deletingLastPathComponent()
        let tmp = folder.appending(path: ".classroom.\(getpid()).\(UUID().uuidString).tmp", directoryHint: .notDirectory)
        defer { try? fm.removeItem(at: tmp) }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            guard fm.createFile(atPath: tmp.path, contents: nil) else {
                return (400, ["error": "Couldn't write the classroom file."])
            }
            let handle = try FileHandle(forWritingTo: tmp)
            do {
                try handle.write(contentsOf: room.serialized(indent: 1))
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            // rename(2) replaces the old file in one step, so a reader sees the old room or the new one.
            guard rename(tmp.path, file.path) == 0 else {
                return (400, ["error": .string(String(cString: strerror(errno)))])
            }
        } catch {
            return (400, ["error": .string(error.localizedDescription)])
        }
        return (200, ["ok": true])
    }

    /// `check_classroom`: the problem with a room's structure, in server.py's words, or nil.
    public static func check(_ room: JSON) -> String? {
        guard let o = room.object else { return "The room must be an object." }
        // Python's `!= 1`, which True and 1.0 also pass.
        switch o["version"] {
        case .int(1)?, .bool(true)?, .double(1)?: break
        default: return "Unknown room version."
        }
        guard let cols = o["cols"]?.int, (16...48).contains(cols), let rows = o["rows"]?.int, (12...36).contains(rows) else {
            return "The room must be 16 to 48 tiles wide and 12 to 36 deep."
        }
        guard let floor = o["floor"]?.object, let style = floor["style"]?.string, ["tile", "wood", "carpet"].contains(style),
              colourOK(floor["color"]) else {
            return "Unknown floor style or colour."
        }
        guard let wall = o["wall"]?.object, colourOK(wall["color"]) else { return "Unknown wall colour." }
        guard let items = o["items"]?.array else { return "The room has no item list." }
        if items.count > maxItems { return "At most \(maxItems) items." }
        for item in items {
            guard let it = item.object, let id = it["id"]?.string, (1...40).contains(Text.length(id)) else {
                return "Every item needs an id."
            }
            guard let kind = it["kind"]?.string, kinds.contains(kind) else { return "Item \(id) is of an unknown kind." }
            guard let x = it["x"]?.int, let y = it["y"]?.int, (0..<cols).contains(x), (0..<rows).contains(y) else {
                return "Item \(id) must be on whole tiles inside the room."
            }
        }
        return nil
    }

    private static let colour = try! NSRegularExpression(pattern: "^#[0-9a-fA-F]{6}\n?\\z")

    /// `None`, or `#rrggbb` (Python's `$` also allows one newline at the end).
    static func colourOK(_ value: JSON?) -> Bool {
        guard let value, !value.isNull else { return true }
        guard let s = value.string else { return false }
        return Text.matches(colour, s)
    }
}
