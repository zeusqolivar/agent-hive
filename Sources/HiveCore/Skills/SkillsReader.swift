import Foundation

/// Every installed skill with its version, as server.py's `skills_report` lists them: plugins (with the
/// newest version in the local marketplace copy), account-synced plugins and plain skill folders.
public final class SkillsReader: @unchecked Sendable {
    private let paths: HivePaths
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var cached: (at: TimeInterval, data: JSON)?

    public init(paths: HivePaths, now: @escaping @Sendable () -> Date = Date.init) {
        self.paths = paths
        self.now = now
    }

    /// The skill folders Agent Hive looks in, with the label each gets.
    var roots: [(label: String, url: URL)] {
        let home = paths.home
        return [
            ("Claude Code", home.appending(path: ".claude/skills")),
            ("Shared agents", home.appending(path: ".agents/skills")),
            ("Cursor", home.appending(path: ".cursor/skills")),
            ("OpenClaw", home.appending(path: ".openclaw/skills")),
            ("OpenClaw workshop", home.appending(path: ".openclaw/agents/main/agent/workshop-skills")),
            ("OpenClaw plugins", home.appending(path: ".openclaw/plugin-skills")),
            ("OpenClaw bundled", paths.openclawPackage.appending(path: "skills")),
            ("OpenClaw custodian", paths.openclawPackage.appending(path: "custodian-skills")),
            ("Google Antigravity", home.appending(path: ".gemini/config/skills")),
            ("Google Antigravity builtin", paths.antigravity.appending(path: "builtin/skills")),
        ]
    }

