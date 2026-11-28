import Foundation
import Testing
@testable import HiveCore

/// The parts of the Windows port that are plain logic, so they run on both systems: path building, the numbers
/// behind the process list, tool lookup, and recognising the agents' command lines.
@Suite struct WindowsPortTests {
    static let home = URL(filePath: "/fixture/home", directoryHint: .isDirectory)
    static let appData = URL(filePath: "/fixture/appdata", directoryHint: .isDirectory)
    static let localAppData = URL(filePath: "/fixture/local", directoryHint: .isDirectory)
    static let temp = URL(filePath: "/fixture/temp", directoryHint: .isDirectory)

    /// Paths compare by where they point: a URL built with `.isDirectory` carries a trailing separator, and
    /// `URL ==` counts that as a difference.
    static func path(_ url: URL) -> String {
        url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
    }

    static func paths(_ environment: [String: String] = [:]) -> HivePaths {
        HivePaths.windows(home: home, appData: appData, localAppData: localAppData, temp: temp,
                          environment: environment)
    }

    @Test func windowsPathsComeFromTheRootsTheCallerPasses() {
        let paths = Self.paths()
        #expect(paths.uid == 0)  // Windows has no getuid()
        #expect(Self.path(paths.claude) == Self.path(Self.home.appending(path: ".claude")))
        #expect(Self.path(paths.sessions) == Self.path(Self.home.appending(path: ".claude/sessions")))
        #expect(Self.path(paths.settings) == Self.path(Self.home.appending(path: ".claude/settings.json")))
        #expect(Self.path(paths.claudeJSON) == Self.path(Self.home.appending(path: ".claude.json")))
        #expect(Self.path(paths.supportFolder) == Self.path(Self.appData.appending(path: "Agent Hive")))
        #expect(Self.path(paths.classroomFile) == Self.path(Self.appData.appending(path: "Agent Hive/classroom.json")))
        #expect(Self.path(paths.claudeDesktopConfig) == Self.path(Self.appData.appending(path: "Claude/claude_desktop_config.json")))
        #expect(Self.path(paths.antigravity) == Self.path(Self.home.appending(path: ".gemini/antigravity")))
        #expect(Self.path(paths.antigravityDB) == Self.path(Self.home.appending(path: ".gemini/antigravity/conversation_summaries.db")))
        #expect(Self.path(paths.antigravityApp) == Self.path(Self.localAppData.appending(path: "Programs/antigravity")))
        #expect(paths.antigravityDevToolsPorts.map(Self.path) == [Self.path(Self.appData.appending(path: "Antigravity/DevToolsActivePort"))])
        // Claude Code's background task output: %TEMP%\claude, not /private/tmp/claude-<uid>.
        #expect(Self.path(paths.tasksRoot) == Self.path(Self.temp.appending(path: "claude")))
        #expect(Self.path(paths.openclawPackage) == Self.path(Self.appData.appending(path: "npm/node_modules/openclaw")))
        #expect(Self.path(paths.cursorMCP) == Self.path(Self.home.appending(path: ".cursor/mcp.json")))
        #expect(paths.antigravityMCPConfigs.map(\.scope) == ["agent", "editor", "shared"])
    }

    @Test func codexHomeIsHonoured() {
        let custom = HivePaths.windows(home: Self.home, appData: Self.appData, localAppData: Self.localAppData,
                                       temp: Self.temp, environment: ["CODEX_HOME": "/elsewhere/codex"])
        #expect(Self.path(custom.codexSessions) == Self.path(URL(filePath: "/elsewhere/codex").appending(path: "sessions")))
        #expect(Self.path(custom.codexConfig) == Self.path(URL(filePath: "/elsewhere/codex").appending(path: "config.toml")))
        // Unset or empty means the usual folder.
        #expect(Self.path(Self.paths().codexSessions) == Self.path(Self.home.appending(path: ".codex/sessions")))
        #expect(Self.path(Self.paths(["CODEX_HOME": ""]).codexSessions) == Self.path(Self.home.appending(path: ".codex/sessions")))
    }

