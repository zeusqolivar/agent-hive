import Foundation
import HiveCore
#if os(Windows)
import WinSDK
#endif

// `hive-core`: HiveCore without a UI.
//
// With no arguments it answers the pages' `/api/...` requests over stdin and stdout, one JSON line in and one
// JSON line out. Requests are answered concurrently and may come back out of order; only the writes to stdout
// are serialised. Nothing but answers goes to stdout — logs go to stderr, which the shell saves to a file.
//
//   hive-core --dump /api/board /api/limits   one refresh, print each answer, exit
//   hive-core --post /api/classroom '{...}'   one POST after one refresh
//   hive-core --version                       the app's version
//   hive-core --web <folder>                  the pages, instead of finding them

/// Logs to stderr, never to stdout, and never with a key, a request body or a response body in it.
///
/// On Windows this writes to the handle directly: Foundation's standard-error file handle reaches a console but
/// not a redirected file, and the shell redirects it to `%APPDATA%\Agent Hive\logs\hive-core.log`.
func log(_ message: String) {
    Diagnostics.write(message)
}

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--version") {
    print(HiveVersion.value)
    exit(0)
}

/// The pages: `--web`, then a `web` folder beside the executable, then the repository's own copy so `swift run`
/// works while developing. The shell passes its bundled folder in phase 3.
func pagesFolder() -> URL? {
    if let i = arguments.firstIndex(of: "--web"), i + 1 < arguments.count {
        return URL(filePath: arguments[i + 1], directoryHint: .isDirectory)
    }
    let executable = URL(filePath: CommandLine.arguments[0]).deletingLastPathComponent()
    let beside = executable.appending(path: "web", directoryHint: .isDirectory)
    if FileManager.default.fileExists(atPath: beside.path) { return beside }
    var folder = executable
    for _ in 0..<6 {
        let candidate = folder.appending(path: "Sources/HiveApp/Resources/web", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        folder = folder.deletingLastPathComponent()
    }
    return nil
}

let pages = pagesFolder()
if pages == nil {
    log("hive-core: no web folder found; the pages won't be served (pass --web <folder>)")
}

/// One POST or nothing, after one refresh: `--post <path> <json>`, or `--dump <path>...`.
func runOnce(_ work: @escaping @Sendable (HiveServices) async -> Void) -> Never {
    let services = HiveServices(actions: HelperActions(), pages: pages, start: false)
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        let started = Date()
        await services.board.refresh()
        log(String(format: "board refresh: %.2fs", Date().timeIntervalSince(started)))
        await work(services)
        done.signal()
    }
    done.wait()
    exit(0)
}

if arguments.contains("--dump") {
    guard let i = arguments.firstIndex(of: "--dump") else { exit(0) }
    let paths = Array(arguments[(i + 1)...]).filter { $0.hasPrefix("/") }
    runOnce { services in
        if paths.contains("/api/usage") { services.usage.scan() }
        for path in paths {
            let response = await services.api.handle(method: "GET", path: path, body: nil)
            FileHandle.standardOutput.write(response.body)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }
}

if let i = arguments.firstIndex(of: "--post"), i + 2 < arguments.count {
    let path = arguments[i + 1]
    let body = Data(arguments[i + 2].utf8)
    runOnce { services in
        let response = await services.api.handle(method: "POST", path: path, body: body)
        print("\(response.status) \(response.contentType)")
        FileHandle.standardOutput.write(response.body)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

// The pipe. Started with the refresh loops as the Mac app starts them.
let services = HiveServices(actions: HelperActions(), pages: pages, start: true)



/// Serialises the answers: each Task may finish in any order, but a line is written whole.
actor AnswerWriter {
    private let handle = FileHandle.standardOutput

    func write(_ answer: HelperFraming.Answer) {
        do {
            try handle.write(contentsOf: HelperFraming.encode(answer))
        } catch {
            // A closed pipe means the shell has gone; there is nobody to answer.
            log("hive-core: couldn't write an answer: \(error.localizedDescription)")
        }
    }
}

let writer = AnswerWriter()
let outstanding = DispatchGroup()

/// Answers one line. A malformed line is answered with 400 and the helper keeps going.
func answer(_ line: Data) {
    switch HelperFraming.decode(line) {
    case .failure(let failure):
        outstanding.enter()
        Task {
            await writer.write(HelperFraming.refusal(for: failure))
            outstanding.leave()
        }
    case .success(let request):
        outstanding.enter()
        Task {
            // The first board takes a couple of seconds. Waiting here — in a request's own task, never on the
            // main thread, which would starve the refresh loop on Windows — is what keeps a page's first
            // question from being answered with an empty board.
            await services.board.waitUntilReady()
            let response = await services.api.handle(method: request.method, path: request.path, body: request.body)
            await writer.write(HelperFraming.Answer(id: request.id, status: response.status,
                                                    contentType: response.contentType, body: response.body))
            outstanding.leave()
        }
    }
}

/// Reads one block from standard input, waiting until there is something or the pipe closes. Nil at EOF.
///
/// On Windows this goes through `ReadFile`: Foundation's `FileHandle.read(upToCount:)` throws when stdin is a
/// redirected file (the shell's own piping works, but a file does not), and `availableData` reports an empty
/// read as end-of-file, which silently dropped every request in a redirected file.
func readStandardInput(_ buffer: inout [UInt8]) -> Int? {
    #if os(Windows)
    let handle = GetStdHandle(STD_INPUT_HANDLE)
    var read: DWORD = 0
    let ok = buffer.withUnsafeMutableBytes { raw in
        ReadFile(handle, raw.baseAddress, DWORD(raw.count), &read, nil)
    }
    guard ok, read > 0 else { return nil }
    return Int(read)
    #else
    let chunk = try? FileHandle.standardInput.read(upToCount: buffer.count)
    guard let chunk, !chunk.isEmpty else { return nil }
    buffer.replaceSubrange(0..<chunk.count, with: chunk)
    return chunk.count
    #endif
}

log("hive-core \(HiveVersion.value): reading requests on stdin")
var reader = LineReader()
var block = [UInt8](repeating: 0, count: 64 * 1024)
while let read = readStandardInput(&block) {
    for line in reader.feed(Data(block[0..<read])) { answer(line) }
}
if let last = reader.flush() { answer(last) }

// The shell is gone: let answers that are already running finish, then stop the refresh loops by exiting.
if outstanding.wait(timeout: .now() + 1) == .timedOut {
    log("hive-core: stdin closed with requests still running; exiting anyway")
}
log("hive-core: stdin closed, exiting")
exit(0)
