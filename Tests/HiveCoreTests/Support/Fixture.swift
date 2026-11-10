import Foundation
import Testing
@testable import HiveCore

/// The synthetic fixture home, prepared the same way `scripts/make_contract_fixtures.py` prepares it:
/// copied to a temporary folder, `__HOME__` replaced by that folder, every mtime set to `now - 60`.
enum Fixture {
    static let now = 1_794_312_000
    static var nowDate: Date { Date(timeIntervalSince1970: TimeInterval(now)) }

    static var root: URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
    }

    /// One shared prepared copy for tests that only read.
    static let shared: URL = try! prepare()

    static func paths(_ home: URL = shared) -> HivePaths {
        var paths = HivePaths(home: home, uid: 501)
        paths.openclawPackage = home.appending(path: "opt/openclaw", directoryHint: .isDirectory)
        paths.tasksRoot = home.appending(path: "tmp-tasks", directoryHint: .isDirectory)
        paths.antigravityApp = home.appending(path: "opt/Antigravity.app", directoryHint: .isDirectory)
        return paths
    }

    /// A private prepared copy for tests that add or change files.
    static func prepare() throws -> URL {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "hive-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let home = tmp.appending(path: "home", directoryHint: .isDirectory)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        try fm.copyItem(at: root.appending(path: "home"), to: home)
        let stamp = Date(timeIntervalSince1970: TimeInterval(now - 60))
        let enumerator = fm.enumerator(at: home, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            if ["json", "jsonl", "md"].contains(url.pathExtension) {
                let data = try Data(contentsOf: url)
                if let text = String(data: data, encoding: .utf8), text.contains("__HOME__") {
                    try Data(text.replacingOccurrences(of: "__HOME__", with: home.path).utf8).write(to: url)
                }
            }
            try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        }
        return home
    }

    /// An expected file with `__HOME__` replaced by `home`.
    static func expected(_ name: String, home: URL = shared) throws -> JSON {
        let url = root.appending(path: "expected/\(name)")
        let json = try JSON.parse(Data(contentsOf: url))
        return json.replacingInStrings("__HOME__", with: home.path)
    }

    static func expectedNames(prefix: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "expected").path)
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") }
            .sorted()
    }
}

/// The fixture's Antigravity app process (see scripts/make_contract_fixtures.py). macOS pids stay below 100000,
/// so it can't be a real process; `pidAlive` treats it as alive.
extension Fixture {
    static let antigravityPID: Int32 = 424_242

    static let pidAlive: @Sendable (Int32) -> Bool = { $0 == antigravityPID || SessionReader.pidAlive($0) }

    /// The process table the contract script used, from an expected file's `processes`.
    static func processes(_ expected: JSON) -> [Int32: ProcRecord] {
        var table: [Int32: ProcRecord] = [:]
        for p in expected["processes"]?.array ?? [] {
            let pid = Int32(p["pid"]?.int ?? 0)
            table[pid] = ProcRecord(pid: pid, ppid: Int32(p["ppid"]?.int ?? 0), uptime: p["uptime"]?.int ?? 0,
                                    rssMB: p["rssMB"]?.int ?? 0, cpu: p["cpu"]?.number ?? 0, cmd: p["cmd"]?.string ?? "")
        }
        return table
    }
}

/// Compares JSON the way the contract does: `null` and a missing key are the same, numbers compare by
/// value, and `ignoring` keys are skipped at every level. Returns the differences found.
func contractDiff(_ a: JSON?, _ b: JSON?, ignoring: Set<String> = [], path: String = "$") -> [String] {
    let a = a ?? .null, b = b ?? .null
    switch (a, b) {
    case (.object(let x), .object(let y)):
        var out: [String] = []
        for key in Set(x.keys).union(y.keys).sorted() where !ignoring.contains(key) {
            out += contractDiff(x[key], y[key], ignoring: ignoring, path: "\(path).\(key)")
        }
        return out
    case (.array(let x), .array(let y)):
        if x.count != y.count { return ["\(path): \(x.count) items vs \(y.count)"] }
        return zip(x, y).enumerated().flatMap { i, pair in
            contractDiff(pair.0, pair.1, ignoring: ignoring, path: "\(path)[\(i)]")
        }
    default:
        if let x = a.number, let y = b.number { return x == y ? [] : ["\(path): \(x) vs \(y)"] }
        return a == b ? [] : ["\(path): \(a.debugText) vs \(b.debugText)"]
    }
}

extension JSON {
    var debugText: String { String(decoding: serialized(), as: UTF8.self).prefix(160).description }
}
