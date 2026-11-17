import Foundation

/// Each AI agent's MCP connectors, read from their own config files: name, type, scope and, for web servers,
/// the host name. Read-only. Commands, arguments, environment, headers, full URLs and query strings are never
/// returned, since they often hold keys and tokens.
public struct ConnectorsReader: Sendable {
    let paths: HivePaths

    public static let note = "Connectors added in claude.ai's settings live on Anthropic's servers and aren't listed here."

    public init(paths: HivePaths) {
        self.paths = paths
    }

    /// One connector: only what is safe to show.
    struct Row: Equatable {
        var name: String
        var type: String
        var scope: String
        var host: String?
        var disabled: Bool

        var json: JSON {
            ["name": .string(name), "type": .string(type), "scope": .string(scope), "host": JSON(host),
             "disabled": .bool(disabled)]
        }
    }

    /// `{agents: [{agent, connectors: [{name, type, scope, host, disabled}]}], note}`. Agents with none of
    /// their config files are left out; a missing or malformed file is skipped.
    public func report() -> JSON {
        var agents: [JSON] = []
        func add(_ agent: String, _ rows: [Row]?) {
            guard let rows else { return }
            agents.append(["agent": .string(agent), "connectors": .array(rows.map(\.json))])
        }
        add("Claude Code", claudeCode())
        add("Claude desktop app", fromFiles([(paths.claudeDesktopConfig, "app")]))
        add("Antigravity", fromFiles(paths.antigravityMCPConfigs))
        add("Codex", codex())
        add("Cursor", fromFiles([(paths.cursorMCP, "user")]))
        add("OpenClaw", openClaw())
        return ["agents": .array(agents), "note": .string(Self.note)]
    }

    // MARK: - Sources

