import AppKit
import HiveCore
import SwiftUI

/// The data readers and the API, shared by the window and the menu bar.
final class Services: Sendable {
    static let shared = Services.make(start: true)

    let paths = HivePaths.current
    let board: Board
    let usage: UsageCounter
    let api: HiveAPI

    static func make(start: Bool) -> Services { Services(start: start) }

    private init(start: Bool) {
        let replies = ReplySender(paths: paths)
        board = Board(paths: paths, processes: PSProcessSource(), pageVersion: 1, replies: replies)
        let liveBoard = board
        usage = UsageCounter(paths: paths, antigravityProject: { liveBoard.antigravityProject($0) })
        let skills = SkillsReader(paths: paths)
        let jobs = SkillsJobs(paths: paths, onFinish: { skills.invalidate() })
        api = HiveAPI(board: board, usage: usage, skills: skills, jobs: jobs, system: SystemReport(paths: paths),
                      classroom: ClassroomStore(paths: paths), actions: WorkspaceActions(), pages: Self.webFolder(),
                      replies: replies)
        guard start else { return }
        let board = self.board, usage = self.usage
        Task {
            await board.start()
            usage.start()
        }
    }

    /// The bundled pages: `Contents/Resources/web` in the app, or SwiftPM's resource bundle under `swift run`.
    static func webFolder() -> URL? {
        if let url = Bundle.main.url(forResource: "web", withExtension: nil) { return url }
        return Bundle.module.url(forResource: "web", withExtension: nil)
    }
}

@main
struct HiveApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel()

    init() {
        Dump.runIfAsked()
    }

    var body: some Scene {
        Window("Agent Hive", id: "main") {
            WebView(api: Services.shared.api, model: model)
                .frame(minWidth: 620, minHeight: 480)
                .ignoresSafeArea()
                .onAppear {
                    model.follow(Services.shared.board)
                    delegate.windowAppeared(model: model)
                }
        }
        .defaultSize(width: 1200, height: 800)

        MenuBarExtra(isInserted: $model.showMenuBarIcon) {
            MenuBarMenu(model: model)
                .onAppear { model.follow(Services.shared.board) }
        } label: {
            MenuBarLabel(model: model)
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// True when macOS opened the app as a login item.
    private var launchedAtLogin = false
    private var handledFirstWindow = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        if let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == kAEOpenApplication,
           event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            launchedAtLogin = true
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if !launchedAtLogin { NSApp.activate() }
    }

    /// At login, the window opens only when the setting says so; the menu bar icon stays.
    @MainActor
    func windowAppeared(model: AppModel) {
        guard !handledFirstWindow else { return }
        handledFirstWindow = true
        if launchedAtLogin, !model.openWindowAtLogin {
            DispatchQueue.main.async {
                NSApp.windows.first { $0.identifier?.rawValue == "main" || $0.title == "Agent Hive" }?.close()
            }
        }
    }

    /// Clicking the Dock icon with no window open brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }
}
