import Foundation

/// One line of `ps`: a process with its parent, age in seconds, memory in MB, CPU percent and command.
public struct ProcRecord: Sendable, Equatable {
    public var pid: Int32
    public var ppid: Int32
    public var uptime: Int
    public var rssMB: Int
    public var cpu: Double
    public var cmd: String

    public init(pid: Int32, ppid: Int32, uptime: Int, rssMB: Int, cpu: Double, cmd: String) {
        self.pid = pid
        self.ppid = ppid
        self.uptime = uptime
        self.rssMB = rssMB
        self.cpu = cpu
        self.cmd = cmd
    }
}

/// Something that lists the Mac's processes. Tests use a fake.
public protocol ProcessSource: Sendable {
    func snapshot() throws -> [Int32: ProcRecord]
}

/// Lists processes with `/bin/ps`, giving up after 20 seconds.
public struct PSProcessSource: ProcessSource {
    public var timeout: TimeInterval = 20

    public init() {}

    public func snapshot() throws -> [Int32: ProcRecord] {
        let out = try Subprocess.run(URL(filePath: "/bin/ps"), ["-Ao", "pid=,ppid=,etime=,rss=,pcpu=,command="],
                                     timeout: timeout)
        return Self.parse(String(decoding: out.stdout, as: UTF8.self))
    }

    static func parse(_ text: String) -> [Int32: ProcRecord] {
        var table: [Int32: ProcRecord] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // Five whitespace-separated fields, then the command with its own spaces.
            var fields: [Substring] = []
            var rest = line[...]
            for _ in 0..<5 {
                rest = rest.drop(while: { $0 == " " || $0 == "\t" })
                guard let end = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) else { fields = []; break }
                fields.append(rest[..<end])
                rest = rest[end...]
            }
            let cmd = rest.drop(while: { $0 == " " || $0 == "\t" })
            guard fields.count == 5, !cmd.isEmpty,
                  let pid = Int32(fields[0]), let ppid = Int32(fields[1]), let rss = Int(fields[3]),
                  let cpu = Double(fields[4]) else { continue }
            let mb = (Double(rss) / 1024).rounded(.toNearestOrEven)
            table[pid] = ProcRecord(pid: pid, ppid: ppid, uptime: parseEtime(String(fields[2])), rssMB: Int(mb),
                                    cpu: cpu, cmd: Text.prefix(String(cmd), 1500))
        }
        return table
    }

    /// `parse_etime`: `[[dd-]hh:]mm:ss` to seconds.
    static func parseEtime(_ s: String) -> Int {
        var days = 0
        var clock = Substring(s)
        if let dash = clock.firstIndex(of: "-") {
            days = Int(clock[..<dash]) ?? 0
            clock = clock[clock.index(after: dash)...]
        }
        var parts = clock.split(separator: ":").compactMap { $0.allSatisfy(\.isNumber) ? Int($0) : nil }
        parts = Array(repeating: 0, count: max(0, 3 - parts.count)) + parts
        guard parts.count >= 3 else { return days * 86400 }
        return days * 86400 + parts[0] * 3600 + parts[1] * 60 + parts[2]
    }
}

/// A command a session is running, as the board shows it.
public struct SessionCommand: Sendable, Equatable, JSONRepresentable {
    public var pid: Int32
    public var uptime: Int
    public var cpu: Double
    public var rssMB: Int
    public var cmd: String

    public init(pid: Int32, uptime: Int, cpu: Double, rssMB: Int, cmd: String) {
        self.pid = pid; self.uptime = uptime; self.cpu = cpu; self.rssMB = rssMB; self.cmd = cmd
    }

    init(json o: JSONObject) {
        pid = Int32(o["pid"]?.int ?? 0)
        uptime = o["uptime"]?.int ?? 0
        cpu = o["cpu"]?.number ?? 0
        rssMB = o["rssMB"]?.int ?? 0
        cmd = o["cmd"]?.string ?? ""
    }

    public var json: JSON {
        ["pid": .int(Int(pid)), "uptime": .int(uptime), "cpu": .double(cpu), "rssMB": .int(rssMB), "cmd": .string(cmd)]
    }
}

/// A session's process tree: its busiest visible commands and the memory and CPU of the whole tree.
public struct SessionTree: Sendable, JSONRepresentable {
    public var commands: [SessionCommand]
    public var rssMB: Int
    public var cpu: Double
    public var uptime: Int?

    public var json: JSON {
        ["commands": commands.json, "rssMB": .int(rssMB), "cpu": .double(cpu), "uptime": JSON(uptime)]
    }
}

/// The process list, refreshed on demand. A failed or empty `ps` keeps the previous list: on a heavily
/// loaded Mac `ps` can time out, and that says nothing about what is still running.
public final class ProcessTable: @unchecked Sendable {
    private let source: ProcessSource
    private let lock = NSLock()
    private var last: [Int32: ProcRecord] = [:]

    public init(source: ProcessSource) {
        self.source = source
    }

    @discardableResult
    public func refresh() -> [Int32: ProcRecord] {
        let fresh = (try? source.snapshot()) ?? [:]
        lock.lock()
        defer { lock.unlock() }
        if !fresh.isEmpty { last = fresh }
        return last
    }

    public var current: [Int32: ProcRecord] {
        lock.lock()
        defer { lock.unlock() }
        return last
    }

    static let background = try! NSRegularExpression(
        pattern: #"mcp|disclaimer|sandbox-exec|caffeinate|npm exec|/npx|uvx|chroma|language-server|sourcekit|"#
            + #"\bzsh -c -l\b|snapshot-zsh|tail -f|/Claude iOS Sim|^sleep |dartvm|analysis_server|flutter_tools|GradleDaemon|KotlinCompileDaemon"#,
        options: [.caseInsensitive])

    /// Every process below `root`, depth first as server.py's `descendants` walks them.
    static func descendants(_ table: [Int32: ProcRecord], _ root: Int32) -> [ProcRecord] {
        var children: [Int32: [Int32]] = [:]
        for p in table.values.sorted(by: { $0.pid < $1.pid }) { children[p.ppid, default: []].append(p.pid) }
        var out: [ProcRecord] = []
        var stack = children[root] ?? []
        var seen = Set<Int32>()
        while let pid = stack.popLast() {
            guard seen.insert(pid).inserted, let p = table[pid] else { continue }
            out.append(p)
            stack.append(contentsOf: children[pid] ?? [])
        }
        return out
    }

    /// `session_processes`: the commands a session started, busiest first, without daemons.
    public static func sessionProcesses(_ table: [Int32: ProcRecord], pid: Int32, naming: Naming) -> SessionTree {
        let tree = descendants(table, pid)
        var cmds = tree.filter { !Text.matches(background, $0.cmd) && !$0.cmd.hasPrefix("(") }.map {
            SessionCommand(pid: $0.pid, uptime: $0.uptime, cpu: $0.cpu, rssMB: $0.rssMB,
                           cmd: Text.oneLine(naming.short($0.cmd), 160))
        }
        cmds = cmds.stableSorted { $0.cpu > $1.cpu }
        let me = table[pid]
        let cpu = (me?.cpu ?? 0) + tree.reduce(0) { $0 + $1.cpu }
        return SessionTree(commands: Array(cmds.prefix(8)),
                           rssMB: (me?.rssMB ?? 0) + tree.reduce(0) { $0 + $1.rssMB },
                           cpu: (cpu * 10).rounded(.toNearestOrEven) / 10,
                           uptime: me?.uptime)
    }
}
