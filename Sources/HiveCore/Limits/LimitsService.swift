import Foundation

/// Checks the usage services that have a saved key and builds the `/api/limits` cards, with the plan cards
/// (Claude, Codex, Antigravity) first.
///
/// - Automatic checks every 15 minutes and when the Usage tab opens; Refresh checks right away.
/// - One request at a time per service. An automatic check skips a service checked in the last minute, and
///   one whose key was refused, until the key changes or Refresh is clicked.
/// - A failed check keeps the last good numbers, marked stale with the reason.
/// - Keys are read from the key store only to make a request; they never reach a card.
public actor LimitsService {
    public static let interval: TimeInterval = 15 * 60
    /// The shortest gap between automatic checks of one service.
    public static let minimumGap: TimeInterval = 60

    public struct BadAction: Error {}

    struct State {
        var good: ProviderResult?
        var goodAt: Date?
        var error: String?
        var paused = false
        var checking = false
        var checkedAt: Date?
    }

    let paths: HivePaths
    let keys: KeyStore
    let http: HTTPClient
    let providers: [UsageProvider]
    let now: @Sendable () -> Date
    let history: UsageHistory
    private var states: [String: State] = [:]
    private var loop: Task<Void, Never>?

    public init(paths: HivePaths, keys: KeyStore, http: HTTPClient, providers: [UsageProvider] = UsageProviders.all,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.paths = paths
        self.keys = keys
        self.http = http
        self.providers = providers
        self.now = now
        history = UsageHistory(file: paths.usageHistoryFile)
    }

    public var providerList: [UsageProvider] { providers }

    /// Starts the 15-minute checks.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkAll(manual: false)
                try? await Task.sleep(for: .seconds(Self.interval))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Refresh: checks every service with a key now, including paused ones.
    public func refresh() async {
        await checkAll(manual: true)
    }

    public func checkAll(manual: Bool) async {
        await withTaskGroup(of: Void.self) { group in
            for provider in providers {
                group.addTask { await self.check(provider, manual: manual) }
            }
        }
    }

    func check(_ provider: UsageProvider, manual: Bool) async {
        let id = provider.id
        guard let key = keys.key(for: id) else {
            states[id] = nil
            return
        }
        var state = states[id] ?? State()
        let t = now()
        if state.checking { return }
        if !manual {
            if state.paused { return }
            if let last = state.checkedAt, t.timeIntervalSince(last) < Self.minimumGap { return }
        }
        state.checking = true
        state.checkedAt = t
        states[id] = state
        let result = await provider.fetch(key: key, http: http, now: t)
        state = states[id] ?? State()
        state.checking = false
        let done = now()
        switch result {
        case .balance(let amount, let currency, _):
            state.good = result
            state.goodAt = done
            state.error = nil
            state.paused = false
            if let amount { try? history.append(service: id, balance: amount, currency: currency, at: done) }
        case .cost:
            state.good = result
            state.goodAt = done
            state.error = nil
            state.paused = false
        case .authFailed(let message):
            state.error = message
            state.paused = true
        case .failed(let message):
            state.error = message
        }
        states[id] = state
    }

    // MARK: - Keys

    public func hasKey(for service: String) -> Bool { keys.key(for: service) != nil }

    /// Saves a key, forgets what the old key found, and checks the service with the new one.
    public func saveKey(_ key: String, for service: String) async throws {
        try keys.save(key, for: service)
        states[service] = nil
        if let provider = providers.first(where: { $0.id == service }) { await check(provider, manual: true) }
    }

    public func removeKey(for service: String) throws {
        try keys.remove(service: service)
        states[service] = nil
    }

    // MARK: - Claude status line

    public func claude(action: String) throws {
        let installer = StatusLineInstaller(paths: paths)
        switch action {
        case "install": try installer.install()
        case "remove": try installer.remove()
        default: throw BadAction()
        }
    }

    // MARK: - Cards

    /// `{cards: [...], apiKeys: true}`.
    public func cards() -> JSON {
        let t = now()
        var cards = [ClaudeLimits.read(paths: paths, now: t), CodexLimits.read(paths: paths, now: t), PlanCards.antigravity()]
        for provider in providers { cards.append(card(provider, now: t)) }
        return ["cards": .array(cards), "apiKeys": true]
    }

    static func money(_ x: Double) -> JSON { .double((x * 10_000).rounded() / 10_000) }

    func card(_ provider: UsageProvider, now t: Date) -> JSON {
        let id = provider.id, title = provider.title
        let state = states[id] ?? State()
        var kind = provider.kind
        if case .cost = state.good { kind = "cost" } else if case .balance = state.good { kind = "balance" }
        guard keys.key(for: id) != nil else {
            return PlanCards.card(id: id, title: title, kind: kind, state: "not-set-up",
                                  message: "Add \(provider.keyKind == "Admin key" ? "an" : "a") \(provider.keyKind) in Settings.")
        }
        guard let good = state.good, let goodAt = state.goodAt else {
            if let error = state.error {
                return PlanCards.card(id: id, title: title, kind: kind, state: "error", message: error)
            }
            return PlanCards.card(id: id, title: title, kind: kind, state: "unavailable", message: "Not checked yet.")
        }
        var balance: JSON?
        var spent: JSON?
        switch good {
        case .balance(let amount, let currency, let reported):
            if let amount { balance = ["amount": Self.money(amount), "currency": .string(currency)] }
            let s = reported ?? history.spent(service: id, now: t)
            spent = ["today": Self.money(s.today), "week": Self.money(s.week), "month": Self.money(s.month),
                     "currency": .string(currency), "estimated": .bool(reported == nil)]
        case .cost(let daily, let currency):
            let s = Spending.spent(daily, now: t)
            spent = ["today": Self.money(s.today), "week": Self.money(s.week), "month": Self.money(s.month),
                     "currency": .string(currency), "estimated": false]
        default:
            break
        }
        return PlanCards.card(id: id, title: title, kind: kind, state: state.error == nil ? "ok" : "stale",
                              balance: balance, spent: spent, updatedAt: Int(goodAt.timeIntervalSince1970),
                              message: state.error)
    }

    // MARK: - Menu bar

    /// One line for the menu bar: the Claude weekly window and the lowest balance, when known.
    public func summary() -> String? {
        var parts: [String] = []
        let claude = ClaudeLimits.read(paths: paths, now: now())
        if let weekly = claude["windows"]?.array?.first(where: { $0["label"] == "Weekly" })?["usedPercent"]?.number {
            parts.append("Claude weekly \(Int(weekly.rounded()))%")
        }
        var lowest: (title: String, amount: Double, currency: String)?
        for provider in providers {
            guard keys.key(for: provider.id) != nil,
                  case .balance(let amount?, let currency, _) = states[provider.id]?.good else { continue }
            if lowest == nil || amount < lowest!.amount { lowest = (provider.title, amount, currency) }
        }
        if let lowest { parts.append("\(lowest.title) \(Self.format(lowest.amount, lowest.currency)) left") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func format(_ amount: Double, _ currency: String) -> String {
        let n = String(format: "%.2f", amount)
        switch currency.uppercased() {
        case "USD": return "$" + n
        case "CNY": return "¥" + n
        default: return "\(n) \(currency)"
        }
    }
}
