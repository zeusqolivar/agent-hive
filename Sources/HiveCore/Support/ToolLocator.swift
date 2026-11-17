import Foundation

/// Finding a command-line tool, and running it, on either system.
///
/// macOS installs these tools in `~/.local/bin` or Homebrew and names them without an extension. Windows has
/// `%USERPROFILE%\.local\bin` for Claude Code's native installer, `%APPDATA%\npm` for npm's shims, an extension
/// per kind of program (`.exe`, `.cmd`, `.bat`), and a `PATH` separated by `;` because drive letters contain `:`.
public enum ToolLocator {
    /// Where a tool may be, before `PATH` itself. `PATH` alone is not enough: a GUI app does not inherit the
    /// shell's additions, so the usual install folders are searched first.
    public static func folders(home: URL, environment: [String: String]) -> [URL] {
        #if os(Windows)
        let appData = home.appending(path: "AppData/Roaming", directoryHint: .isDirectory)
        return [
            home.appending(path: ".local/bin", directoryHint: .isDirectory),
            appData.appending(path: "npm", directoryHint: .isDirectory),
        ] + (environment["Path"] ?? environment["PATH"] ?? "").split(separator: ";").map {
            URL(filePath: String($0), directoryHint: .isDirectory)
        }
        #else
        return [
            home.appending(path: ".local/bin", directoryHint: .isDirectory),
            URL(filePath: "/opt/homebrew/bin", directoryHint: .isDirectory),
            URL(filePath: "/usr/local/bin", directoryHint: .isDirectory),
        ] + (environment["PATH"] ?? "").split(separator: ":").map {
            URL(filePath: String($0), directoryHint: .isDirectory)
        }
        #endif
    }

    /// The `PATH` value the tool should be run with: the same folders, in the same order, joined properly.
    public static func pathValue(home: URL, environment: [String: String]) -> String {
        let existing = environment["PATH"] ?? ""
        let own = folders(home: home, environment: [:]).map(\.path)
        #if os(Windows)
        return (own + [existing]).filter { !$0.isEmpty }.joined(separator: ";")
        #else
        return (own + [existing.isEmpty ? "/usr/bin:/bin" : existing]).joined(separator: ":")
        #endif
    }

    /// The names a tool may have on this system, in the order to try.
    public static func names(_ tool: String) -> [String] {
        #if os(Windows)
        let lower = tool.lowercased()
        if [".exe", ".cmd", ".bat", ".com"].contains(where: lower.hasSuffix) { return [tool] }
        return [tool + ".exe", tool + ".cmd", tool + ".bat", tool]
        #else
        return [tool]
        #endif
    }

    /// The first path that holds an executable with that name.
    public static func find(_ tool: String, home: URL, environment: [String: String]) -> URL? {
        for folder in folders(home: home, environment: environment) {
            for name in names(tool) {
                let candidate = folder.appending(path: name, directoryHint: .notDirectory)
                if isRunnable(candidate) { return candidate }
            }
        }
        return nil
    }

    /// Whether a file can be run. `FileManager.isExecutableFile` answers for `.exe` on Windows and for the
    /// executable bit on macOS; batch files carry no executable bit on Windows, so their extension decides.
    public static func isRunnable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        #if os(Windows)
        let lower = url.pathExtension.lowercased()
        return ["exe", "cmd", "bat", "com"].contains(lower)
        #else
        return FileManager.default.isExecutableFile(atPath: url.path)
        #endif
    }

    /// The program to start, and the arguments, for a tool that may be a batch file.
    ///
    /// Windows cannot start a `.cmd` or `.bat` directly: it needs `cmd.exe /d /s /c`. The arguments are passed as
    /// separate arguments rather than spliced into a command string, so nothing in them is interpreted.
    public static func invocation(_ tool: URL, _ arguments: [String]) -> (executable: URL, arguments: [String]) {
        #if os(Windows)
        let lower = tool.pathExtension.lowercased()
        if lower == "cmd" || lower == "bat" {
            let command = URL(filePath: (ProcessInfo.processInfo.environment["COMSPEC"] ?? "cmd.exe"),
                              directoryHint: .notDirectory)
            return (command, ["/d", "/s", "/c", tool.path] + arguments)
        }
        #endif
        return (tool, arguments)
    }
}
