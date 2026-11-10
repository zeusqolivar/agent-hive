import Foundation
import HiveCore
import ServiceManagement

/// `HiveApp --dump <path>...` prints what the API answers for each path after one board refresh and
/// usage scan, then exits. For comparing the app with the local server while developing.
enum Dump {
    static func runIfAsked() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--login-item"), i + 1 < args.count {
            loginItem(args[i + 1])
        }
        if let i = args.firstIndex(of: "--post"), i + 2 < args.count { post(args[i + 1], args[i + 2]) }
        guard let i = args.firstIndex(of: "--dump") else { return }
        let paths = Array(args[(i + 1)...])
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let services = Services.make(start: false)
            let started = Date()
            await services.board.refresh()
            FileHandle.standardError.write(Data("board refresh: \(Date().timeIntervalSince(started))s\n".utf8))
            if paths.contains("/api/usage") { services.usage.scan() }
            for path in paths {
                let r = await services.api.handle(method: "GET", path: path, body: nil)
                FileHandle.standardOutput.write(r.body)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
            done.signal()
        }
        done.wait()
        exit(0)
    }

    /// `HiveApp --post <path> <json>`: one POST after one board refresh, for checking replies and actions
    /// from a terminal.
    static func post(_ path: String, _ json: String) -> Never {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let services = Services.make(start: false)
            await services.board.refresh()
            let r = await services.api.handle(method: "POST", path: path, body: Data(json.utf8))
            print(r.status, String(decoding: r.body, as: UTF8.self))
            done.signal()
        }
        done.wait()
        exit(0)
    }

    /// `HiveApp --login-item on|off|status`: the same SMAppService calls the Settings toggle makes,
    /// for checking the login item from a terminal. Works from the bundled app only.
    static func loginItem(_ command: String) -> Never {
        let service = SMAppService.mainApp
        do {
            if command == "on" { try service.register() }
            if command == "off" { try service.unregister() }
            print("login item: \(describe(service.status))")
            exit(0)
        } catch {
            print("login item: \(describe(service.status)); error: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "enabled"
        case .notRegistered: return "not registered"
        case .requiresApproval: return "requires approval"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }
}