    public func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    static func readJSON(_ url: URL) -> JSON? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return try? JSON.parse(data)
    }

    static func object(_ url: URL) -> JSONObject {
        readJSON(url)?.object ?? JSONObject()
    }

    private static let frontMatter = try! NSRegularExpression(pattern: #"\A---\s*\n(.*?)\n---"#,
                                                              options: [.dotMatchesLineSeparators])
    private static let description = try! NSRegularExpression(pattern: #"^description:[ \t]*(.*)$"#,
                                                              options: [.anchorsMatchLines])
    private static let version = try! NSRegularExpression(pattern: #"^\s*version:[ \t]*["']?([\w.+-]+)"#,
                                                          options: [.anchorsMatchLines])

    /// `skill_info`: name, description and version from a SKILL.md's front matter.
    static func skillInfo(_ folder: URL) -> JSON? {
        guard let handle = FileHandle(forReadingAtPath: folder.appending(path: "SKILL.md").path) else { return nil }
        defer { try? handle.close() }
        let head = Text.prefix(String(decoding: (try? handle.read(upToCount: 24_000)) ?? Data(), as: UTF8.self), 6000)
        var info = JSONObject(["name": .string(folder.lastPathComponent), "description": "", "version": .null])
        let ns = head as NSString
        if let m = frontMatter.firstMatch(in: head, range: NSRange(location: 0, length: ns.length)) {
            let block = ns.substring(with: m.range(at: 1))
            let bns = block as NSString
            if let d = description.firstMatch(in: block, range: NSRange(location: 0, length: bns.length)) {
                var text = Text.strip(bns.substring(with: d.range(at: 1)))
                if ["|", ">", "|-", ">-", ""].contains(text) {
                    let after = bns.substring(from: d.range.location + d.range.length).components(separatedBy: "\n")
                    text = after.filter { $0.hasPrefix(" ") || $0.hasPrefix("\t") }.map(Text.strip).joined(separator: " ")
                }
                info["description"] = .string(Text.oneLine(stripQuotes(text), 180))
            }
            if let v = Text.firstGroup(version, block) { info["version"] = .string(v) }
        }
        return .object(info)
    }

    static func stripQuotes(_ s: String) -> String {
        var t = Substring(s)
        while let c = t.first, c == "\"" || c == "'" { t = t.dropFirst() }
        while let c = t.last, c == "\"" || c == "'" { t = t.dropLast() }
        return String(t)
    }

    static func pySorted(_ names: [String]) -> [String] {
        names.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
    }

    /// `skills_in`: every subfolder with a SKILL.md, by name.
    static func skillsIn(_ folder: URL) -> [JSON] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return pySorted(names).compactMap { name -> JSON? in
            let sub = folder.appending(path: name, directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: sub.appending(path: "SKILL.md").path) else { return nil }
            return skillInfo(sub)
        }
    }

    static func versionTuple(_ v: String?) -> [Int] {
        guard let v else { return [] }
        var out: [Int] = [], digits = ""
        for c in v.unicodeScalars {
            if ("0"..."9").contains(c) { digits.unicodeScalars.append(c) } else if !digits.isEmpty {
                out.append(Int(digits) ?? 0); digits = ""
            }
        }
        if !digits.isEmpty { out.append(Int(digits) ?? 0) }
        return out
    }

    func installedPlugins() -> JSONObject {
        Self.object(paths.plugins.appending(path: "installed_plugins.json"))["plugins"]?.object ?? JSONObject()
    }

    /// The newest version in the local copy of the marketplace; `Check for updates` refreshes that copy.
    func marketplaceVersion(_ market: String, _ name: String) -> JSON {
        let known = Self.object(paths.plugins.appending(path: "known_marketplaces.json"))
        guard let location = known[market]?["installLocation"], location.truthy else { return .null }
        let root = URL(filePath: Py.str(location))
        let manifest = Self.object(root.appending(path: ".claude-plugin/marketplace.json"))
        guard let entry = (manifest["plugins"]?.array ?? []).compactMap({ $0.object })
            .first(where: { $0["name"] == .string(name) }) else { return .null }
        if let v = entry["version"], v.truthy { return v }
        if case .string(let source) = entry["source"] {
            return Self.object(root.appending(path: source).appending(path: ".claude-plugin/plugin.json"))["version"] ?? .null
        }
        return .null
    }

    public func report() -> JSON {
        let t = now().timeIntervalSince1970
        lock.lock()
        if let cached, t - cached.at < 60, t >= cached.at { lock.unlock(); return cached.data }
        lock.unlock()
        let data = build()
        lock.lock()
        cached = (t, data)
        lock.unlock()
        return data
    }

    private func build() -> JSON {
        let enabled = Self.object(paths.settings)["enabledPlugins"]?.object ?? JSONObject()
        var plugins: [JSONObject] = []
        for (pid, installs) in installedPlugins().pairs {
            guard let first = installs.array?.first, let info = first.object else { continue }
            let name = pid.split(separator: "@", maxSplits: 1).first.map(String.init) ?? pid
            let market = pid.contains("@") ? String(pid[pid.index(after: pid.firstIndex(of: "@")!)...]) : ""
            let latest = marketplaceVersion(market, name)
            let version = info["version"] ?? .null
            let behind = latest.truthy && version.truthy
                && Self.versionTuple(Py.str(version)).lexicographicallyPrecedes(Self.versionTuple(Py.str(latest)))
            let install = info["installPath"].truthy ? Py.str(info["installPath"]!) : ""
            plugins.append(JSONObject([
                "key": .string(pid), "kind": "plugin", "title": .string(name), "source": .string(market),
                "version": version, "latest": latest,
                "status": .string(behind ? "update" : latest.truthy ? "current" : "unknown"),
                "updatedAt": JSON(Epoch.parse(info["lastUpdated"])), "enabled": enabled[pid] ?? .bool(true),
                "skills": .array(Self.skillsIn(URL(filePath: install).appending(path: "skills"))),
            ]))
        }
        plugins = plugins.stableSorted { a, b in
            let ua = a["status"] != "update", ub = b["status"] != "update"
            if ua != ub { return !ua }
            return (a["title"]?.string ?? "").unicodeScalars.lexicographicallyPrecedes((b["title"]?.string ?? "").unicodeScalars)
        }

        var synced: [JSONObject] = []
        let syncedRoot = paths.plugins.appending(path: "synced")
        for account in (try? FileManager.default.contentsOfDirectory(atPath: syncedRoot.path)) ?? [] {
            let accountDir = syncedRoot.appending(path: account, directoryHint: .isDirectory)
            for plugin in (try? FileManager.default.contentsOfDirectory(atPath: accountDir.path)) ?? [] {
                let folder = accountDir.appending(path: plugin, directoryHint: .isDirectory)
                let meta = folder.appending(path: ".claude-plugin/plugin.json")
                guard FileManager.default.fileExists(atPath: meta.path) else { continue }
                let manifest = Self.object(meta)
                synced.append(JSONObject([
                    "key": .string("synced:" + plugin), "kind": "synced",
                    "title": manifest["name"].truthy ? manifest["name"]! : .string(plugin),
                    "version": manifest["version"] ?? .null,
                    "skills": .array(Self.skillsIn(folder.appending(path: "skills"))),
                ]))
            }
        }
        synced = synced.stableSorted {
            Py.str(orEmpty: $0["title"]).unicodeScalars.lexicographicallyPrecedes(Py.str(orEmpty: $1["title"]).unicodeScalars)
        }

        let openclawVersion = Self.object(paths.openclawPackage.appending(path: "package.json"))["version"] ?? .null
        let lock = Self.object(paths.home.appending(path: ".agents/.skill-lock.json"))["skills"]?.object ?? JSONObject()
        var folders: [JSONObject] = []
        let accountRoot = paths.claude.appending(path: "skills/synced")
        for account in (try? FileManager.default.contentsOfDirectory(atPath: accountRoot.path)) ?? [] {
            let dir = accountRoot.appending(path: account, directoryHint: .isDirectory)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            folders.append(JSONObject([
                "key": "account", "kind": "account", "title": "Your Claude account",
                "skills": .array(Self.skillsIn(dir)), "note": "Synced from claude.ai, which keeps them up to date.",
            ]))
        }
        for (label, root) in roots {
            var items = Self.skillsIn(root)
            if items.isEmpty { continue }
            var group = JSONObject(["key": .string(label), "kind": "folder", "title": .string(label)])
            if label.contains("bundled") || label.contains("custodian") {
                group["version"] = openclawVersion
                group["note"] = "These ship with OpenClaw, so they change when OpenClaw itself updates."
            } else if label.contains("OpenClaw") {
                group["note"] = "`Update all` also runs OpenClaw's own updater, which covers skills installed from ClawHub."
            } else {
                group["note"] = "Copied in by hand or by another tool, with no update source Agent Hive can use."
            }
            for n in items.indices {
                guard case .object(var s) = items[n], let name = s["name"]?.string,
                      let tracked = lock[name], tracked.truthy else { continue }
                s["origin"] = tracked["source"] ?? .null
                s["updatedAt"] = JSON(Epoch.parse(tracked["updatedAt"]))
                items[n] = .object(s)
            }
            group["skills"] = .array(items)
            folders.append(group)
        }

        let total = (plugins + synced + folders).reduce(0) { $0 + ($1["skills"]?.array?.count ?? 0) }
        let markets = Self.object(paths.plugins.appending(path: "known_marketplaces.json"))
        let stamps = markets.values.map { Epoch.parse($0["lastUpdated"]) ?? 0 }
        return [
            "total": .int(total), "plugins": .array(plugins.map(JSON.object)), "synced": .array(synced.map(JSON.object)),
            "folders": .array(folders.map(JSON.object)), "marketplacesAt": JSON(stamps.max()),
        ]
    }
}
