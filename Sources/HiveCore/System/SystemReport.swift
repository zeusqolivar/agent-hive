import Foundation

/// `/api/system`: other agent apps running on the Mac, and OpenClaw's tasks and schedules.
public struct SystemReport: Sendable {
    /// The agents whose processes aren't sessions on the board.
    ///
    /// The macOS rows match app bundles. The Windows rows at the end match executable paths, because Windows has
    /// no bundles: several agents share `claude.exe`, and every Electron app spawns `--type=` helpers, so the
    /// helpers are skipped by pattern rather than by name. Only one set can ever match a given command line.
    static let otherAgents: [(label: String, pattern: NSRegularExpression)] = [
        ("skip", #"/Applications/Claude\.app/Contents/(Frameworks|Helpers)/"#),
        ("skip", #"/Applications/Antigravity\.app/Contents/Frameworks/"#),
        ("Claude desktop app", #"/Applications/Claude\.app/Contents/MacOS/Claude(\s|$)"#),
        ("Claude Code", #"/claude\.app/Contents/MacOS/claude(\s|$)|\.local/bin/claude(\s|$)|@anthropic-ai/claude-code"#),
        ("Google Antigravity", #"/Applications/Antigravity\.app/Contents/MacOS/Antigravity(\s|$)"#),
        ("Google Antigravity language server", #"/Applications/Antigravity\.app/Contents/Resources/bin/language_server(\s|$)"#),
        ("Google Gemini", #"/Applications/Gemini\.app/Contents/MacOS/Gemini(\s|$)"#),
        ("Codex", #"(^|/)codex(\.js)?(\s|$)|codex-cli"#),
        ("Cursor", #"/Cursor\.app/Contents/MacOS/Cursor"#),
        ("OpenClaw gateway", #"openclaw/dist/index\.js gateway"#),
        ("Continue", #"/continue(\s|$)"#),
        // Windows.
        ("skip", #"--type=(renderer|gpu-process|utility|crashpad-handler|zygote)"#),
        ("Claude desktop app", #"\\WindowsApps\\Claude_[\d.]+_x64__[^\\]+\\app\\Claude\.exe"#),
        ("Claude Code", #"(\\Claude-Data\\claude_[^\\]+\\claude-code\\|\\\.local\\bin\\claude\.exe|@anthropic-ai[/\\]claude-code)"#),
        ("Google Antigravity", #"\\Programs\\antigravity\\Antigravity\.exe"#),
        ("Google Antigravity language server", #"\\antigravity\\resources\\bin\\language_server\.exe"#),
        ("Cursor", #"\\Programs\\cursor\\Cursor\.exe"#),
        ("OpenClaw gateway", #"openclaw[\\/]dist[\\/]index\.js gateway"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1, options: [.caseInsensitive])) }

    let paths: HivePaths
    let openclaw: OpenClawReader

    public init(paths: HivePaths, now: @escaping @Sendable () -> Date = Date.init) {
        self.paths = paths
        openclaw = OpenClawReader(paths: paths, now: now)
    }

    /// Agent apps that aren't sessions on the board. `skipping` holds pids already shown as sessions.
    static func apps(state: BoardState, naming: Naming, skipping tracked: Set<Int32>) -> [JSON] {
        let me = getpid()
        var apps: [(name: String, pid: Int32, json: JSON)] = []
        for p in state.processes.values where !tracked.contains(p.pid) && p.pid != me {
            guard let label = otherAgents.first(where: { Text.matches($0.pattern, p.cmd) })?.label, label != "skip"
            else { continue }
            apps.append((label, p.pid, [
                "name": .string(label), "pid": .int(Int(p.pid)), "uptime": .int(p.uptime), "rssMB": .int(p.rssMB),
                "cpu": .double(p.cpu), "cmd": .string(Text.oneLine(naming.short(p.cmd), 140)),
            ]))
        }
        return apps.sorted { ($0.name, $0.pid) < ($1.name, $1.pid) }.map(\.json)
    }

    public func make(state: BoardState) -> Data {
        let tracked = Set(state.rows.compactMap { $0.pid.map { Int32(truncatingIfNeeded: $0) } })
        var summary: JSON = .null
        var error: JSON = .null
        do { summary = try openclaw.summary() } catch let e as OpenClawReader.DatabaseError {
            error = .string(e.message)
        } catch {
            summary = .null
        }
        let apps = Self.apps(state: state, naming: Naming(paths: paths), skipping: tracked)
        return JSON.object(JSONObject(["apps": .array(apps), "openclaw": summary, "openclawError": error])).serialized()
    }
}