    @Test func processRowsBecomeRecords() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let rows = [
            ProcessRow(pid: 10, ppid: 1, startedAt: now.addingTimeInterval(-100), cpuSeconds: 25,
                       workingSetBytes: 300 * 1_048_576, commandLine: "claude.exe --resume abc"),
            // Just started: the percentage must not run away.
            ProcessRow(pid: 11, ppid: 10, startedAt: now, cpuSeconds: 0.5,
                       workingSetBytes: 1_048_576, commandLine: "node.exe x"),
        ]
        let table = ProcessRecords.make(from: rows, now: now)
        #expect(table[10]?.ppid == 1)
        #expect(table[10]?.uptime == 100)
        #expect(table[10]?.rssMB == 300)
        #expect(table[10]?.cpu == 25)          // a quarter of the processor over its lifetime
        #expect(table[10]?.cmd == "claude.exe --resume abc")
        #expect(table[11]?.uptime == 1)        // floored at one second
        #expect(table[11]?.cpu == 50)
    }

    @Test func longCommandLinesAreTrimmedLikePss() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let long = String(repeating: "x", count: 4_000)
        let table = ProcessRecords.make(from: [ProcessRow(pid: 1, ppid: 0, startedAt: now, cpuSeconds: 0,
                                                          workingSetBytes: 0, commandLine: long)], now: now)
        #expect(table[1]?.cmd.count == 1500)
    }

    @Test func theAgentsAreRecognisedByTheirWindowsProcesses() {
        // The forms found on a real PC, from docs/windows/phase-0-findings.md.
        let session = #""C:\Users\me\AppData\Local\Claude-Data\claude_abc\claude-code\2.1.325\806e\claude.exe" --output-format stream-json"#
        #expect(AgentProcesses.isClaudeCode(session))
        #expect(AgentProcesses.isClaudeCode(#""C:\Users\me\.local\bin\claude.exe" auth status --json"#))
        let desktop = #""C:\Program Files\WindowsApps\Claude_5.11492.5.0_x64__abc\app\Claude.exe""#
        #expect(AgentProcesses.isClaudeDesktop(desktop))
        #expect(AgentProcesses.label(desktop) == "Claude desktop app")
        // Its chromium children carry the same path and must not count as the app.
        let helper = #""C:\Program Files\WindowsApps\Claude_5.11492.5.0_x64__abc\app\Claude.exe" --type=renderer --user-data-dir="C:\x""#
        #expect(!AgentProcesses.isClaudeDesktop(helper))
        #expect(AgentProcesses.isHelperProcess(helper))
        #expect(AgentProcesses.isAntigravityApp(#""C:\Users\me\AppData\Local\Programs\antigravity\Antigravity.exe" --updated"#))
        let server = #"C:\Users\me\AppData\Local\Programs\antigravity\resources\bin\language_server.exe --standalone --subclient_type hub"#
        #expect(AgentProcesses.isAntigravityLanguageServer(server))
        #expect(AgentProcesses.label(server) == "Google Antigravity language server")
        #expect(AgentProcesses.isAntigravity(server))
        // An unrelated node program is not a session.
        #expect(!AgentProcesses.isClaudeCode(#""C:\Program Files\nodejs\node.exe" "C:\node_modules\npm\bin\npx-cli.js" "-y" "@modelcontextprotocol/server-pdf""#))
    }

    @Test func theMacProcessesAreStillRecognised() {
        #expect(AgentProcesses.isClaudeCode("/Users/me/.local/bin/claude --resume x"))
        #expect(AgentProcesses.isClaudeDesktop("/Applications/Claude.app/Contents/MacOS/Claude"))
        #expect(AgentProcesses.isAntigravityApp("/Applications/Antigravity.app/Contents/MacOS/Antigravity"))
        #expect(AgentProcesses.isAntigravityLanguageServer(
            "/Applications/Antigravity.app/Contents/Resources/bin/language_server --port 1"))
        #expect(AgentProcesses.isAntigravityHubCLI("agy --hub"))
    }

    @Test func toolsAreFoundByTheirWindowsNames() {
        #expect(ToolLocator.names("claude") == ["claude.exe", "claude.cmd", "claude.bat", "claude"])
        #expect(ToolLocator.names("claude.cmd") == ["claude.cmd"])
        let folders = ToolLocator.folders(home: Self.home,
                                         environment: ["Path": "C:\\Windows;C:\\Program Files\\x"])
        #expect(folders.contains { $0.lastPathComponent == "npm" })
        #expect(folders.contains { $0.path == "C:/Windows" || $0.path == "C:\\Windows" })
        let batch = URL(filePath: "C:/Users/me/AppData/Roaming/npm/claude.cmd")
        let call = ToolLocator.invocation(batch, ["--resume", "abc"])
        #expect(call.arguments.prefix(3) == ["/d", "/s", "/c"])
        #expect(call.arguments.last == "abc")
        // A plain executable is run as itself.
        let exe = URL(filePath: "C:/Users/me/.local/bin/claude.exe")
        #expect(ToolLocator.invocation(exe, ["auth"]).arguments == ["auth"])
    }

    @Test func aFileIsReplacedInOneStep() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "hive-atomic-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appending(path: "settings.json")
        let temp = folder.appending(path: "settings.json.tmp")
        try Data("old".utf8).write(to: target)
        try Data("new".utf8).write(to: temp)
        try AtomicFile.replace(target, with: temp)
        #expect(try String(contentsOf: target, encoding: .utf8) == "new")
        #expect(!FileManager.default.fileExists(atPath: temp.path))
    }

    @Test func theWindowsFixtureHomeHasTheRealShape() throws {
        let home = try #require(Bundle.module.url(forResource: "Fixtures/windows-home", withExtension: nil))
        // Claude Code's session file, and the project folder name it derives from C:\Users\me\demo.
        #expect(FileManager.default.fileExists(atPath: home.appending(path: ".claude/sessions/424242.json").path))
        #expect(FileManager.default.fileExists(atPath: home.appending(path: ".claude/projects/C--Users-me-demo").path))
        let paths = HivePaths.windows(home: home,
                                      appData: home.appending(path: "AppData/Roaming"),
                                      localAppData: home.appending(path: "AppData/Local"),
                                      temp: home.appending(path: "AppData/Local/Temp"))
        // The initialiser finds Claude Code's session file where Windows keeps it. (liveSessions is not used
        // here: it also asks whether the pid is running, and no fixture pid is.)
        let names = try FileManager.default.contentsOfDirectory(atPath: paths.sessions.path)
        #expect(names.contains("424242.json"))
        let data = try Data(contentsOf: paths.sessions.appending(path: "424242.json"))
        let object: JSONObject = try #require(try JSON.parse(data).object)
        let record = SessionFile(json: object)
        #expect(record.sessionId == "sess-windows-0001")
    }

    #if os(Windows)
    @Test func theRealSnapshotIsFastEnoughForTheBoard() throws {
        // The board refreshes every 2 seconds; a snapshot has to be a small part of that. The bound is loose so
        // a busy CI machine does not fail it, and the line it prints is the number to quote in the PR.
        let source = WindowsProcessSource()
        _ = try source.snapshot()  // warm the handle and module caches
        let start = Date()
        let table = try source.snapshot()
        let milliseconds = Date().timeIntervalSince(start) * 1000
        print(String(format: "snapshot: %d processes in %.1f ms", table.count, milliseconds))
        #expect(milliseconds < 500)
        #expect(table.count > 20)
        #expect(table[getpid()] != nil)
        #expect(WindowsProcessSource.pidAlive(getpid()))
        // Command lines come through NtQueryInformationProcess for our own process.
        let mine = try #require(table[getpid()])
        #expect(mine.cmd.lowercased().contains("hivecoretests") || mine.cmd.lowercased().contains("test"))
    }
    #endif

    @Test func thePathSeparatorFollowsTheSystem() {
        let value = ToolLocator.pathValue(home: Self.home, environment: ["PATH": "existing"])
        #if os(Windows)
        #expect(value.contains(";"))
        #expect(!value.contains(":/opt"))
        #else
        #expect(value.contains(":"))
        #endif
        #expect(value.hasSuffix("existing") || value.hasSuffix("existing;") || value.hasSuffix(":existing"))
    }
}

@Suite struct ClockTests {
    /// The refresh loops pace themselves with `Task.sleep`. If that returned immediately the helper would spin
    /// at a full core, which is exactly what happened on Windows before this test existed.
    @Test func taskSleepActuallyWaits() async throws {
        let start = Date()
        try await Task.sleep(for: .milliseconds(300))
        let waited = Date().timeIntervalSince(start)
        #expect(waited >= 0.2, "Task.sleep(for:) waited only \(waited)s")
        // A generous ceiling on purpose: the only failure worth catching here is the sleep returning at once,
        // which is what spinning looks like. On a busy machine (a game at 447% CPU during a parallel run) 300 ms
        // can take seconds, and a tight bound would report that load as a defect.
        #expect(waited < 10, "Task.sleep(for:) waited \(waited)s for 300 ms")
    }
}
