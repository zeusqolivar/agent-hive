import Foundation

/// Every folder and file Agent Hive reads, derived from one home folder and user id.
/// Readers take a `HivePaths` instead of looking up the home folder themselves, so tests
/// can point them at fixtures.
public struct HivePaths: Sendable {
    public var home: URL
    public var uid: Int
    public var claude: URL
    public var sessions: URL
    public var projects: URL
    public var plugins: URL
    public var settings: URL
    public var codexSessions: URL
    public var openclawDB: URL
    /// Where Claude Code writes background task output: `/private/tmp/claude-<uid>`.
    public var tasksRoot: URL
    /// The OpenClaw package installed by Homebrew, for its bundled skills and version.
    public var openclawPackage: URL
    /// Agent Hive's own folder: the classroom layout, the Claude status line script and limits, usage history.
    public var supportFolder: URL
    /// The saved classroom arrangement, shared with the browser version's server.py.
    public var classroomFile: URL
    /// Google Antigravity's folder: its conversation database, transcripts (`brain/`) and daemon files.
    public var antigravity: URL
    public var antigravityDB: URL
    /// The Antigravity app, for its version.
    public var antigravityApp: URL
    /// Where the running Antigravity window writes its DevTools port, in the order server.py looks.
    public var antigravityDevToolsPorts: [URL]
    /// Claude Code's main config: user and per-project MCP servers.
    public var claudeJSON: URL
    /// The Claude desktop app's MCP config.
    public var claudeDesktopConfig: URL
    /// Antigravity's MCP configs, with the scope each is shown under.
    public var antigravityMCPConfigs: [(url: URL, scope: String)]
    /// Codex's config, for its `[mcp_servers.<name>]` tables.
    public var codexConfig: URL
    /// Cursor's MCP config.
    public var cursorMCP: URL
    /// OpenClaw's folder, whose top-level JSON files may list MCP servers.
    public var openclawFolder: URL

    public init(home: URL, uid: Int) {
        self.home = home
        self.uid = uid
        claude = home.appending(path: ".claude", directoryHint: .isDirectory)
        sessions = claude.appending(path: "sessions", directoryHint: .isDirectory)
        projects = claude.appending(path: "projects", directoryHint: .isDirectory)
        plugins = claude.appending(path: "plugins", directoryHint: .isDirectory)
        settings = claude.appending(path: "settings.json", directoryHint: .notDirectory)
        codexSessions = home.appending(path: ".codex/sessions", directoryHint: .isDirectory)
        openclawDB = home.appending(path: ".openclaw/state/openclaw.sqlite", directoryHint: .notDirectory)
        tasksRoot = URL(filePath: "/private/tmp/claude-\(uid)", directoryHint: .isDirectory)
        openclawPackage = URL(filePath: "/opt/homebrew/lib/node_modules/openclaw", directoryHint: .isDirectory)
        supportFolder = home.appending(path: "Library/Application Support/Agent Hive", directoryHint: .isDirectory)
        classroomFile = supportFolder.appending(path: "classroom.json", directoryHint: .notDirectory)
        antigravity = home.appending(path: ".gemini/antigravity", directoryHint: .isDirectory)
        antigravityDB = antigravity.appending(path: "conversation_summaries.db", directoryHint: .notDirectory)
        antigravityApp = URL(filePath: "/Applications/Antigravity.app", directoryHint: .isDirectory)
        antigravityDevToolsPorts = [
            home.appending(path: "Library/Application Support/Antigravity/DevToolsActivePort", directoryHint: .notDirectory),
            home.appending(path: ".config/Antigravity/DevToolsActivePort", directoryHint: .notDirectory),
        ]
        claudeJSON = home.appending(path: ".claude.json", directoryHint: .notDirectory)
        claudeDesktopConfig = home.appending(path: "Library/Application Support/Claude/claude_desktop_config.json",
                                             directoryHint: .notDirectory)
        antigravityMCPConfigs = [
            (home.appending(path: ".gemini/antigravity/mcp_config.json", directoryHint: .notDirectory), "agent"),
            (home.appending(path: ".gemini/antigravity-ide/mcp_config.json", directoryHint: .notDirectory), "editor"),
            (home.appending(path: ".gemini/config/mcp_config.json", directoryHint: .notDirectory), "shared"),
        ]
        codexConfig = home.appending(path: ".codex/config.toml", directoryHint: .notDirectory)
        cursorMCP = home.appending(path: ".cursor/mcp.json", directoryHint: .notDirectory)
        openclawFolder = home.appending(path: ".openclaw", directoryHint: .isDirectory)
    }

    /// The opt-in status line script and what it saves.
    public var statusLineScript: URL { supportFolder.appending(path: "statusline.sh", directoryHint: .notDirectory) }
    public var statusLinePrevious: URL {
        supportFolder.appending(path: "statusline-previous.json", directoryHint: .notDirectory)
    }
    public var claudeLimitsFile: URL { supportFolder.appending(path: "claude-limits.json", directoryHint: .notDirectory) }
    /// Balance snapshots for the services that report a balance but no history.
    public var usageHistoryFile: URL { supportFolder.appending(path: "usage-history.json", directoryHint: .notDirectory) }

