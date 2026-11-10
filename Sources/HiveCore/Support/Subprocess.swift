import Foundation

/// Runs a program directly (no shell), with stdin closed and a time limit.
enum Subprocess {
    struct Timeout: Error {}

    struct Output: Sendable {
        var status: Int32
        var stdout: Data
    }

    /// Runs `executable` with `arguments` and returns its exit status and combined output.
    /// Throws `Timeout` and kills the program if it runs longer than `timeout` seconds.
    static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval,
                    environment: [String: String]? = nil, directory: URL? = nil,
                    mergeStderr: Bool = false) throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = directory }
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = mergeStderr ? pipe : FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        let collected = Collected()
        let reader = Thread {
            collected.set(pipe.fileHandleForReading.readDataToEndOfFile())
            collected.finished.signal()
        }
        reader.start()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            kill(process.processIdentifier, SIGKILL)
            _ = done.wait(timeout: .now() + 2)
            throw Timeout()
        }
        _ = collected.finished.wait(timeout: .now() + 5)
        return Output(status: process.terminationStatus, stdout: collected.data)
    }

    private final class Collected: @unchecked Sendable {
        let finished = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var value = Data()
        var data: Data { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ d: Data) { lock.lock(); value = d; lock.unlock() }
    }
}
