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
        classroomFile = home.appending(path: "Library/Application Support/Agent Hive/classroom.json",
                                       directoryHint: .notDirectory)
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
        HivePaths(home: FileManager.default.homeDirectoryForCurrentUser, uid: Int(getuid()))
    }
}
