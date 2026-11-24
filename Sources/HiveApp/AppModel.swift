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
        /// Which agent runs it: "Claude", "Antigravity" or "Codex".
        var agent: String = "Claude"

        init(id: String, name: String, headline: String, agent: String = "Claude") {
            self.id = id
            self.name = name
            self.headline = headline
            self.agent = agent
        }

        init(_ row: BoardRow) {
            self.init(id: row.id, name: row.name, headline: row.headline, agent: Self.agent(row.provider))
        }

        static func agent(_ provider: String?) -> String {
            switch provider {
            case "google": "Antigravity"
            case "openai": "Codex"
            default: "Claude"
            }
        }
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

    /// Minutes left on the one-hour mode while it's on.
    var minutesLeft: Int? {
        guard keepAwakeMode == .oneHour, let until = keepAwakeUntil else { return nil }
        return KeepAwakePolicy.minutesLeft(now: Date(), until: until)
    }

    /// The menu item's text for a mode, with the minutes left on the one-hour mode.
    func title(for mode: KeepAwakeMode) -> String {
        guard mode == .oneHour, keepAwakeMode == .oneHour, let until = keepAwakeUntil else { return mode.title }
        return "\(mode.title) (\(KeepAwakePolicy.minutesLeft(now: Date(), until: until)) min left)"
    }
    /// A view the window should switch to, such as `#/agents/<id>`; the web view clears it once shown.
    var route: String?
    var loginError: String?

    /// The menu bar's limits line: the Claude weekly window and the lowest balance.
    var usageSummary: String?
    /// Each usage source as the menu bar panel shows it.
    var usage: [UsageGlance] = []
    var refreshingUsage = false
    /// Sessions that are working right now, for the menu bar panel.
    var busy: [Waiting] = []
    /// Which usage services have a key in the Keychain (never the keys themselves).
    var savedKeys: Set<String> = []
    var keyErrors: [String: String] = [:]
    var statusLineInstalled = false
    var statusLineError: String?

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
    /// False when drawing the panel with set data: nothing follows the board or checks usage.
    let live: Bool
    private var syncingLogin = false
    private var polling: Task<Void, Never>?
    private let assertion = SleepAssertion()

    /// `live: false` skips following the board and the usage checks, for drawing the panel with set data.
    init(defaults: UserDefaults = .standard, live: Bool = true) {
        self.defaults = defaults
        self.live = live
        defaults.register(defaults: [Keys.menuBar: true, Keys.openWindow: true, Keys.startAtLogin: false])
        showMenuBarIcon = defaults.bool(forKey: Keys.menuBar)
        openWindowAtLogin = defaults.bool(forKey: Keys.openWindow)
        keepAwakeMode = KeepAwakeMode(stored: defaults.string(forKey: Keys.keepAwake))
        keepAwakeUntil = defaults.object(forKey: Keys.keepAwakeUntil) as? Date
        // The system's record is the truth; the user can remove the login item in System Settings.
        let status = SMAppService.mainApp.status
        startAtLogin = status == .enabled || status == .requiresApproval
        guard live else { return }
        applyKeepAwake()
        // Follow the board from launch, so "while agents are working" works even before a window opens.
        Task { @MainActor [weak self] in
            self?.follow(Services.shared.board)
            await self?.refreshUsageState()
        }
    }

    // MARK: - Usage services

    var limits: LimitsService { Services.shared.limits }

    /// Re-reads which keys are saved, whether the status line is set up, and the menu bar line.
    func refreshUsageState() async {
        var saved = Set<String>()
        for provider in UsageProviders.all where await limits.hasKey(for: provider.id) { saved.insert(provider.id) }
        savedKeys = saved
        statusLineInstalled = StatusLineInstaller(paths: Services.shared.paths).isInstalled
        usageSummary = await limits.summary()
        usage = UsageGlance.from(await limits.cards())
    }

    /// Checks every usage service now, as the Usage tab's Refresh does.
    func checkUsageNow() async {
        guard !refreshingUsage else { return }
        refreshingUsage = true
        await limits.refresh()
        await refreshUsageState()
        refreshingUsage = false
    }

    /// Saves a key to the Keychain and checks that service with it.
    func saveKey(_ key: String, for service: String) async {
        keyErrors[service] = nil
        do {
            try await limits.saveKey(key, for: service)
        } catch {
            keyErrors[service] = "Couldn't save the key to the Keychain."
        }
        await refreshUsageState()
    }

    func removeKey(for service: String) async {
        keyErrors[service] = nil
        do {
            try await limits.removeKey(for: service)
        } catch {
            keyErrors[service] = "Couldn't remove the key from the Keychain."
        }
        await refreshUsageState()
    }

    func setStatusLine(installed: Bool) async {
        statusLineError = nil
        do {
            try await limits.claude(action: installed ? "install" : "remove")
        } catch StatusLineError.unreadableSettings {
            statusLineError = "~/.claude/settings.json isn't valid JSON, so Agent Hive left it alone."
        } catch {
            statusLineError = "Couldn't change the Claude status line."
        }
        await refreshUsageState()
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

    /// Follows the board: the needs-you count, the first sessions waiting on you and those working.
    func follow(_ board: Board) {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                if tick % 15 == 0 { await self?.refreshUsageState() }
                tick += 1
                let state = await board.snapshot()
                let needs = state.rows.filter { $0.group == "needs" }
                self?.needsYou = needs.count
                self?.working = state.rows.filter { $0.group == "working" }.count
                self?.waiting = needs.prefix(5).map(Waiting.init)
                self?.busy = state.rows.filter { $0.group == "working" }.prefix(5).map(Waiting.init)
                self?.applyKeepAwake()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
