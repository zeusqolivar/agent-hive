import Foundation

/// Runs one program for a skills job, passing each output line to `line`, and returns its exit status.
public protocol JobRunner: Sendable {
    func find(_ tool: String) -> URL?
    func run(_ executable: URL, _ args: [String], environment: [String: String], directory: URL,
             timeout: TimeInterval, line: (String) -> Void) -> Int32
}

/// The skills check and update jobs: fixed argument lists, no shell, stdin closed, five minutes per
/// command, `CLAUDE*` variables removed, one job at a time. Nothing that needs a person's confirmation is
/// ever passed (`-y`, `--force`), so such a step fails and shows in the log.
public final class SkillsJobs: @unchecked Sendable {
    public static let timeout: TimeInterval = 300

    private let paths: HivePaths
    private let runner: JobRunner
    private let environment: [String: String]
    private let onFinish: @Sendable () -> Void
    private let lock = NSLock()
    private var running = false
    private var label: String?
    private var log: [String] = []
    private var startedAt: Int?
    private var finishedAt: Int?
    private var ok: Bool?

    public init(paths: HivePaths, runner: JobRunner = ProcessJobRunner(),
                environment: [String: String] = ProcessInfo.processInfo.environment,
                onFinish: @escaping @Sendable () -> Void = {}) {
        self.paths = paths
        self.runner = runner
        self.environment = environment
        self.onFinish = onFinish
    }

    /// The `job` object of `/api/skills`.
    public func status() -> JSON {
        lock.lock()
        defer { lock.unlock() }
        return ["running": .bool(running), "label": JSON(label), "log": .array(log.map(JSON.string)),
                "startedAt": JSON(startedAt), "finishedAt": JSON(finishedAt), "ok": JSON(ok)]
    }

    /// `POST /api/skills/run`.
    public func start(action: String?, plugin: String?) -> (status: Int, body: Data) {
        let refresh = ["claude", "plugin", "marketplace", "update"]
        let plugins = SkillsReader(paths: paths).installedPlugins()
        let label: String
        var steps: [[String]]
        switch action {
        case "check":
            label = "Checking for updates"
            steps = [refresh]
        case "update-all":
            label = "Updating everything"
            steps = [refresh] + SkillsReader.pySorted(plugins.keys).map { ["claude", "plugin", "update", $0] }
            steps.append(["openclaw", "skills", "update", "--all"])
        case "update" where plugin.map { plugins[$0] != nil } == true:
            label = "Updating " + (plugin!.split(separator: "@", maxSplits: 1).first.map(String.init) ?? plugin!)
            steps = [refresh, ["claude", "plugin", "update", plugin!]]
        default:
            return (400, JSON.object(JSONObject(["error": "Unknown update request."])).serialized())
        }
        lock.lock()
        if running {
            lock.unlock()
            return (409, JSON.object(JSONObject(["error": "An update is already running."])).serialized())
        }
        running = true
        self.label = label
        log = []
        startedAt = Int(Date().timeIntervalSince1970)
        finishedAt = nil
        ok = nil
        lock.unlock()
        Thread.detachNewThread { [self] in run(steps) }
        return (200, JSON.object(JSONObject(["ok": true, "message": .string(label + ".")])).serialized())
    }

    private func append(_ line: String) {
        var text = Patterns.stripANSI(line)
        while text.hasSuffix("\n") { text.removeLast() }
        lock.lock()
        log.append(Text.prefix(text, 2000))
        if log.count > 1500 { log.removeFirst(log.count - 1500) }
        lock.unlock()
    }

    private func run(_ steps: [[String]]) {
        var env = environment.filter { !$0.key.hasPrefix("CLAUDE") }
        let home = paths.home.path
        env["PATH"] = [home + "/.local/bin", "/opt/homebrew/bin", env["PATH"] ?? ""].joined(separator: ":")
        var allOK = true
        for argv in steps {
            append("$ " + argv.map(Shell.quote).joined(separator: " "))
            guard let tool = runner.find(argv[0]) else {
                append("\(argv[0]) isn't installed where Agent Hive can find it.")
                allOK = false
                continue
            }
            let code = runner.run(tool, Array(argv.dropFirst()), environment: env, directory: paths.home,
                                  timeout: Self.timeout, line: append)
            append(code != 0 ? "Finished with exit code \(code)." : "Done.")
            append("")
            allOK = allOK && code == 0
        }
        lock.lock()
        running = false
        finishedAt = Int(Date().timeIntervalSince1970)
        ok = allOK
        lock.unlock()
        onFinish()
    }
}

/// Runs job steps as real processes.
public struct ProcessJobRunner: JobRunner {
    public init() {}

    public func find(_ tool: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let dirs = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"] + path.split(separator: ":").map(String.init)
        for dir in dirs where !dir.isEmpty {
            let candidate = URL(filePath: dir).appending(path: tool)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    public func run(_ executable: URL, _ args: [String], environment: [String: String], directory: URL,
                    timeout: TimeInterval, line: (String) -> Void) -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch {
            line(error.localizedDescription)
            return 1
        }
        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        timer.resume()
        var buffer = Data()
        let reader = pipe.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                line(String(decoding: buffer[..<nl], as: UTF8.self))
                buffer = Data(buffer[(nl + 1)...])
            }
        }
        if !buffer.isEmpty { line(String(decoding: buffer, as: UTF8.self)) }
        process.waitUntilExit()
        timer.cancel()
        return process.terminationReason == .uncaughtSignal ? -Int32(process.terminationStatus) : process.terminationStatus
    }
}