    /// `~/.claude.json` (user and per-project servers) and the `.mcp.json` of installed and synced plugins.
    func claudeCode() -> [Row]? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.claudeJSON.path) || fm.fileExists(atPath: paths.claude.path) else { return nil }
        var rows: [Row] = []
        if let config = Self.readJSON(paths.claudeJSON) {
            rows += Self.rows(config["mcpServers"], scope: "user")
            for (folder, project) in config["projects"]?.object?.pairs ?? JSONObject().pairs {
                let off = Set(project["disabledMcpServers"]?.array?.compactMap(\.string) ?? [])
                rows += Self.rows(project["mcpServers"], scope: shorten(folder), disabledNames: off)
            }
        }
        var seen = Set<String>()
        func plugin(_ folder: URL, _ name: String) {
            guard let config = Self.readJSON(folder.appending(path: ".mcp.json")) else { return }
            let servers = config["mcpServers"] ?? config
            for row in Self.rows(servers, scope: name) where seen.insert("\(name)\u{0}\(row.name)").inserted {
                rows.append(row)
            }
        }
        let installed = Self.readJSON(paths.plugins.appending(path: "installed_plugins.json"))?["plugins"]?.object
        for (key, value) in installed?.pairs ?? JSONObject().pairs {
            let name = String(key.split(separator: "@", maxSplits: 1).first ?? Substring(key))
            let entries = value.array ?? [value]
            var folders = Set<String>()
            for entry in entries {
                guard let path = entry["installPath"]?.string, !path.isEmpty, folders.insert(path).inserted else { continue }
                plugin(URL(filePath: path, directoryHint: .isDirectory), name)
            }
        }
        let synced = paths.plugins.appending(path: "synced", directoryHint: .isDirectory)
        for account in Self.sortedChildren(synced) {
            for folder in Self.sortedChildren(account) {
                let name = String(folder.lastPathComponent.split(separator: "~", maxSplits: 1).first ?? "")
                guard !name.isEmpty else { continue }
                plugin(folder, name)
            }
        }
        return rows
    }

    /// `~/.codex/config.toml`'s `[mcp_servers.<name>]` tables.
    func codex() -> [Row]? {
        guard let data = FileManager.default.contents(atPath: paths.codexConfig.path) else { return nil }
        return Self.codexServers(String(decoding: data, as: UTF8.self)).map { s in
            let host = s.url.flatMap(Self.host)
            return Row(name: s.name, type: s.url != nil ? "http" : "stdio", scope: "user", host: host,
                       disabled: !s.enabled)
        }
    }

    /// Any `mcpServers` in `~/.openclaw/*.json`, scoped by file name.
    func openClaw() -> [Row]? {
        let files = Self.sortedChildren(paths.openclawFolder).filter { $0.pathExtension == "json" }
        guard !files.isEmpty else { return nil }
        return fromFiles(files.map { ($0, $0.lastPathComponent) })
    }

    /// `mcpServers` from JSON config files; nil when none of them exists.
    func fromFiles(_ files: [(url: URL, scope: String)]) -> [Row]? {
        let present = files.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        guard !present.isEmpty else { return nil }
        return present.flatMap { Self.rows(Self.readJSON($0.url)?["mcpServers"], scope: $0.scope) }
    }

    // MARK: - Rows

    static func rows(_ servers: JSON?, scope: String, disabledNames: Set<String> = []) -> [Row] {
        guard let servers = servers?.object else { return [] }
        return servers.pairs.compactMap { name, server in
            guard let server = server.object else { return nil }
            let url = ["url", "serverUrl", "httpUrl"].lazy.compactMap { server[$0]?.string }.first
            let disabled = server["disabled"]?.bool == true || server["enabled"]?.bool == false
                || disabledNames.contains(name)
            return Row(name: name, type: type(declared: server["type"]?.string ?? server["transport"]?.string,
                                              hasCommand: server["command"] != nil, url: url),
                       scope: scope, host: url.flatMap(host), disabled: disabled)
        }
    }

    /// `stdio`, `http` or `sse`: the declared type when there is one, else from a command or a URL.
    static func type(declared: String?, hasCommand: Bool, url: String?) -> String {
        switch declared?.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "stdio": return "stdio"
        case "sse": return "sse"
        case "http", "streamable-http", "streamablehttp": return "http"
        default: break
        }
        if hasCommand || url == nil { return "stdio" }
        let path = URLComponents(string: url ?? "")?.path ?? ""
        return path.hasSuffix("/sse") ? "sse" : "http"
    }

    /// The bare host name of a web URL, lowercased; nil for anything else. Never the user, password, port,
    /// path or query.
    static func host(_ url: String) -> String? {
        guard let parts = URLComponents(string: url), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty else { return nil }
        return host.lowercased()
    }

    /// A project folder with the home folder written as `~`.
    func shorten(_ folder: String) -> String {
        let home = paths.home.path.hasSuffix("/") ? String(paths.home.path.dropLast()) : paths.home.path
        if folder == home { return "~" }
        if folder.hasPrefix(home + "/") { return "~" + folder.dropFirst(home.count) }
        return folder
    }

    // MARK: - Codex TOML

    struct CodexServer: Equatable {
        var name: String
        var command = false
        var url: String?
        var enabled = true
    }

    private static let header = try! NSRegularExpression(pattern: #"^\s*\[\s*([^\]]*?)\s*\]\s*(#.*)?$"#)
    private static let keyValue = try! NSRegularExpression(pattern: #"^\s*([A-Za-z0-9_-]+|"[^"]*"|'[^']*')\s*=\s*(.*)$"#)

    /// The servers in a Codex config: `[mcp_servers.<name>]` tables (bare or quoted names, their sub-tables
    /// ignored) and inline tables under `[mcp_servers]`. A minimal scan, not a full TOML parser.
    static func codexServers(_ toml: String) -> [CodexServer] {
        var servers: [CodexServer] = []
        var current: Int?          // index of the server whose own table we're in
        var inRoot = false         // inside `[mcp_servers]` itself
        for raw in toml.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw)
            let trimmed = Text.strip(line)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("["), let h = Text.firstGroup(header, trimmed) {
                current = nil
                inRoot = false
                let keys = dottedKeys(h)
                guard keys.first == "mcp_servers" else { continue }
                if keys.count == 1 { inRoot = true; continue }
                if keys.count == 2 {
                    servers.append(CodexServer(name: keys[1]))
                    current = servers.count - 1
                }
                continue
            }
            guard let m = keyValue.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let k = Range(m.range(at: 1), in: line), let v = Range(m.range(at: 2), in: line) else { continue }
            let key = unquote(String(line[k]))
            let value = Text.strip(String(line[v]))
            if inRoot, value.hasPrefix("{") {
                var server = CodexServer(name: key)
                for pair in inlinePairs(value) { apply(pair.key, pair.value, to: &server) }
                servers.append(server)
            } else if let i = current {
                apply(key, value, to: &servers[i])
            }
        }
        return servers
    }

    private static func apply(_ key: String, _ value: String, to server: inout CodexServer) {
        switch key {
        case "command": server.command = true
        case "url": server.url = stringValue(value)
        case "enabled": server.enabled = !value.hasPrefix("false")
        default: break
        }
    }

    /// `a."b.c".'d'` as `["a", "b.c", "d"]`.
    static func dottedKeys(_ s: String) -> [String] {
        var keys: [String] = []
        var cur = ""
        var quote: Character?
        for ch in s {
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "." {
                keys.append(Text.strip(cur)); cur = ""
            } else {
                cur.append(ch)
            }
        }
        keys.append(Text.strip(cur))
        return keys
    }

    private static func unquote(_ s: String) -> String {
        if s.count >= 2, let f = s.first, f == "\"" || f == "'", s.last == f { return String(s.dropFirst().dropLast()) }
        return s
    }

    /// The text of a basic or literal TOML string at the start of `value`.
    private static func stringValue(_ value: String) -> String? {
        guard let q = value.first, q == "\"" || q == "'" else { return nil }
        let rest = value.dropFirst()
        guard let end = rest.firstIndex(of: q) else { return nil }
        return String(rest[..<end])
    }

    /// The top-level `key = value` pairs of an inline table, `{ a = "x", b = [1, 2] }`.
    private static func inlinePairs(_ table: String) -> [(key: String, value: String)] {
        var pairs: [(String, String)] = []
        var depth = 0
        var quote: Character?
        var cur = ""
        func flush() {
            if let eq = cur.firstIndex(of: "=") {
                pairs.append((unquote(Text.strip(String(cur[..<eq]))), Text.strip(String(cur[cur.index(after: eq)...]))))
            }
            cur = ""
        }
        for ch in table {
            if let q = quote {
                cur.append(ch)
                if ch == q { quote = nil }
                continue
            }
            switch ch {
            case "\"", "'": quote = ch; cur.append(ch)
            case "{", "[":
                depth += 1
                if depth > 1 { cur.append(ch) }
            case "}", "]":
                if depth > 1 { cur.append(ch) }
                depth -= 1
                if depth == 0 { flush() }
            case "," where depth == 1: flush()
            default: cur.append(ch)
            }
        }
        return pairs
    }

    // MARK: - Files

    static func readJSON(_ url: URL) -> JSON? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return try? JSON.parse(data)
    }

    static func sortedChildren(_ folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().map { folder.appending(path: $0) }
    }
}
