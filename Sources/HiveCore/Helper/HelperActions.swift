import Foundation

#if os(Windows)
import WinSDK
#endif

/// The actions the pages can ask for, without a UI framework: the helper is a console program.
///
/// The Mac app opens a URL with `NSWorkspace` and shows a folder in Finder. Here the same three actions are done
/// with the tools the platform has, and each says plainly when it cannot.
public struct HelperActions: ActionHandler {
    public init() {}

    /// Opening a Claude desktop session needs the `claude://` scheme to have a handler. On the PC that
    /// docs/windows/phase-0-findings.md describes it has none (`AssocQueryString` returns 0x80070483), so this
    /// asks Windows anyway — an app update that registers the scheme then works with no change here — and the
    /// page falls back to `openInTerminal`.
    public func open(hostSessionId: String) -> Bool {
        #if os(Windows)
        var parts = URLComponents()
        parts.scheme = "claude"
        parts.host = "code"
        parts.path = "/continue"
        parts.queryItems = [URLQueryItem(name: "session", value: hostSessionId),
                            URLQueryItem(name: "source", value: "desktop_action")]
        guard let url = parts.url?.absoluteString else { return false }
        // ShellExecuteW reports success for a scheme nobody handles — it opens the "how do you want to open
        // this" prompt instead — so the association is checked first.
        guard hasHandler(for: "claude") else { return false }
        return shellOpen(verb: nil, file: url, parameters: nil)
        #else
        // The Mac app does this itself; a headless helper on the Mac still has `open`.
        var parts = URLComponents()
        parts.scheme = "claude"
        parts.host = "code"
        parts.path = "/continue"
        parts.queryItems = [URLQueryItem(name: "session", value: hostSessionId),
                            URLQueryItem(name: "source", value: "desktop_action")]
        guard let url = parts.url else { return false }
        return (try? Subprocess.run(URL(filePath: "/usr/bin/open"), [url.absoluteString], timeout: 5)) != nil
        #endif
    }

    /// Shows a folder in Explorer, or in the Finder.
    public func reveal(folder: URL) -> Bool {
        #if os(Windows)
        // ShellExecuteW, because Explorer wants `/select,"<path>"` with its own quoting.
        return shellOpen(verb: nil, file: "explorer.exe", parameters: "/select,\"\(folder.path)\"")
        #else
        return (try? Subprocess.run(URL(filePath: "/usr/bin/open"), ["-R", folder.path], timeout: 5)) != nil
        #endif
    }

    public func openAntigravity(sessionId: String, cwd: String?) async -> (ok: Bool, message: String) {
        #if os(Windows)
        // Phase 4 adds the Windows launcher: Antigravity.exe, then bringing its window forward.
        return (false, "Not available on Windows yet.")
        #else
        return await AntigravityOpener(paths: .current).open(sessionId: sessionId, cwd: cwd)
        #endif
    }

    #if os(Windows)
    /// Continues a session in a terminal: Windows Terminal if it is there, a console window otherwise, running
    /// `claude --resume <id>` in the session's own folder.
    ///
    /// This is what "Open in Claude" means on Windows while the desktop app has no `claude://` handler. The id is
    /// already limited to `[A-Za-z0-9_-]` by the API's route, and every argument is quoted here as well.
    public func openInTerminal(sessionId: String, cwd: String?) -> Bool {
        guard Patterns.isID(sessionId) else { return false }
        let folder = cwd.flatMap { $0.isEmpty ? nil : $0 } ?? FileManager.default.currentDirectoryPath
        guard let claude = ToolLocator.find("claude", home: FileManager.default.homeDirectoryForCurrentUser,
                                           environment: ProcessInfo.processInfo.environment) else {
            diagnose("no claude command found for the terminal fallback")
            return false
        }
        let resume = "--resume \(sessionId)"
        if shellOpen(verb: nil, file: "wt.exe", parameters: "-d \"\(folder)\" \"\(claude.path)\" \(resume)") {
            return true
        }
        diagnose("wt.exe not available, trying a console window")
        // `start` takes the working directory itself, which avoids a fragile `cd && …` chain.
        return shellOpen(verb: nil, file: "cmd.exe",
                         parameters: "/c start \"\" /D \"\(folder)\" \"\(claude.path)\" \(resume)")
    }

    /// One line on stderr, which the shell saves to its log. Never a key, a path from a transcript or a message.
    private func diagnose(_ message: String) {
        Diagnostics.write("helper action: " + message)
    }

    /// Whether Windows has a program registered for a URL scheme, which is what `AssocQueryStringW` answers.
    private func hasHandler(for scheme: String) -> Bool {
        var size = DWORD(1024)
        var buffer = [WCHAR](repeating: 0, count: Int(size))
        let status = scheme.withCString(encodedAs: UTF16.self) { schemePointer in
            buffer.withUnsafeMutableBufferPointer { out in
                AssocQueryStringW(ASSOCF(0), ASSOCSTR_EXECUTABLE, schemePointer, nil, out.baseAddress, &size)
            }
        }
        return status == S_OK
    }

    /// `ShellExecuteW`, which needs its own quoting rules and reports success as a value above 32.
    private func shellOpen(verb: String?, file: String, parameters: String?) -> Bool {
        var opened = false
        /// `withCString(encodedAs:)` for a pointer that may be nil, which `ShellExecuteW`'s arguments allow.
        func withWide<T>(_ value: String?, _ body: (UnsafePointer<WCHAR>?) -> T) -> T {
            guard let value else { return body(nil) }
            return value.withCString(encodedAs: UTF16.self) { body($0) }
        }
        withWide(file) { filePointer in
            withWide(parameters) { parametersPointer in
                withWide(verb) { verbPointer in
                    let result = ShellExecuteW(nil, verbPointer, filePointer, parametersPointer, nil, SW_SHOWNORMAL)
                    opened = Int(bitPattern: result) > 32
                }
            }
        }
        return opened
    }
    #endif
}
