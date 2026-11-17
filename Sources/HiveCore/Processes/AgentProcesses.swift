import Foundation

/// Recognising the agents' own processes, on either system.
///
/// macOS names them by app bundle (`/Applications/Antigravity.app/Contents/MacOS/…`). Windows has no bundles:
/// the same agents run from `WindowsApps`, `%LOCALAPPDATA%\Programs` and `%USERPROFILE%`, and the executable
/// names it shares are ambiguous (`claude.exe` is both the CLI and the desktop app's helpers; any `node.exe`
/// may be an unrelated tool). Both sets of patterns are checked everywhere: a Mac command line never matches a
/// Windows pattern or the other way round, and one set of tests can describe both.
///
/// Kept in one place so `SystemReport`, `MacSummary` and `AntigravityReader` answer the same way, and so the
/// Windows patterns are reviewable in one list.
public enum AgentProcesses {
    /// The Claude Code session or CLI, however it was installed.
    public static func isClaudeCode(_ cmd: String) -> Bool {
        matchesAny(cmd, [
            // macOS: the app bundle, the native installer's ~/.local/bin, or npx.
            #"/claude\.app/Contents/MacOS/claude(\s|$)|\.local/bin/claude(\s|$)|@anthropic-ai/claude-code"#,
            // Windows: the desktop app's own copy under %LOCALAPPDATA%\Claude-Data, the installer's
            // %USERPROFILE%\.local\bin, or npx.
            #"\\Claude-Data\\claude_[^\\]+\\claude-code\\|\\\.local\\bin\\claude\.exe|@anthropic-ai[/\\]claude-code"#,
        ])
    }

    /// The Claude desktop app itself, not the chromium helpers it spawns.
    public static func isClaudeDesktop(_ cmd: String) -> Bool {
        matchesAny(cmd, [
            #"/Applications/Claude\.app/Contents/MacOS/Claude(\s|$)"#,
            // The Store build lives in WindowsApps; its helpers all pass --type=, so they are excluded below.
            #"\\WindowsApps\\Claude_[\d.]+_x64__[^\\]+\\app\\Claude\.exe"#,
        ]) && !isHelperProcess(cmd)
    }

    /// Chromium's renderer, GPU, utility and crash-handler children. They repeat the parent's executable path,
    /// so they must not be counted as apps.
    public static func isHelperProcess(_ cmd: String) -> Bool {
        matchesAny(cmd, [#"--type=(renderer|gpu-process|utility|crashpad-handler|zygote)"#])
    }

    /// The Antigravity app window: the Mac bundle or the Windows folder.
    public static func isAntigravityApp(_ cmd: String) -> Bool {
        matchesAny(cmd, [
            #"/Applications/Antigravity\.app/Contents/MacOS/Antigravity(\s|$)"#,
            #"\\Programs\\antigravity\\Antigravity\.exe"#,
        ]) && !isHelperProcess(cmd)
    }

    /// Antigravity's language server, which owns the hub the app talks to.
    public static func isAntigravityLanguageServer(_ cmd: String) -> Bool {
        matchesAny(cmd, [
            #"/Applications/Antigravity\.app/Contents/Resources/bin/language_server(\s|$)"#,
            #"\\antigravity\\resources\\bin\\language_server\.exe"#,
        ])
    }

    /// Either half of Antigravity.
    public static func isAntigravity(_ cmd: String) -> Bool {
        isAntigravityApp(cmd) || isAntigravityLanguageServer(cmd)
    }

    /// `agy --hub`, the command-line hub Antigravity's own tooling starts.
    public static func isAntigravityHubCLI(_ cmd: String) -> Bool {
        matchesAny(cmd, [#"(^|[\\/])agy(\.exe)?\s.*--hub\b"#])
    }

    /// The name the System view shows, for the agents whose processes span several executables.
    public static func label(_ cmd: String) -> String? {
        if isAntigravityLanguageServer(cmd) { return "Google Antigravity language server" }
        if isAntigravityApp(cmd) { return "Google Antigravity" }
        if isClaudeDesktop(cmd) { return "Claude desktop app" }
        if isClaudeCode(cmd) { return "Claude Code" }
        if matchesAny(cmd, [#"\\Programs\\cursor\\Cursor\.exe"#]) { return "Cursor" }
        if matchesAny(cmd, [#"(^|[\\/])codex(\.exe)?(\s|$)|codex-cli"#]) { return "Codex" }
        if matchesAny(cmd, [#"openclaw[\\/]dist[\\/]index\.js gateway"#]) { return "OpenClaw gateway" }
        return nil
    }

    private static func matchesAny(_ text: String, _ patterns: [String]) -> Bool {
        patterns.contains { pattern in
            guard let regex = cache.regex(pattern) else { return false }
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }

    private static let cache = RegexCache()
}

/// Compiled regular expressions, built once. `NSRegularExpression` is immutable, so sharing them is safe.
private final class RegexCache: @unchecked Sendable {
    private let lock = NSLock()
    private var compiled: [String: NSRegularExpression] = [:]

    func regex(_ pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = compiled[pattern] { return hit }
        guard let made = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        compiled[pattern] = made
        return made
    }
}
