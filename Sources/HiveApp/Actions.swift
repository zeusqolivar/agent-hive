import AppKit
import HiveCore

/// Opens sessions in Claude and folders in Finder.
struct WorkspaceActions: ActionHandler {
    func open(hostSessionId: String) -> Bool {
        var parts = URLComponents()
        parts.scheme = "claude"
        parts.host = "code"
        parts.path = "/continue"
        parts.queryItems = [URLQueryItem(name: "session", value: hostSessionId),
                            URLQueryItem(name: "source", value: "desktop_action")]
        guard let url = parts.url else { return false }
        return DispatchQueue.main.sync { NSWorkspace.shared.open(url) }
    }

    func openAntigravity(sessionId: String, cwd: String?) async -> (ok: Bool, message: String) {
        await AntigravityOpener(paths: .current).open(sessionId: sessionId, cwd: cwd)
    }

    func reveal(folder: URL) -> Bool {
        DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        return true
    }
}
