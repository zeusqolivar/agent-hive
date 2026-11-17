import Foundation
import Testing
@testable import HiveCore

/// A provider that answers from a script of results and counts its calls.
final class ScriptedProvider: UsageProvider, @unchecked Sendable {
    let id: String
    let title: String
    let host = "api.example.com"
    let keyKind = "API key"
    private let lock = NSLock()
    private var script: [ProviderResult]
    private var count = 0
    private var keys: [String] = []
    let delay: Duration

    init(id: String = "deepseek", title: String = "DeepSeek", _ script: [ProviderResult], delay: Duration = .zero) {
        self.id = id
        self.title = title
        self.script = script
        self.delay = delay
    }

    var calls: Int { lock.withLock { count } }
    var keysSeen: [String] { lock.withLock { keys } }

    func fetch(key: String, http: HTTPClient, now: Date) async -> ProviderResult {
        let r = lock.withLock { () -> ProviderResult in
            count += 1
            keys.append(key)
            return script.count > 1 ? script.removeFirst() : script[0]
        }
        if delay != .zero { try? await Task.sleep(for: delay) }
        return r
    }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date
    init(_ t: Date) { self.t = t }
    var now: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
}

@Suite struct LimitsServiceTests {
    static let key = "sk-test-NOT-A-REAL-KEY-12345"

    static func make(_ providers: [UsageProvider], keys: [String: String] = ["deepseek": key],
                     clock: Clock = Clock(ProvidersTests.now)) throws -> (LimitsService, HivePaths) {
        let paths = HivePaths(home: try tempHome(), uid: 501)
        let service = LimitsService(paths: paths, keys: MemoryKeyStore(keys), http: FakeHTTP(), providers: providers,
                                    now: { clock.now })
        return (service, paths)
    }

    static func card(_ cards: JSON, _ id: String) -> JSON? {
        cards["cards"]?.array?.first { $0["id"]?.string == id }
    }

    @Test func noKeyNoRequest() async throws {
        let provider = ScriptedProvider([.balance(amount: 1, currency: "USD", spent: nil)])
        let (service, _) = try Self.make([provider], keys: [:])
        await service.refresh()
        #expect(provider.calls == 0)
        let card = try #require(Self.card(await service.cards(), "deepseek"))
        #expect(card["state"] == "not-set-up")
        #expect(card["kind"] == "balance")
    }

    @Test func balanceCardWithEstimatedSpending() async throws {
        let clock = Clock(ProvidersTests.now.addingTimeInterval(-7200))
        let provider = ScriptedProvider([.balance(amount: 10, currency: "USD", spent: nil),
                                         .balance(amount: 8.5, currency: "USD", spent: nil)])
        let (service, paths) = try Self.make([provider], clock: clock)
        await service.refresh()
        clock.advance(3600)
        await service.refresh()
        let cards = await service.cards()
        #expect(cards["apiKeys"] == true)
        let card = try #require(Self.card(cards, "deepseek"))
        #expect(card["state"] == "ok")
        #expect(card["balance"] == ["amount": 8.5, "currency": "USD"])
        #expect(card["spent"] == ["today": 1.5, "week": 1.5, "month": 1.5, "currency": "USD", "estimated": true])
        #expect(card["updatedAt"] == .int(Int(clock.now.timeIntervalSince1970)))
        #expect(provider.keysSeen == [Self.key, Self.key])
        #expect(UsageHistory(file: paths.usageHistoryFile).entries().count == 2)
    }

    @Test func reportedSpendingIsNotEstimated() async throws {
        let provider = ScriptedProvider(id: "openrouter", title: "OpenRouter",
                                        [.balance(amount: 74.5, currency: "USD", spent: Spent(today: 1, week: 2, month: 3))])
        let (service, _) = try Self.make([provider], keys: ["openrouter": Self.key])
        await service.refresh()
        let card = try #require(Self.card(await service.cards(), "openrouter"))
        #expect(card["spent"] == ["today": 1.0, "week": 2.0, "month": 3.0, "currency": "USD", "estimated": false])
    }

    @Test func costCard() async throws {
        let p = Spending.periods(now: ProvidersTests.now)
        let provider = ScriptedProvider(id: "openai", title: "OpenAI", [.cost(daily: [
            DailyCost(day: p.month, amount: 2), DailyCost(day: p.today, amount: 0.25)], currency: "USD")])
        let (service, _) = try Self.make([provider], keys: ["openai": Self.key])
        await service.refresh()
        let card = try #require(Self.card(await service.cards(), "openai"))
        #expect(card["kind"] == "cost")
        #expect(card["state"] == "ok")
        #expect(card["balance"] == nil)
        #expect(card["spent"] == ["today": 0.25, "week": 0.25, "month": 2.25, "currency": "USD", "estimated": false])
    }

    @Test func authFailurePausesUntilRefresh() async throws {
        let provider = ScriptedProvider([.authFailed("DeepSeek rejected this key."), .balance(amount: 3, currency: "USD", spent: nil)])
        let clock = Clock(ProvidersTests.now)
        let (service, _) = try Self.make([provider], clock: clock)
        await service.checkAll(manual: false)
        #expect(provider.calls == 1)
        let card = try #require(Self.card(await service.cards(), "deepseek"))
        #expect(card["state"] == "error")
        #expect(card["message"] == "DeepSeek rejected this key.")
        clock.advance(3600)
        await service.checkAll(manual: false)
        #expect(provider.calls == 1)  // paused
        await service.refresh()
        #expect(provider.calls == 2)
        #expect(Self.card(await service.cards(), "deepseek")?["state"] == "ok")
    }

