import Foundation

/// What is keeping the Mac busy, grouped by app, as server.py's `mac_summary` reports it.
public enum MacSummary {
    private static let appBundle = try! NSRegularExpression(pattern: #"/([^/]+)\.app/"#)

    /// `app_name`: the app a process belongs to, or the program's own name.
    static func appName(_ cmd: String) -> String {
        if cmd.contains("CoreSimulator") { return "iOS Simulator" }
        if cmd.contains("claude-code") || cmd.contains("/.local/bin/claude") { return "Claude Code" }
        if cmd.contains("/Antigravity.app/") { return "Google Antigravity" }
        if cmd.contains("/Gemini.app/") { return "Google Gemini" }
        if let app = Text.firstGroup(appBundle, cmd) { return app }
        let first = cmd.components(separatedBy: " ").first ?? ""
        let base = Text.basename(first)
        return base.isEmpty ? Text.prefix(cmd, 30) : base
    }

    public static func make(_ table: [Int32: ProcRecord]) -> JSON {
        var order: [String] = []
        var apps: [String: (cpu: Double, rssMB: Int, count: Int)] = [:]
        for p in table.values.sorted(by: { $0.pid < $1.pid }) {
            let name = appName(p.cmd)
            if apps[name] == nil { order.append(name); apps[name] = (0, 0, 0) }
            apps[name]!.cpu += p.cpu
            apps[name]!.rssMB += p.rssMB
            apps[name]!.count += 1
        }
        let top = order.stableSorted { apps[$0]!.cpu > apps[$1]!.cpu }.prefix(7)
        let rows: [JSON] = top.compactMap { name in
            let a = apps[name]!
            guard a.cpu >= 1 else { return nil }
            return ["name": .string(name), "cpu": .int(Int(a.cpu.rounded(.toNearestOrEven))),
                    "rssMB": .int(a.rssMB), "count": .int(a.count)]
        }
        return ["load": .double(loadAverage()), "cores": .int(ProcessInfo.processInfo.processorCount),
                "top": .array(rows)]
    }

    /// The one-minute load average, to one decimal place.
    public static func loadAverage() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) > 0 else { return 0 }
        return (loads[0] * 10).rounded(.toNearestOrEven) / 10
    }
}
