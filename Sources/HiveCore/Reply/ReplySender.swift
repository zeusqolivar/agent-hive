import Foundation

/// Starts a reply command and reports its exit status and output when it ends.
public protocol ReplyRunner: Sendable {
    func find(_ tool: String) -> URL?
    func start(_ executable: URL, _ args: [String], stdin: Data, environment: [String: String], directory: URL,
               completion: @escaping @Sendable (Int32, String) -> Void) throws
    /// Whether the command-line tool is signed in (`claude auth status --json`).
    func signedIn(_ executable: URL, environment: [String: String]) -> Bool
}

/// Replies to sessions the way spike S1 found safe: only to a session with no running process, by running
/// `claude --resume <id> -p` in the session's folder with the user's own permission settings. Live sessions,
/// sessions another process is resuming, and sessions with a reply already on its way are refused, because
/// two writers fork the conversation.
public final class ReplySender: ReplyPolicy, ReplyHandler, @unchecked Sendable {
    static let liveNote = "This session is running, and replying from here would split its conversation. Open it in Claude to reply."
    static let busyNote = "Another Claude process is using this session right now."
    static let sendingNote = "Your last reply is still being sent."
    static let folderNote = "This session's folder no longer exists, so a reply can't run there."
    static let missingNote = "Replies need the claude command-line tool, which isn't installed where Agent Hive can find it."
    static let signedOutNote = "Replies run the claude command-line tool, which is signed out. Run claude in Terminal, sign in, then try again."
    /// How long a sign-in check is trusted, since the board asks on every refresh.
    static let signInTTL: TimeInterval = 60

    private let paths: HivePaths
    private let runner: ReplyRunner
    private let environment: [String: String]
    private let lock = NSLock()
    private var inFlight = Set<String>()
    private var signInCache: (at: Date, ok: Bool)?

    public init(paths: HivePaths, runner: ReplyRunner = ProcessReplyRunner(),
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = paths
        self.runner = runner
        self.environment = environment
    }

    /// The exact arguments after `claude`. The text goes on stdin, so nothing the user types can be read
    /// as a command-line flag.
    static func arguments(sessionId: String) -> [String] {
        ["--resume", sessionId, "-p", "--output-format", "json"]
    }

    /// A signed-out reply still writes the message and an error into the session, so check before offering
    /// or sending one. `fresh` skips the cache.
    func isSignedIn(_ claude: URL, fresh: Bool) -> Bool {
        if !fresh, let cached = lock.withLock({ signInCache }), Date().timeIntervalSince(cached.at) < Self.signInTTL {
            return cached.ok
        }
        let ok = runner.signedIn(claude, environment: commandEnvironment())
        lock.withLock { signInCache = (Date(), ok) }
        return ok
    }

    func commandEnvironment() -> [String: String] {
        var env = environment.filter { !$0.key.hasPrefix("CLAUDE") }
        env["PATH"] = [paths.home.path + "/.local/bin", "/opt/homebrew/bin", env["PATH"] ?? "/usr/bin:/bin"]
            .joined(separator: ":")
        return env
    }

    static func resumes(_ cmd: String, _ id: String) -> Bool {
        cmd.contains("--resume \(id)") || cmd.contains("--resume=\(id)") || cmd.contains("-r \(id)")
    }

    public func canReply(_ row: BoardRow, processes: [Int32: ProcRecord]) -> (allowed: Bool, note: String?) {
        if row.provider != nil { return (false, nil) }    // Antigravity conversations aren't Claude sessions
        if row.live { return (false, Self.liveNote) }
        if processes.values.contains(where: { Self.resumes($0.cmd, row.id) }) { return (false, Self.busyNote) }
        if lock.withLock({ inFlight.contains(row.id) }) { return (false, Self.sendingNote) }
        var isDir: ObjCBool = false
        guard let cwd = row.cwd, FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            return (false, Self.folderNote)
        }
        guard let claude = runner.find("claude") else { return (false, Self.missingNote) }
        if !isSignedIn(claude, fresh: false) { return (false, Self.signedOutNote) }
        return (true, nil)
    }

    /// `POST /api/reply`: 404 for a session not on the board, 409 when it can't take a reply, 400 for empty
    /// text, 202 once the command has started.
    public func reply(sessionId: String, text: String, state: BoardState) async -> (status: Int, body: JSON) {
        guard let row = state.row(sessionId) else { return (404, ["error": "This session is no longer on the board."]) }
        let verdict = canReply(row, processes: state.processes)
        guard verdict.allowed else { return (409, ["error": .string(verdict.note ?? "This session can't take a reply.")]) }
        guard !Text.strip(text).isEmpty else { return (400, ["error": "Type a reply first."]) }
        guard let claude = runner.find("claude"), let cwd = row.cwd else { return (409, ["error": .string(Self.missingNote)]) }
        guard isSignedIn(claude, fresh: true) else { return (409, ["error": .string(Self.signedOutNote)]) }
        let claimed = lock.withLock { inFlight.insert(row.id).inserted }
        guard claimed else { return (409, ["error": .string(Self.sendingNote)]) }

        let env = commandEnvironment()
        let id = row.id
        do {
            try runner.start(claude, Self.arguments(sessionId: id), stdin: Data(text.utf8), environment: env,
                             directory: URL(filePath: cwd, directoryHint: .isDirectory)) { [weak self] _, _ in
                _ = self?.lock.withLock { self?.inFlight.remove(id) }
            }
        } catch {
            _ = lock.withLock { inFlight.remove(id) }
            return (500, ["error": .string("Couldn't start claude: \(error.localizedDescription)")])
        }
        return (202, ["ok": true, "message": "Sent. Claude's answer shows in the timeline when it finishes."])
    }
}

/// Runs reply commands as real processes, with a 30-minute limit.
public struct ProcessReplyRunner: ReplyRunner {
    public static let timeout: TimeInterval = 30 * 60

    public init() {}

    public func find(_ tool: String) -> URL? { ProcessJobRunner().find(tool) }

    public func start(_ executable: URL, _ args: [String], stdin: Data, environment: [String: String], directory: URL,
                      completion: @escaping @Sendable (Int32, String) -> Void) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.environment = environment
        process.currentDirectoryURL = directory
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        let collected = OutputBox()
        output.fileHandleForReading.readabilityHandler = { handle in collected.append(handle.availableData) }
        process.terminationHandler = { p in
            output.fileHandleForReading.readabilityHandler = nil
            completion(p.terminationStatus, collected.text)
        }
        try process.run()
        input.fileHandleForWriting.write(stdin)
        try? input.fileHandleForWriting.close()
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout) {
            if process.isRunning { process.terminate() }
        }
    }

    public func signedIn(_ executable: URL, environment: [String: String]) -> Bool {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["auth", "status", "--json"]
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return false }
        if done.wait(timeout: .now() + 15) == .timedOut {
            process.terminate()
            return false
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let status = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return status?["loggedIn"] as? Bool == true
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ d: Data) { lock.withLock { if data.count < 1_000_000 { data.append(d) } } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }
}
