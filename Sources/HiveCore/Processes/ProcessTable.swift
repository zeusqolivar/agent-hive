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

/// The process source this system uses.
public enum ProcessSources {
    public static func system() -> ProcessSource {
        #if os(Windows)
        return WindowsProcessSource()
        #else
        return PSProcessSource()
        #endif
    }
}

/// One process as Windows reports it, before any arithmetic.
///
/// Keeping the raw numbers separate is what makes the board's CPU and memory figures testable on macOS: the
/// Win32 calls are the only part that cannot run there.
public struct ProcessRow: Sendable, Equatable {
    public var pid: Int32
    public var ppid: Int32
    /// When the process started, as Windows records it.
    public var startedAt: Date
    /// Total processor time used, in seconds: kernel plus user.
    public var cpuSeconds: Double
    public var workingSetBytes: UInt64
    public var commandLine: String

    public init(pid: Int32, ppid: Int32, startedAt: Date, cpuSeconds: Double, workingSetBytes: UInt64,
                commandLine: String) {
        self.pid = pid
        self.ppid = ppid
        self.startedAt = startedAt
        self.cpuSeconds = cpuSeconds
        self.workingSetBytes = workingSetBytes
        self.commandLine = commandLine
    }
}

/// Turns Windows process rows into the board's records.
public enum ProcessRecords {
    /// CPU as `ps`'s `pcpu` reports it: the process's total processor time over its lifetime, as a percentage.
    /// Lifetime is floored at one second so a process that has just started doesn't read as 8000%.
    public static func make(from rows: [ProcessRow], now: Date) -> [Int32: ProcRecord] {
        var table: [Int32: ProcRecord] = [:]
        for row in rows {
            let wall = max(1, now.timeIntervalSince(row.startedAt))
            let cpu = (row.cpuSeconds / wall) * 100
            let mb = (Double(row.workingSetBytes) / 1_048_576).rounded(.toNearestOrEven)
            table[row.pid] = ProcRecord(pid: row.pid, ppid: row.ppid,
                                        uptime: Int(wall), rssMB: Int(mb),
                                        cpu: (cpu * 10).rounded(.toNearestOrEven) / 10,
                                        cmd: Text.prefix(row.commandLine, 1500))
        }
        return table
    }
}

#if os(Windows)
import WinSDK
import CWinProcess

/// Lists processes with the Win32 API: `CreateToolhelp32Snapshot` for pids and parents, `GetProcessTimes` for
/// CPU, `K32GetProcessMemoryInfo` for memory, and `NtQueryInformationProcess` (through `CWinProcess`) for the
/// command line.
///
/// The board calls this every 2 seconds, so it stays flat and closes every handle it opens. Command lines are
/// unavailable for elevated or protected processes; those rows carry the executable name instead.
public struct WindowsProcessSource: ProcessSource {
    /// Room for a long command line; `ProcRecord.cmd` is trimmed to 1500 characters anyway.
    static let commandLineCapacity = 32 * 1024

    public init() {}

    public func snapshot() throws -> [Int32: ProcRecord] {
        ProcessRecords.make(from: Self.rows(), now: Date())
    }

    /// Whether a pid is alive: `OpenProcess` then `GetExitCodeProcess`. Access denied counts as alive, just as
    /// `EPERM` does from `kill(pid, 0)` on the Mac.
    public static func pidAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        guard let handle = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, DWORD(pid)) else {
            return GetLastError() == DWORD(ERROR_ACCESS_DENIED)
        }
        defer { CloseHandle(handle) }
        var code: DWORD = 0
        guard GetExitCodeProcess(handle, &code) else { return true }
        return code == DWORD(STILL_ACTIVE)
    }

    static func rows() -> [ProcessRow] {
        guard let snapshot = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPPROCESS), 0),
              snapshot != INVALID_HANDLE_VALUE else { return [] }
        defer { CloseHandle(snapshot) }

        var entry = PROCESSENTRY32W()
        entry.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
        var rows: [ProcessRow] = []
        var more = Process32FirstW(snapshot, &entry)
        // One buffer for every command line in the snapshot: allocating per process doubled the cost of a
        // refresh, which runs every 2 seconds.
        var buffer = [WCHAR](repeating: 0, count: commandLineCapacity)
        while more {
            let pid = Int32(entry.th32ProcessID)
            if pid > 0 {
                let ppid = Int32(entry.th32ParentProcessID)
                let name = exeName(entry)
                if let row = details(pid: pid, ppid: ppid, fallback: name, buffer: &buffer) {
                    rows.append(row)
                }
            }
            more = Process32NextW(snapshot, &entry)
        }
        return rows
    }

    static func exeName(_ entry: PROCESSENTRY32W) -> String {
        var entry = entry
        return withUnsafePointer(to: &entry.szExeFile) { raw in
            raw.withMemoryRebound(to: WCHAR.self, capacity: Int(MAX_PATH)) { wide in
                String(decodingCString: wide, as: UTF16.self)
            }
        }
    }

    /// Times, memory and command line for one process. Nil when it has already exited or access is refused.
    static func details(pid: Int32, ppid: Int32, fallback name: String, buffer: inout [WCHAR]) -> ProcessRow? {
        guard let handle = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, DWORD(pid)) else { return nil }
        defer { CloseHandle(handle) }

        var created = FILETIME(), exited = FILETIME(), kernel = FILETIME(), user = FILETIME()
        guard GetProcessTimes(handle, &created, &exited, &kernel, &user) else { return nil }

        var counters = PROCESS_MEMORY_COUNTERS_EX()
        let sized = DWORD(MemoryLayout<PROCESS_MEMORY_COUNTERS_EX>.size)
        let gotMemory = withUnsafeMutablePointer(to: &counters) { pointer in
            pointer.withMemoryRebound(to: PROCESS_MEMORY_COUNTERS.self, capacity: 1) { base in
                K32GetProcessMemoryInfo(handle, base, sized)
            }
        }

        return ProcessRow(pid: pid, ppid: ppid,
                          startedAt: date(from: created),
                          cpuSeconds: seconds(from: kernel) + seconds(from: user),
                          workingSetBytes: gotMemory ? UInt64(counters.WorkingSetSize) : 0,
                          commandLine: commandLine(pid: pid, buffer: &buffer) ?? name)
    }

    /// The command line through `CWinProcess`, which asks `ntdll` for it. Nil when access is refused.
    static func commandLine(pid: Int32, buffer: inout [WCHAR]) -> String? {
        let written = buffer.withUnsafeMutableBufferPointer { wide -> Int32 in
            Int32(hive_process_command_line(UInt32(pid), wide.baseAddress, Int32(wide.count)))
        }
        guard written > 0 else { return nil }
        return buffer.withUnsafeBufferPointer { wide in
            String(decodingCString: wide.baseAddress!, as: UTF16.self)
        }
    }

    /// A `FILETIME` is 100-nanosecond ticks since 1601-01-01.
    static func date(from fileTime: FILETIME) -> Date {
        Date(timeIntervalSince1970: ticks(fileTime) / 10_000_000 - 11_644_473_600)
    }

    static func seconds(from fileTime: FILETIME) -> Double {
        ticks(fileTime) / 10_000_000
    }

    static func ticks(_ fileTime: FILETIME) -> Double {
        Double((UInt64(fileTime.dwHighDateTime) << 32) | UInt64(fileTime.dwLowDateTime))
    }
}
#endif

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
