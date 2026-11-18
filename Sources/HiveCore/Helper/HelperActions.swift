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
    /// docs/windows/phase-0-findings.md describes it has none (`AssocQueryString` returns 0x80070483), and the
    /// page already draws its own "can't open" state for a false answer, so this says no rather than guessing.
    public func open(hostSessionId: String) -> Bool {
        #if os(Windows)
        return false
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
        let arguments = "/select,\"\(folder.path)\""
        var opened = false
        arguments.withCString(encodedAs: UTF16.self) { parameters in
            "explorer.exe".withCString(encodedAs: UTF16.self) { program in
                // ShellExecuteW returns a value greater than 32 on success, as an HINSTANCE.
                opened = Int(bitPattern: ShellExecuteW(nil, nil, program, parameters, nil, SW_SHOWNORMAL)) > 32
            }
        }
        return opened
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
}
