import Foundation

public enum StatusLineError: Error, Equatable, Sendable {
    /// `~/.claude/settings.json` isn't a JSON object, so it's left alone.
    case unreadableSettings
}

/// Sets up and removes the opt-in Claude status line script that saves plan limits.
///
/// - Install writes `statusline.sh` and `statusline-previous.json` to Agent Hive's folder, then points
///   `statusLine` in `~/.claude/settings.json` at the script. The previous status line command, if any, is
///   written into the script, which runs it with the same input and prints its output unchanged.
/// - Only the `statusLine` value's text changes in settings.json; every other byte is kept. Remove puts the
///   previous text back exactly, or deletes the key if there was none. If something else rewrote the file in
///   the meantime, Remove changes only the `statusLine` key and keeps the rest; if something else replaced the
///   status line, Remove leaves settings.json alone.
/// - The file is written atomically, through a symbolic link if settings.json is one.
public struct StatusLineInstaller: Sendable {
    let paths: HivePaths

    public init(paths: HivePaths) {
        self.paths = paths
    }

    /// The `command` the status line runs: the script's path, quoted for the shell.
    var command: String { Self.shellQuote(paths.statusLineScript.path) }

    public var isInstalled: Bool {
        guard let data = FileManager.default.contents(atPath: paths.settings.path), let json = try? JSON.parse(data)
        else { return false }
        return json["statusLine"]?["command"]?.string == command
    }

    public func install() throws {
        if isInstalled { return }
        let fm = FileManager.default
        let target = settingsTarget
        let original = fm.contents(atPath: target.path)
        let text = original.map { String(decoding: $0, as: UTF8.self) } ?? "{}\n"
        guard let parsed = try? JSON.parse(text), parsed.object != nil, let top = Self.members(text) else {
            throw StatusLineError.unreadableSettings
        }
        let previous = parsed["statusLine"]
        var mine = JSONObject(["type": "command", "command": .string(command)])
        if let padding = previous?["padding"], padding.number != nil { mine["padding"] = padding }
        let mineText = JSON.object(mine).serializedString

        var record = JSONObject(["installed": .string(mineText)])
        let newText: String
        if let existing = top.members.first(where: { $0.key == "statusLine" }) {
            record["previous"] = .string(String(text[existing.value]))
            newText = text.replacingCharacters(in: existing.value, with: mineText)
        } else if let last = top.members.last {
            newText = text.replacingCharacters(in: last.value.upperBound..<last.value.upperBound,
                                               with: ",\n  \"statusLine\": " + mineText)
        } else {
            record["emptyInner"] = .string(String(text[top.inner]))
            newText = text.replacingCharacters(in: top.inner, with: "\n  \"statusLine\": " + mineText + "\n")
        }
        let previousCommand = previous?["type"]?.string == "command" ? previous?["command"]?.string : nil

        try fm.createDirectory(at: paths.supportFolder, withIntermediateDirectories: true)
        try Data(Self.script(support: paths.supportFolder, previous: previousCommand).utf8)
            .write(to: paths.statusLineScript, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.statusLineScript.path)
        try JSON.object(record).serialized(indent: 2).write(to: paths.statusLinePrevious, options: .atomic)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(newText.utf8).write(to: target, options: .atomic)
    }

    public func remove() throws {
        let fm = FileManager.default
        defer {
            try? fm.removeItem(at: paths.statusLineScript)
            try? fm.removeItem(at: paths.statusLinePrevious)
        }
        let target = settingsTarget
        guard isInstalled, let data = fm.contents(atPath: target.path) else { return }
        let text = String(decoding: data, as: UTF8.self)
        let record = (fm.contents(atPath: paths.statusLinePrevious.path)).flatMap { try? JSON.parse($0) }
        let previousText = record?["previous"]?.string
        let installedText = record?["installed"]?.string

        // Untouched since install: undo the text edit exactly.
        if let top = Self.members(text), let i = top.members.firstIndex(where: { $0.key == "statusLine" }),
           String(text[top.members[i].value]) == installedText {
            let member = top.members[i]
            var restored: String?
            if let previousText {
                restored = text.replacingCharacters(in: member.value, with: previousText)
            } else if top.members.count == 1 {
                restored = text.replacingCharacters(in: top.inner, with: record?["emptyInner"]?.string ?? "")
            } else if i > 0 {
                restored = text.replacingCharacters(in: top.members[i - 1].value.upperBound..<member.value.upperBound,
                                                    with: "")
            }
            if let restored, (try? JSON.parse(restored))?.object != nil {
                try Data(restored.utf8).write(to: target, options: .atomic)
                return
            }
        }
        // Rewritten by something else: change only the statusLine key.
        guard case .object(var o) = try JSON.parse(data) else { return }
        o["statusLine"] = previousText.flatMap { try? JSON.parse($0) }
        try JSON.object(o).serialized(indent: 2).write(to: target, options: .atomic)
    }

