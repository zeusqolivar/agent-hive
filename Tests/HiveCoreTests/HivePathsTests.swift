import Foundation
import Testing
@testable import HiveCore

@Suite struct HivePathsTests {
    let paths = HivePaths(home: URL(filePath: "/tmp/h"), uid: 501)

    @Test func sessionsLiveUnderClaude() {
        #expect(paths.sessions.path == "/tmp/h/.claude/sessions")
        #expect(paths.projects.path == "/tmp/h/.claude/projects")
        #expect(paths.plugins.path == "/tmp/h/.claude/plugins")
        #expect(paths.settings.path == "/tmp/h/.claude/settings.json")
    }

    @Test func tasksRootUsesTheUid() {
        #expect(paths.tasksRoot.path == "/private/tmp/claude-501")
    }

    @Test func otherRoots() {
        #expect(paths.codexSessions.path == "/tmp/h/.codex/sessions")
        #expect(paths.openclawDB.path == "/tmp/h/.openclaw/state/openclaw.sqlite")
    }

    @Test func connectorConfigs() {
        #expect(paths.claudeJSON.path == "/tmp/h/.claude.json")
        #expect(paths.claudeDesktopConfig.path == "/tmp/h/Library/Application Support/Claude/claude_desktop_config.json")
        #expect(paths.antigravityMCPConfigs.map(\.scope) == ["agent", "editor", "shared"])
        #expect(paths.codexConfig.path == "/tmp/h/.codex/config.toml")
        #expect(paths.cursorMCP.path == "/tmp/h/.cursor/mcp.json")
    }
}
