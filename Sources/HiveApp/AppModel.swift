import Foundation
import HiveCore
import Observation
import ServiceManagement

/// App-wide state: how many sessions need you, and the three settings, kept in UserDefaults.
@MainActor
@Observable
final class AppModel {
    struct Waiting: Identifiable, Equatable {
        var id: String
        var name: String
        var headline: String
    }

    var needsYou = 0
    var waiting: [Waiting] = []
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
    }

    private let defaults: UserDefaults
    private var syncingLogin = false
    private var polling: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Keys.menuBar: true, Keys.openWindow: true, Keys.startAtLogin: false])
        showMenuBarIcon = defaults.bool(forKey: Keys.menuBar)
        openWindowAtLogin = defaults.bool(forKey: Keys.openWindow)
        // The system's record is the truth; the user can remove the login item in System Settings.
        let status = SMAppService.mainApp.status
        startAtLogin = status == .enabled || status == .requiresApproval
    }

    /// Follows the board: the needs-you count and the first three sessions waiting on you.
    func follow(_ board: Board) {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                let state = await board.snapshot()
                let needs = state.rows.filter { $0.group == "needs" }
                self?.needsYou = needs.count
                self?.waiting = needs.prefix(3).map { Waiting(id: $0.id, name: $0.name, headline: $0.headline) }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