    /// `brain/<id>/.system_generated`, where Antigravity keeps one conversation's transcript and task logs.
    public func antigravityConversation(_ id: String) -> URL {
        antigravity.appending(path: "brain/\(id)/.system_generated", directoryHint: .isDirectory)
    }

    /// `brain/<id>/.system_generated/logs/transcript.jsonl`.
    public func antigravityTranscript(_ id: String) -> URL {
        antigravityConversation(id).appending(path: "logs/transcript.jsonl", directoryHint: .notDirectory)
    }

    /// Whether a transcript is Antigravity's rather than Claude Code's (server.py's `is_antigravity`).
    public func isAntigravity(_ url: URL) -> Bool {
        url.path.hasPrefix(antigravity.path.hasSuffix("/") ? antigravity.path : antigravity.path + "/")
    }

    /// The signed-in user's real folders.
    public static var current: HivePaths {
        #if os(Windows)
        return HivePaths.windows(home: FileManager.default.homeDirectoryForCurrentUser,
                                 appData: windowsAppData, localAppData: windowsLocalAppData,
                                 temp: FileManager.default.temporaryDirectory)
        #else
        return HivePaths(home: FileManager.default.homeDirectoryForCurrentUser, uid: Int(getuid()))
        #endif
    }

    #if os(Windows)
    static var windowsAppData: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "AppData/Roaming", directoryHint: .isDirectory)
    }

    static var windowsLocalAppData: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "AppData/Local", directoryHint: .isDirectory)
    }
    #endif

    /// The same folders on Windows, where they come from `%USERPROFILE%`, `%APPDATA%`, `%LOCALAPPDATA%` and
    /// `%TEMP%` rather than from a home folder alone. Takes every folder as a parameter so tests can point it
    /// at a fixture, and so this stays plain URL building: it runs on both systems.
    ///
    /// The paths are the ones `docs/windows/phase-0-findings.md` found on a real PC. `uid` is 0: Windows has no
    /// `getuid()`, and nothing that depends on it is used there.
    public static func windows(home: URL,
                               appData: URL,
                               localAppData: URL,
                               temp: URL,
                               environment: [String: String] = [:]) -> HivePaths {
        var paths = HivePaths(home: home, uid: 0)
        paths.claude = home.appending(path: ".claude", directoryHint: .isDirectory)
        paths.sessions = paths.claude.appending(path: "sessions", directoryHint: .isDirectory)
        paths.projects = paths.claude.appending(path: "projects", directoryHint: .isDirectory)
        paths.plugins = paths.claude.appending(path: "plugins", directoryHint: .isDirectory)
        paths.settings = paths.claude.appending(path: "settings.json", directoryHint: .notDirectory)
        // The Store app may keep Codex's home under %LOCALAPPDATA%; CODEX_HOME wins when it is set.
        let codex = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
            ?? home.appending(path: ".codex", directoryHint: .isDirectory)
        paths.codexSessions = codex.appending(path: "sessions", directoryHint: .isDirectory)
        paths.codexConfig = codex.appending(path: "config.toml", directoryHint: .notDirectory)
        // Claude Code writes background task output to %TEMP%\claude\<hash>\<session>	asks; there is no
        // /private/tmp/claude-<uid> and no uid, so the root is the folder below %TEMP%.
        paths.tasksRoot = temp.appending(path: "claude", directoryHint: .isDirectory)
        paths.openclawPackage = appData.appending(path: "npm/node_modules/openclaw", directoryHint: .isDirectory)
        paths.openclawDB = home.appending(path: ".openclaw/state/openclaw.sqlite", directoryHint: .notDirectory)
        paths.openclawFolder = home.appending(path: ".openclaw", directoryHint: .isDirectory)
        paths.supportFolder = appData.appending(path: "Agent Hive", directoryHint: .isDirectory)
        paths.classroomFile = paths.supportFolder.appending(path: "classroom.json", directoryHint: .notDirectory)
        paths.antigravity = home.appending(path: ".gemini/antigravity", directoryHint: .isDirectory)
        paths.antigravityDB = paths.antigravity.appending(path: "conversation_summaries.db", directoryHint: .notDirectory)
        paths.antigravityApp = localAppData.appending(path: "Programs/antigravity", directoryHint: .isDirectory)
        paths.antigravityDevToolsPorts = [
            appData.appending(path: "Antigravity/DevToolsActivePort", directoryHint: .notDirectory),
        ]
        paths.claudeJSON = home.appending(path: ".claude.json", directoryHint: .notDirectory)
        paths.claudeDesktopConfig = appData.appending(path: "Claude/claude_desktop_config.json",
                                                      directoryHint: .notDirectory)
        paths.antigravityMCPConfigs = [
            (home.appending(path: ".gemini/antigravity/mcp_config.json", directoryHint: .notDirectory), "agent"),
            (home.appending(path: ".gemini/antigravity-ide/mcp_config.json", directoryHint: .notDirectory), "editor"),
            (home.appending(path: ".gemini/config/mcp_config.json", directoryHint: .notDirectory), "shared"),
        ]
        paths.cursorMCP = home.appending(path: ".cursor/mcp.json", directoryHint: .notDirectory)
        return paths
    }
}
