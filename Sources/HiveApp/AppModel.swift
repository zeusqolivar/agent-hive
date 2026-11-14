import Foundation
import HiveCore
import Observation
import ServiceManagement

/// App-wide state: how many sessions need you, the settings (kept in UserDefaults), and keeping the Mac awake.
@MainActor
@Observable
final class AppModel {
    struct Waiting: Identifiable, Equatable {
        var id: String
        var name: String
        var headline: String
    }

    var needsYou = 0
    var working = 0
    var waiting: [Waiting] = []
    /// True while Agent Hive is holding the Mac awake.
    private(set) var keepingAwake = false
    /// When the one-hour mode ends.
    private(set) var keepAwakeUntil: Date?

    var keepAwakeMode: KeepAwakeMode {
        didSet {
            guard keepAwakeMode != oldValue else { return }
            keepAwakeUntil = keepAwakeMode == .oneHour ? KeepAwakePolicy.oneHourFrom(Date()) : nil
            defaults.set(keepAwakeMode.rawValue, forKey: Keys.keepAwake)
            defaults.set(keepAwakeUntil, forKey: Keys.keepAwakeUntil)
            applyKeepAwake()
        }
    }

    /// The menu item's text for a mode, with the minutes left on the one-hour mode.
    func title(for mode: KeepAwakeMode) -> String {
        guard mode == .oneHour, keepAwakeMode == .oneHour, let until = keepAwakeUntil else { return mode.title }
        return "\(mode.title) (\(KeepAwakePolicy.minutesLeft(now: Date(), until: until)) min left)"
    }
    /// A view the window should switch to, such as `#/agents/<id>`; the web view clears it once shown.
    var route: String?
    var loginError: String?

    var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: Keys.menuBar) }
    }

    var openWindowAtLogin: Bool {
        didSet { defaults.set(openWindowAtLogin, forKey: Keys.openWindow) }
    }

    /// Registers or unregisters the app as a login item; shows the system's error text if that fails.
    var startAtLogin: Bool {
        didSet {
            guard startAtLogin != oldValue, !syncingLogin else { return }
            defaults.set(startAtLogin, forKey: Keys.startAtLogin)
            do {
                if startAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                loginError = nil
            } catch {
                loginError = error.localizedDescription
                syncingLogin = true
                startAtLogin = SMAppService.mainApp.status == .enabled
                syncingLogin = false
            }
        }
    }

    private enum Keys {
        static let menuBar = "showMenuBarIcon"
        static let openWindow = "openWindowAtLogin"
        static let startAtLogin = "startAtLogin"
        static let keepAwake = "keepAwakeMode"
        static let keepAwakeUntil = "keepAwakeUntil"
    }

    private let defaults: UserDefaults
    private var syncingLogin = false
    private var polling: Task<Void, Never>?
    private let assertion = SleepAssertion()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Keys.menuBar: true, Keys.openWindow: true, Keys.startAtLogin: false])
        showMenuBarIcon = defaults.bool(forKey: Keys.menuBar)
        openWindowAtLogin = defaults.bool(forKey: Keys.openWindow)
        keepAwakeMode = KeepAwakeMode(stored: defaults.string(forKey: Keys.keepAwake))
        keepAwakeUntil = defaults.object(forKey: Keys.keepAwakeUntil) as? Date
        // The system's record is the truth; the user can remove the login item in System Settings.
        let status = SMAppService.mainApp.status
        startAtLogin = status == .enabled || status == .requiresApproval
        applyKeepAwake()
        // Follow the board from launch, so "while agents are working" works even before a window opens.
        Task { @MainActor [weak self] in self?.follow(Services.shared.board) }
    }

    /// Holds or releases the Mac's sleep, and switches the one-hour mode off once it runs out.
    func applyKeepAwake() {
        let now = Date()
        if KeepAwakePolicy.expired(mode: keepAwakeMode, now: now, until: keepAwakeUntil) {
            keepAwakeMode = .off
            return
        }
        let hold = KeepAwakePolicy.shouldStayAwake(mode: keepAwakeMode, working: working, needsYou: needsYou,
                                                   now: now, until: keepAwakeUntil)
        assertion.set(hold)
        keepingAwake = assertion.isHeld
    }

    /// Follows the board: the needs-you count and the first three sessions waiting on you.
    func follow(_ board: Board) {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                let state = await board.snapshot()
                let needs = state.rows.filter { $0.group == "needs" }
                self?.needsYou = needs.count
                self?.working = state.rows.filter { $0.group == "working" }.count
                self?.waiting = needs.prefix(3).map { Waiting(id: $0.id, name: $0.name, headline: $0.headline) }
                self?.applyKeepAwake()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
