import Foundation
import Testing
@testable import HiveCore

/// Provider responses come from fixtures shaped like each provider's documented examples (see the doc URLs at
/// the top of each provider file). No test reaches the network.
@Suite struct ProvidersTests {
    /// 2026-11-17 12:00 UTC, a Tuesday.
    static let now = Date(timeIntervalSince1970: 1_794_916_800)
    static let key = "test-key-not-real-0000"

    static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Fixture.root.appending(path: "limits/\(name)"))
    }

    static func http(_ answers: [(String, Int, String)]) throws -> FakeHTTP {
        let http = FakeHTTP()
        for (url, status, file) in answers { http.answer(url, status: status, data: try fixture(file)) }
        return http
    }

    // MARK: DeepSeek

    static let deepseekURL = "https://api.deepseek.com/user/balance"

    @Test func deepseekBalance() async throws {
        let http = try Self.http([(Self.deepseekURL, 200, "deepseek-balance.json")])
        let r = await DeepSeekProvider().fetch(key: Self.key, http: http, now: Self.now)
        #expect(r == .balance(amount: 110, currency: "CNY", spent: nil))
        #expect(http.requests.count == 1)
        #expect(http.requests.first?.headers == ["Authorization": "Bearer \(Self.key)", "Accept": "application/json"])
    }

    @Test func deepseekPrefersACurrencyWithMoney() async throws {
        let http = try Self.http([(Self.deepseekURL, 200, "deepseek-balance-two.json")])
        #expect(await DeepSeekProvider().fetch(key: Self.key, http: http, now: Self.now)
                == .balance(amount: 4.25, currency: "USD", spent: nil))
    }

    @Test(arguments: [
        (401, "bad-key.json", ProviderResult.authFailed("DeepSeek rejected this key.")),
        (403, "bad-key.json", .authFailed("DeepSeek rejected this key.")),
        (429, "rate-limit.json", .failed("DeepSeek is limiting requests. Agent Hive will try again later.")),
        (200, "captive-portal.html", .failed("DeepSeek sent an answer Agent Hive couldn't read.")),
        (200, "malformed.json", .failed("DeepSeek sent an answer Agent Hive couldn't read.")),
        (200, "error-200.json", .failed("DeepSeek reported an error.")),
        (502, "captive-portal.html", .failed("DeepSeek answered with HTTP 502.")),
    ])
    func deepseekFailures(status: Int, file: String, expected: ProviderResult) async throws {
        let http = try Self.http([(Self.deepseekURL, status, file)])
        #expect(await DeepSeekProvider().fetch(key: Self.key, http: http, now: Self.now) == expected)
    }

    @Test func unreachable() async {
        let r = await DeepSeekProvider().fetch(key: Self.key, http: FakeHTTP(), now: Self.now)
        #expect(r == .failed("Couldn't reach DeepSeek."))
    }

    // MARK: OpenRouter

    static let orKey = "https://openrouter.ai/api/v1/key"
    static let orCredits = "https://openrouter.ai/api/v1/credits"

    @Test func openRouterRegularKeyUsesItsLimit() async throws {
        let http = try Self.http([(Self.orKey, 200, "openrouter-key.json"), (Self.orCredits, 403, "openrouter-forbidden.json")])
        let r = await OpenRouterProvider().fetch(key: Self.key, http: http, now: Self.now)
        #expect(r == .balance(amount: 74.5, currency: "USD", spent: Spent(today: 1.25, week: 6.5, month: 25.5)))
        #expect(http.requests.allSatisfy { $0.url.host == "openrouter.ai" && $0.headers["Authorization"] == "Bearer \(Self.key)" })
    }

    @Test func openRouterManagementKeyUsesCredits() async throws {
        let http = try Self.http([(Self.orKey, 200, "openrouter-key-nolimit.json"), (Self.orCredits, 200, "openrouter-credits.json")])
        let r = await OpenRouterProvider().fetch(key: Self.key, http: http, now: Self.now)
        #expect(r == .balance(amount: 74.75, currency: "USD", spent: Spent(today: 0.5, week: 1, month: 3)))
    }

    @Test func openRouterNoLimitAndNoCredits() async throws {
        let http = try Self.http([(Self.orKey, 200, "openrouter-key-nolimit.json"), (Self.orCredits, 403, "openrouter-forbidden.json")])
        let r = await OpenRouterProvider().fetch(key: Self.key, http: http, now: Self.now)
        #expect(r == .balance(amount: nil, currency: "USD", spent: Spent(today: 0.5, week: 1, month: 3)))
    }

    @Test func openRouterBadKey() async throws {
        let http = try Self.http([(Self.orKey, 401, "openrouter-unauthorized.json")])
        #expect(await OpenRouterProvider().fetch(key: Self.key, http: http, now: Self.now)
                == .authFailed("OpenRouter rejected this key."))
        #expect(http.requests.count == 1)
    }

    @Test func openRouterCaptivePortal() async throws {
        let http = try Self.http([(Self.orKey, 200, "captive-portal.html")])
        #expect(await OpenRouterProvider().fetch(key: Self.key, http: http, now: Self.now)
                == .failed("OpenRouter sent an answer Agent Hive couldn't read."))
    }

    // MARK: OpenAI

    @Test func openAIDailyCosts() async throws {
        let http = FakeHTTP()
        let provider = OpenAIProvider()
        let url = provider.costsURL(now: Self.now, page: nil)
        // From the earlier of the month's and the week's start (UTC): 2026-11-01.
        #expect(url.absoluteString
                == "https://api.openai.com/v1/organization/costs?start_time=1793491200&bucket_width=1d&limit=17")
        http.answer(url.absoluteString, status: 200, data: try Self.fixture("openai-costs.json"))
        let r = await provider.fetch(key: Self.key, http: http, now: Self.now)
        guard case .cost(let daily, let currency) = r else { Issue.record("\(r)"); return }
        #expect(currency == "USD")
        #expect(daily.map(\.amount) == [2.5, 1.25, 0.06, 0.5])
        let spent = Spending.spent(daily, now: Self.now)
        #expect(spent.today == 0.5)
        #expect(abs(spent.week - 0.56) < 1e-9)
        #expect(abs(spent.month - 1.81) < 1e-9)
        #expect(http.requests.first?.headers["Authorization"] == "Bearer \(Self.key)")
    }

    @Test func openAIBadKey() async throws {
        let provider = OpenAIProvider()
        let http = FakeHTTP()
        http.answer(provider.costsURL(now: Self.now, page: nil).absoluteString, status: 401, data: try Self.fixture("bad-key.json"))
        #expect(await provider.fetch(key: Self.key, http: http, now: Self.now) == .authFailed("OpenAI rejected this key."))
    }

    // MARK: Anthropic

    @Test func anthropicDailyCostsInCents() async throws {
        let provider = AnthropicProvider()
        let url = provider.costURL(now: Self.now, page: nil)
        #expect(url.absoluteString == "https://api.anthropic.com/v1/organizations/cost_report"
                + "?starting_at=2026-11-01T00:00:00Z&bucket_width=1d&limit=31")
        let http = FakeHTTP()
        http.answer(url.absoluteString, status: 200, data: try Self.fixture("anthropic-cost-report.json"))
        let r = await provider.fetch(key: Self.key, http: http, now: Self.now)
        guard case .cost(let daily, let currency) = r else { Issue.record("\(r)"); return }
        #expect(currency == "USD")
        #expect(daily.count == 3)
        #expect(daily.first?.amount == 2.5)
        let spent = Spending.spent(daily, now: Self.now)
        #expect(spent.today == 0)
        #expect(abs(spent.week - 1.2378912) < 1e-9)
        #expect(abs(spent.month - 3.7378912) < 1e-9)
        let headers = try #require(http.requests.first?.headers)
        #expect(headers["x-api-key"] == Self.key)
        #expect(headers["anthropic-version"] == "2026-10-21")
        #expect(headers["Authorization"] == nil)
    }

    @Test func anthropicFollowsPages() async throws {
        let provider = AnthropicProvider()
        let http = FakeHTTP()
        let first = #"{"data": [{"starting_at": "2026-11-16T00:00:00Z", "ending_at": "2026-11-17T00:00:00Z", "results": [{"amount": "100", "currency": "USD"}]}], "has_more": true, "next_page": "page_abc"}"#
        let second = #"{"data": [{"starting_at": "2026-11-17T00:00:00Z", "ending_at": "2026-11-18T00:00:00Z", "results": [{"amount": "50", "currency": "USD"}]}], "has_more": false, "next_page": null}"#
        http.answer(provider.costURL(now: Self.now, page: nil).absoluteString, status: 200, body: first)
        http.answer(provider.costURL(now: Self.now, page: "page_abc").absoluteString, status: 200, body: second)
        let r = await provider.fetch(key: Self.key, http: http, now: Self.now)
        guard case .cost(let daily, _) = r else { Issue.record("\(r)"); return }
        #expect(daily.map(\.amount) == [1, 0.5])
    }

    @Test func anthropicRateLimited() async throws {
        let provider = AnthropicProvider()
        let http = FakeHTTP()
        http.answer(provider.costURL(now: Self.now, page: nil).absoluteString, status: 429, data: try Self.fixture("rate-limit.json"))
        #expect(await provider.fetch(key: Self.key, http: http, now: Self.now)
                == .failed("Anthropic is limiting requests. Agent Hive will try again later."))
    }

    // MARK: Every provider

    @Test func requestsGoOnlyToTheProvidersHost() async throws {
        for provider in UsageProviders.all {
            let http = FakeHTTP()
            _ = await provider.fetch(key: Self.key, http: http, now: Self.now)
            #expect(!http.requests.isEmpty, "\(provider.id)")
            #expect(http.requests.allSatisfy { $0.url.host == provider.host && $0.url.scheme == "https" }, "\(provider.id)")
        }
        #expect(UsageProviders.all.map(\.id) == ["deepseek", "openrouter", "openai", "anthropic"])
        #expect(UsageProviders.all.map(\.host) == ["api.deepseek.com", "openrouter.ai", "api.openai.com", "api.anthropic.com"])
    }

    @Test func refusesAnotherHost() async {
        let http = FakeHTTP()
        let r = await ProviderRequest(title: "Test", host: "api.example.com")
            .get(URL(string: "https://elsewhere.example/x")!, headers: [:], http: http)
        #expect(http.requests.isEmpty)
        if case .success = r { Issue.record("should refuse") }
    }

    @Test func periodsAreUTC() {
        let p = Spending.periods(now: Self.now)
        #expect(p.today == Date(timeIntervalSince1970: 1_794_873_600))   // 2026-11-17
        #expect(p.week == Date(timeIntervalSince1970: 1_794_787_200))    // Monday 2026-11-16
        #expect(p.month == Date(timeIntervalSince1970: 1_793_491_200))   // 2026-11-01
        // On a Monday the week starts that day; on Sunday 2026-11-01 it started in October.
        let early = Spending.periods(now: Date(timeIntervalSince1970: 1_793_620_800))  // 2026-11-02 12:00, Monday
        #expect(early.week == Date(timeIntervalSince1970: 1_793_577_600))
        #expect(Spending.periods(now: Date(timeIntervalSince1970: 1_793_534_400)).week  // Sunday 2026-11-01
                == Date(timeIntervalSince1970: 1_792_972_800))  // Monday 2026-10-26
    }
}
