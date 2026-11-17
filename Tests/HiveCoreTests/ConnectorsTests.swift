import Foundation
import Testing
@testable import HiveCore

@Suite struct ConnectorsTests {
    static let home: URL = try! Fixture.prepare("connectors-home")

    static func report(_ home: URL = home) -> JSON {
        ConnectorsReader(paths: HivePaths(home: home, uid: 501)).report()
    }

    static func agent(_ report: JSON, _ name: String) -> [JSON]? {
        report["agents"]?.array?.first { $0["agent"]?.string == name }?["connectors"]?.array
    }

    static func row(_ rows: [JSON]?, _ name: String, scope: String? = nil) -> JSON? {
        rows?.first { $0["name"]?.string == name && (scope == nil || $0["scope"]?.string == scope) }
    }

    @Test func listsEveryAgentInOrder() {
        let agents = Self.report()["agents"]?.array?.compactMap { $0["agent"]?.string }
        #expect(agents == ["Claude Code", "Claude desktop app", "Antigravity", "Codex", "Cursor", "OpenClaw"])
        #expect(Self.report()["note"]?.string?.contains("claude.ai") == true)
    }

    @Test func claudeCodeUserProjectAndPluginScopes() throws {
        let rows = Self.agent(Self.report(), "Claude Code")
        let notes = try #require(Self.row(rows, "local-notes"))
        #expect(notes == ["name": "local-notes", "type": "stdio", "scope": "user", "host": nil, "disabled": false])
        #expect(Self.row(rows, "weather") == ["name": "weather", "type": "http", "scope": "user",
                                             "host": "api.weather.example", "disabled": false])
        #expect(Self.row(rows, "events") == ["name": "events", "type": "sse", "scope": "user",
                                            "host": "events.example.com", "disabled": true])
        #expect(Self.row(rows, "builder") == ["name": "builder", "type": "stdio", "scope": "~/code/sample-app",
                                             "host": nil, "disabled": true])
        #expect(Self.row(rows, "docs")?["scope"] == "/srv/shared/tools")
        #expect(Self.row(rows, "docs")?["type"] == "sse")
        #expect(Self.row(rows, "notes-cloud") == ["name": "notes-cloud", "type": "http", "scope": "notes-plugin",
                                                 "host": "mcp.notes.example", "disabled": false])
        #expect(Self.row(rows, "charts") == ["name": "charts", "type": "stdio", "scope": "charts",
                                            "host": nil, "disabled": false])
        #expect(rows?.count == 7)
    }

    @Test func otherAgents() {
        let report = Self.report()
        #expect(Self.row(Self.agent(report, "Claude desktop app"), "files")?["type"] == "stdio")
        let ag = Self.agent(report, "Antigravity")
        #expect(Self.row(ag, "design") == ["name": "design", "type": "http", "scope": "agent",
                                          "host": "design.example.net", "disabled": false])
        #expect(Self.row(ag, "helper")?["disabled"] == true)
        #expect(Self.row(ag, "db")?["scope"] == "editor")
        #expect(ag?.count == 3)  // the shared config file is malformed and skipped
        let codex = Self.agent(report, "Codex")
        #expect(Self.row(codex, "search") == ["name": "search", "type": "stdio", "scope": "user", "host": nil,
                                             "disabled": false])
        #expect(Self.row(codex, "remote-tools") == ["name": "remote-tools", "type": "http", "scope": "user",
                                                   "host": "tools.example.dev", "disabled": true])
        #expect(codex?.count == 2)
        #expect(Self.row(Self.agent(report, "Cursor"), "tickets")?["host"] == "tickets.example.com")
        #expect(Self.row(Self.agent(report, "OpenClaw"), "memory")?["scope"] == "openclaw.json")
    }

    @Test func noSecretReachesTheJSON() {
        let text = Self.report().serializedString
        #expect(!text.contains("SECRET"))
        for key in ["command", "args", "env", "headers", "url", "serverUrl"] {
            #expect(!text.contains("\"\(key)\""), "\(key)")
        }
        for value in ["npx", "/opt/tools", "/data/private", "https://", "http://", "?", "@", "mcp?"] {
            #expect(!text.contains(value), "\(value)")
        }
        for row in Self.report()["agents"]?.array?.flatMap({ $0["connectors"]?.array ?? [] }) ?? [] {
            #expect(row.object?.keys == ["name", "type", "scope", "host", "disabled"])
        }
    }

    @Test func missingOrMalformedFilesAreSkipped() throws {
        let home = try Fixture.prepare("connectors-home")
        try Data("{not json".utf8).write(to: home.appending(path: ".claude.json"))
        try FileManager.default.removeItem(at: home.appending(path: ".cursor"))
        let report = Self.report(home)
        let rows = Self.agent(report, "Claude Code")
        #expect(rows?.map { $0["name"]?.string } == ["notes-cloud", "charts"])
        #expect(Self.agent(report, "Cursor") == nil)
        #expect(Self.agent(report, "Codex")?.count == 2)

        let empty = FileManager.default.temporaryDirectory.appending(path: "empty-home-\(UUID().uuidString)")
        #expect(Self.report(empty)["agents"] == [])
    }

    @Test func hostOnly() {
        #expect(ConnectorsReader.host("https://user:pw@Example.COM:8443/path?q=1#f") == "example.com")
        #expect(ConnectorsReader.host("not a url") == nil)
        #expect(ConnectorsReader.host("file:///etc/passwd") == nil)
    }

    @Test func codexTOMLTables() {
        let toml = """
        [mcp_servers]
        inline = { command = "x", args = ["SECRET"] }
        [mcp_servers.'single quoted']
        url = 'http://a.example/mcp'
        # [mcp_servers.commented]
        [other]
        """
        let servers = ConnectorsReader.codexServers(toml)
        #expect(servers.map(\.name) == ["inline", "single quoted"])
        #expect(servers.last?.url == "http://a.example/mcp")
        #expect(servers.first?.command == true)
    }
}
