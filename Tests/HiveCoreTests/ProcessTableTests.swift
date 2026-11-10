import Foundation
import Testing
@testable import HiveCore

final class ScriptedSource: ProcessSource, @unchecked Sendable {
    var results: [Result<[Int32: ProcRecord], Error>]
    private(set) var calls = 0
    init(_ results: [Result<[Int32: ProcRecord], Error>]) { self.results = results }
    func snapshot() throws -> [Int32: ProcRecord] {
        defer { calls += 1 }
        return try results[min(calls, results.count - 1)].get()
    }
}

struct Boom: Error {}

func proc(_ pid: Int32, _ ppid: Int32, _ cmd: String, cpu: Double = 0, rss: Int = 10, uptime: Int = 60) -> ProcRecord {
    ProcRecord(pid: pid, ppid: ppid, uptime: uptime, rssMB: rss, cpu: cpu, cmd: cmd)
}

@Suite struct ProcessTableTests {
    @Test func keepsTheLastGoodListWhenPsFails() {
        let first = [Int32(10): proc(10, 1, "claude")]
        let table = ProcessTable(source: ScriptedSource([.success(first), .failure(Boom()), .success([:])]))
        #expect(table.refresh() == first)
        #expect(table.refresh() == first)
        #expect(table.refresh() == first)
    }

    @Test func parsesPsOutput() {
        let text = """
          101     1 01-02:03:04  2048  12.5 /Applications/Claude.app/Contents/MacOS/Claude
          202   101    05:06    1536   0.0 claude --resume abc
          bad line
          303   202       07     512   1.0 /bin/zsh -c sleep 5
        """
        let table = PSProcessSource.parse(text)
        #expect(table.count == 3)
        #expect(table[101]?.uptime == 86400 + 2 * 3600 + 3 * 60 + 4)
        #expect(table[101]?.rssMB == 2)
        #expect(table[202]?.rssMB == 2)          // 1.5 rounds to even, as Python's round()
        #expect(table[303]?.uptime == 7)
        #expect(table[202]?.cmd == "claude --resume abc")
        #expect(table[101]?.cpu == 12.5)
    }

    @Test func parseEtime() {
        #expect(PSProcessSource.parseEtime("00:05") == 5)
        #expect(PSProcessSource.parseEtime("1:00:00") == 3600)
        #expect(PSProcessSource.parseEtime("3-00:00:01") == 3 * 86400 + 1)
    }

    @Test func realPsListsThisProcess() throws {
        let table = try PSProcessSource().snapshot()
        #expect(table[getpid()] != nil)
    }

    @Test func sessionProcessesWalkTheTreeAndHideDaemons() {
        let naming = Naming(home: "/Users/someone")
        let table: [Int32: ProcRecord] = [
            10: proc(10, 1, "claude", cpu: 5, rss: 100, uptime: 999),
            11: proc(11, 10, "/bin/zsh -c swift build", cpu: 50, rss: 30),
            12: proc(12, 11, "swift-build --product X", cpu: 80, rss: 200),
            13: proc(13, 10, "node /Users/someone/mcp-server/index.js", cpu: 1, rss: 40),
            14: proc(14, 10, "(swift-frontend)", cpu: 1, rss: 1),
            20: proc(20, 1, "unrelated", cpu: 99),
        ]
        let tree = ProcessTable.sessionProcesses(table, pid: 10, naming: naming)
        #expect(tree.commands.map(\.pid) == [12, 11])
        #expect(tree.rssMB == 100 + 30 + 200 + 40 + 1)
        #expect(tree.cpu == 137)
        #expect(tree.uptime == 999)
    }
}
