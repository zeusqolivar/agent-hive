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
}