    /// settings.json, or the file it links to.
    var settingsTarget: URL { paths.settings.resolvingSymlinksInPath() }

    // MARK: - The script

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func script(support: URL, previous: String?) -> String {
        """
        #!/bin/sh
        # Agent Hive status line, set up from Agent Hive's Settings. It saves the plan limits Claude Code passes
        # on stdin (the rate_limits object only) to claude-limits.json, then runs the status line you had before,
        # if any, with the same input, and prints its output. Remove it in Agent Hive's Settings to put your
        # previous status line back.
        dir=\(shellQuote(support.path))
        previous=\(shellQuote(previous ?? ""))
        input=$(cat)
        limits=$(printf '%s' "$input" | /usr/bin/plutil -extract rate_limits json -o - - 2>/dev/null)
        case "$limits" in
          '{'*)
            tmp="$dir/.claude-limits.$$.tmp"
            printf '{"savedAt": %s, "rate_limits": %s}\\n' "$(/bin/date +%s)" "$limits" > "$tmp" \\
              && /bin/mv -f "$tmp" "$dir/claude-limits.json"
            ;;
        esac
        if [ -n "$previous" ]; then
          printf '%s' "$input" | /bin/sh -c "$previous"
        fi

        """
    }

    // MARK: - Top-level members of a JSON object, as text ranges

    struct Member {
        var key: String
        var value: Range<String.Index>
    }

    /// The top-level object's members with each value's range, and the range between its braces. Nil when the
    /// text isn't a single object. Assumes the text already parsed as JSON.
    static func members(_ text: String) -> (members: [Member], inner: Range<String.Index>)? {
        let u = Array(text.utf8)
        var i = 0
        func space() { while i < u.count, [0x20, 0x09, 0x0A, 0x0D].contains(u[i]) { i += 1 } }
        func skipString() -> Bool {
            guard i < u.count, u[i] == 0x22 else { return false }
            i += 1
            while i < u.count {
                if u[i] == 0x5C { i += 2; continue }
                if u[i] == 0x22 { i += 1; return true }
                i += 1
            }
            return false
        }
        func skipValue() -> Bool {
            guard i < u.count else { return false }
            if u[i] == 0x22 { return skipString() }
            if u[i] == 0x7B || u[i] == 0x5B {
                var depth = 0
                while i < u.count {
                    switch u[i] {
                    case 0x22: if !skipString() { return false }; continue
                    case 0x7B, 0x5B: depth += 1
                    case 0x7D, 0x5D:
                        depth -= 1
                        if depth == 0 { i += 1; return true }
                    default: break
                    }
                    i += 1
                }
                return false
            }
            while i < u.count, ![0x2C, 0x7D, 0x5D, 0x20, 0x09, 0x0A, 0x0D].contains(u[i]) { i += 1 }
            return true
        }
        func index(_ offset: Int) -> String.Index { text.utf8.index(text.utf8.startIndex, offsetBy: offset) }

        space()
        guard i < u.count, u[i] == 0x7B else { return nil }
        i += 1
        let innerStart = i
        var members: [Member] = []
        space()
        if i < u.count, u[i] == 0x7D {
            return ([], index(innerStart)..<index(i))
        }
        while i < u.count {
            space()
            let keyStart = i
            guard skipString() else { return nil }
            let keyData = Data(u[keyStart..<i])
            guard let key = (try? JSON.parse(keyData))?.string else { return nil }
            space()
            guard i < u.count, u[i] == 0x3A else { return nil }
            i += 1
            space()
            let valueStart = i
            guard skipValue() else { return nil }
            members.append(Member(key: key, value: index(valueStart)..<index(i)))
            space()
            guard i < u.count else { return nil }
            if u[i] == 0x2C { i += 1; continue }
            if u[i] == 0x7D { return (members, index(innerStart)..<index(i)) }
            return nil
        }
        return nil
    }
}
