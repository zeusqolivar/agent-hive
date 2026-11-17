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
        if hasHandler(for: "claude"), shellOpen(verb: nil, file: url, parameters: nil) {
            return true
        }
        // No handler: bring the Claude desktop app forward instead, starting it when it isn't running. That is
        // what "Open in Claude" has to mean here; the terminal resume is the caller's last resort.
        return focusOrLaunchClaudeApp()
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


    #if os(Windows)
    /// The Claude desktop app: brought forward if it is running, started if it isn't, and false only when there
    /// is no app to show — which is when the caller falls back to a terminal.
    ///
    /// The app registers no `claude://` handler on the PC phase 0 measured, so a session cannot be deep-linked.
    /// Focusing the app is the honest version of the same gesture.
    func focusOrLaunchClaudeApp() -> Bool {
        let table = (try? ProcessSources.system().snapshot()) ?? [:]
        let pids = table.values.filter { AgentProcesses.isClaudeDesktop($0.cmd) }.map(\.pid).sorted()
        for pid in pids {
            guard let window = Self.mainWindow(of: DWORD(pid)) else { continue }
            let brought = Self.bringForward(window)
            diagnose(brought ? "brought the Claude app forward" : "the Claude app is up but Windows kept the focus")
            return true
        }
        guard let app = Self.claudeAppExecutable() else {
            diagnose("the Claude desktop app is neither running nor found in WindowsApps")
            return false
        }
        diagnose("starting the Claude desktop app")
        return shellOpen(verb: nil, file: app, parameters: nil)
    }

    /// The window a process owns that a person would call its window: visible, and big enough not to be a
    /// tooltip or a hidden message-only window.
    static func mainWindow(of pid: DWORD) -> HWND? {
        let lookup = WindowLookup(pid: pid)
        let context = Unmanaged.passUnretained(lookup).toOpaque()
        _ = EnumWindows(enumWindows, LPARAM(Int(bitPattern: context)))
        return lookup.found
    }

    /// Puts a window in front. Windows only grants the foreground to the active process, so this tries the plain
    /// call, then attaching to the target's input queue; when both are refused it flashes the taskbar button,
    /// which is what the Mac design settled on as acceptable.
    static func bringForward(_ window: HWND) -> Bool {
        if IsIconic(window) { _ = ShowWindow(window, SW_RESTORE) }
        _ = SetForegroundWindow(window)
        if GetForegroundWindow() == window { return true }

        let owner = GetWindowThreadProcessId(window, nil)
        let current = GetCurrentThreadId()
        if owner != 0, owner != current, AttachThreadInput(current, owner, true) {
            _ = BringWindowToTop(window)
            _ = SetForegroundWindow(window)
            _ = AttachThreadInput(current, owner, false)
            if GetForegroundWindow() == window { return true }
        }
        // Pressing and releasing Alt unlocks the foreground lock Windows keeps for the active process; without
        // it SetForegroundWindow from a background helper is silently ignored.
        keybd_event(BYTE(VK_MENU), 0, 0, 0)
        _ = SetForegroundWindow(window)
        keybd_event(BYTE(VK_MENU), 0, DWORD(KEYEVENTF_KEYUP), 0)
        if GetForegroundWindow() == window { return true }

        SwitchToThisWindow(window, true)
        if GetForegroundWindow() == window { return true }

        var info = FLASHWINFO()
        info.cbSize = UINT(MemoryLayout<FLASHWINFO>.size)
        info.hwnd = window
        info.dwFlags = UINT(FLASHW_ALL) | UINT(FLASHW_TIMERNOFG)
        _ = FlashWindowEx(&info)
        return false
    }

    /// Where the Store build of the Claude app keeps its executable, found by looking rather than by assuming a
    /// version number.
    static func claudeAppExecutable() -> String? {
        let packages = "C:\\Program Files\\WindowsApps"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: packages)) ?? []
        for name in names.sorted(by: >) where name.hasPrefix("Claude_") {
            let candidate = packages + "\\" + name + "\\app\\Claude.exe"
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }
    #endif

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

#if os(Windows)
/// What the `EnumWindows` callback is looking for. A C callback cannot capture, so the state travels through
/// the `LPARAM` argument.
private final class WindowLookup {
    let pid: DWORD
    var found: HWND?

    init(pid: DWORD) {
        self.pid = pid
    }
}

/// Top-level enumeration: stop at the first visible, reasonably sized window owned by the process.
private let enumWindows: WNDENUMPROC = { window, parameter in
    guard let window, let raw = UnsafeMutableRawPointer(bitPattern: Int(parameter)) else { return true }
    let lookup = Unmanaged<WindowLookup>.fromOpaque(raw).takeUnretainedValue()
    var owner: DWORD = 0
    _ = GetWindowThreadProcessId(window, &owner)
    guard owner == lookup.pid, IsWindowVisible(window) else { return true }
    var frame = RECT()
    guard GetWindowRect(window, &frame) else { return true }
    guard frame.right - frame.left >= 300, frame.bottom - frame.top >= 200 else { return true }
    lookup.found = window
    return false
}
#endif
