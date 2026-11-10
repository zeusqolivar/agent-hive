import Foundation

/// Runs `open` and `osascript` for the Antigravity action.
public protocol AppLauncher: Sendable {
    func run(_ program: String, _ arguments: [String])
}

/// The two things the Antigravity action asks of the window's Chrome DevTools endpoint on 127.0.0.1.
public protocol DevToolsClient: Sendable {
    /// One GET (`/json/list`, `/json/activate/<id>`), with a two-second limit.
    func get(_ url: URL) async throws -> Data
    /// Sends `Page.navigate` to `url` over the page's DevTools WebSocket and waits up to two seconds for the answer.
    func navigate(webSocket: URL, to url: String) async throws
}

/// "Open in Antigravity": brings the Antigravity window forward and switches it to the conversation through
/// the Chrome DevTools Protocol, as server.py's `open_antigravity_session` does. It reads only the DevTools port
/// file, the page list and the daemon file's port.
public struct AntigravityOpener: Sendable {
    let paths: HivePaths
    let launcher: AppLauncher
    let devtools: DevToolsClient
    let pidAlive: @Sendable (Int32) -> Bool
    let pause: @Sendable (Double) async -> Void
    let processes: @Sendable () -> [Int32: ProcRecord]

    public init(paths: HivePaths, launcher: AppLauncher = ProcessLauncher(), devtools: DevToolsClient = URLSessionDevTools(),
                pidAlive: @escaping @Sendable (Int32) -> Bool = SessionReader.pidAlive,
                pause: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
                processes: @escaping @Sendable () -> [Int32: ProcRecord] = { (try? PSProcessSource().snapshot()) ?? [:] }) {
        self.paths = paths
        self.launcher = launcher
        self.devtools = devtools
        self.pidAlive = pidAlive
        self.pause = pause
        self.processes = processes
    }

    static let open = ("/usr/bin/open", ["-a", "Antigravity"])

    private func bringForward() { launcher.run(Self.open.0, Self.open.1) }

    private func portFile() -> URL? {
        paths.antigravityDevToolsPorts.first {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && !isDir.boolValue
        }
    }

    struct Failure: Error, CustomStringConvertible { var description: String }

    public func open(sessionId sid: String, cwd: String?) async -> (ok: Bool, message: String) {
        var file = portFile()
        if file == nil {
            bringForward()
            for _ in 0..<8 {
                await pause(0.25)
                file = portFile()
                if file != nil { break }
            }
        }
        guard let file else {
            var isDir: ObjCBool = false
            if let cwd, !cwd.isEmpty, FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue {
                launcher.run(Self.open.0, Self.open.1 + [cwd])
            } else {
                bringForward()
            }
            return (true, "Launched Antigravity.")
        }
        do {
            let first = (try String(contentsOf: file, encoding: .utf8)).components(separatedBy: "\n").first ?? ""
            guard let port = Int(Text.strip(first)) else {
                throw Failure(description: "invalid literal for int() with base 10: \(Py.reprString(Text.strip(first)))")
            }
            let root = "http://127.0.0.1:\(port)"
            let targets = try JSON.parse(try await devtools.get(URL(string: root + "/json/list")!))
            let pages = (targets.array ?? []).filter {
                $0["type"]?.string == "page" && ($0["url"]?.string ?? "").contains("127.0.0.1")
            }
            guard let page = pages.first else {
                bringForward()
                return (true, "Brought Antigravity to front.")
            }
            let pageID = Py.str(page["id"] ?? .null)
            if let activate = URL(string: root + "/json/activate/" + pageID) { _ = try? await devtools.get(activate) }
            let current = page["url"]?.string ?? ""
            if !current.contains("/c/\(sid)"), let socket = page["webSocketDebuggerUrl"]?.string, !socket.isEmpty {
                var base = current.contains("/c/") ? current.components(separatedBy: "/c/")[0]
                    : String((current.components(separatedBy: "?").first ?? "").reversed().drop { $0 == "/" }.reversed())
                if base.isEmpty || !base.contains("127.0.0.1") {
                    guard let hub = AntigravityReader.hub(paths: paths, pidAlive: pidAlive, table: processes()), hub.httpsPort.truthy else {
                        bringForward()
                        return (false, "Brought Antigravity forward, but couldn't find the session's address.")
                    }
                    base = "https://127.0.0.1:\(Py.str(hub.httpsPort))"
                }
                guard let ws = URL(string: socket) else { throw Failure(description: "bad WebSocket address \(socket)") }
                try await devtools.navigate(webSocket: ws, to: "\(base)/c/\(sid)")
            }
            bringForward()
            launcher.run("/usr/bin/osascript", ["-e", "tell application \"Antigravity\" to activate"])
            return (true, "Opened session in Antigravity.")
        } catch {
            bringForward()
            let reason = (error as? Failure)?.description ?? error.localizedDescription
            return (false, "Brought Antigravity forward, but couldn't switch to the session: \(reason)")
        }
    }
}

/// Runs a program with a five-second limit, as server.py's `subprocess.run(..., timeout=5)`.
public struct ProcessLauncher: AppLauncher {
    public init() {}

    public func run(_ program: String, _ arguments: [String]) {
        _ = try? Subprocess.run(URL(filePath: program), arguments, timeout: 5)
    }
}

/// The DevTools endpoint over URLSession, with no cache, cookies or proxies.
public struct URLSessionDevTools: DevToolsClient {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }()

    public init() {}

    public func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        return try await Self.session.data(for: request).0
    }

    public func navigate(webSocket: URL, to url: String) async throws {
        let task = Self.session.webSocketTask(with: webSocket)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        let message: JSON = ["id": 1, "method": "Page.navigate", "params": ["url": .string(url)]]
        try await task.send(.string(String(decoding: message.serialized(), as: UTF8.self)))
        // Wait up to two seconds for the reply; what it says doesn't matter.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await task.receive() }
            group.addTask { try? await Task.sleep(for: .seconds(2)) }
            await group.next()
            task.cancel(with: .normalClosure, reason: nil)
            group.cancelAll()
        }
    }
}