    @Test func newKeyClearsThePause() async throws {
        let provider = ScriptedProvider([.authFailed("DeepSeek rejected this key."), .balance(amount: 3, currency: "USD", spent: nil)])
        let (service, _) = try Self.make([provider])
        await service.checkAll(manual: false)
        try await service.saveKey("sk-test-another-fake-key", for: "deepseek")
        #expect(provider.calls == 2)
        #expect(provider.keysSeen.last == "sk-test-another-fake-key")
        #expect(Self.card(await service.cards(), "deepseek")?["state"] == "ok")
        try await service.removeKey(for: "deepseek")
        #expect(Self.card(await service.cards(), "deepseek")?["state"] == "not-set-up")
        #expect(Self.card(await service.cards(), "deepseek")?["balance"] == nil)
    }

    @Test func failureKeepsLastGoodNumbersMarkedStale() async throws {
        let clock = Clock(ProvidersTests.now)
        let provider = ScriptedProvider([.balance(amount: 5, currency: "CNY", spent: nil), .failed("Couldn't reach DeepSeek.")])
        let (service, _) = try Self.make([provider], clock: clock)
        await service.refresh()
        let good = Int(clock.now.timeIntervalSince1970)
        clock.advance(900)
        await service.refresh()
        let card = try #require(Self.card(await service.cards(), "deepseek"))
        #expect(card["state"] == "stale")
        #expect(card["balance"] == ["amount": 5.0, "currency": "CNY"])
        #expect(card["updatedAt"] == .int(good))
        #expect(card["message"] == "Couldn't reach DeepSeek.")
    }

    @Test func automaticChecksWaitTheirTurn() async throws {
        let clock = Clock(ProvidersTests.now)
        let provider = ScriptedProvider([.balance(amount: 5, currency: "USD", spent: nil)])
        let (service, _) = try Self.make([provider], clock: clock)
        await service.checkAll(manual: false)
        await service.checkAll(manual: false)  // tab opened again a moment later
        #expect(provider.calls == 1)
        clock.advance(LimitsService.minimumGap + 1)
        await service.checkAll(manual: false)
        #expect(provider.calls == 2)
    }

    @Test func oneRequestAtATimePerService() async throws {
        let provider = ScriptedProvider([.balance(amount: 5, currency: "USD", spent: nil)], delay: .milliseconds(100))
        let (service, _) = try Self.make([provider])
        async let a: Void = service.refresh()
        async let b: Void = service.refresh()
        _ = await (a, b)
        #expect(provider.calls == 1)
    }

    @Test func cardsNeverContainTheKey() async throws {
        let providers: [UsageProvider] = [
            ScriptedProvider([.failed("x")]),
            ScriptedProvider(id: "openai", title: "OpenAI", [.authFailed("OpenAI rejected this key.")]),
        ]
        let (service, _) = try Self.make(providers, keys: ["deepseek": Self.key, "openai": Self.key])
        await service.refresh()
        let text = await service.cards().serializedString
        #expect(!text.contains(Self.key))
        #expect(!text.contains("NOT-A-REAL"))
    }

    @Test func planCardsComeFirst() async throws {
        let (service, _) = try Self.make(UsageProviders.all, keys: [:])
        let ids = await service.cards()["cards"]?.array?.compactMap { $0["id"]?.string }
        #expect(ids == ["claude", "codex", "antigravity", "deepseek", "openrouter", "openai", "anthropic"])
    }

    @Test func summaryLine() async throws {
        let clock = Clock(ProvidersTests.now)
        let (service, paths) = try Self.make([
            ScriptedProvider([.balance(amount: 12.5, currency: "USD", spent: nil)]),
            ScriptedProvider(id: "openrouter", title: "OpenRouter", [.balance(amount: 3.25, currency: "USD", spent: nil)]),
        ], keys: ["deepseek": Self.key, "openrouter": Self.key], clock: clock)
        #expect(await service.summary() == nil)
        await service.refresh()
        #expect(await service.summary() == "OpenRouter $3.25 left")
        let t = Int(clock.now.timeIntervalSince1970)
        try ClaudeLimitsTests.save(paths, savedAt: t - 60, limits: """
            {"five_hour": {"used_percentage": 10, "resets_at": \(t + 600)}, "seven_day": {"used_percentage": 41.4, "resets_at": \(t + 86400)}}
            """)
        #expect(await service.summary() == "Claude weekly 41% · OpenRouter $3.25 left")
    }

    @Test func claudeInstallAndRemoveThroughTheService() async throws {
        let (service, paths) = try Self.make([], keys: [:])
        try await service.claude(action: "install")
        #expect(StatusLineInstaller(paths: paths).isInstalled)
        #expect(Self.card(await service.cards(), "claude")?["installed"] == true)
        try await service.claude(action: "remove")
        #expect(!StatusLineInstaller(paths: paths).isInstalled)
        await #expect(throws: LimitsService.BadAction.self) { try await service.claude(action: "explode") }
    }
}
