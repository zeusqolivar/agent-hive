// Anthropic organization cost report (needs an Admin key).
// Docs (checked 2026-11-17):
//   https://platform.claude.com/docs/en/api/beta/organization/cost_report/retrieve
//     GET https://api.anthropic.com/v1/organizations/cost_report?starting_at=<RFC 3339>&bucket_width=1d&limit=<1-31>
//     200: {"data": [{"starting_at": "...Z", "ending_at": "...Z", "results": [{"amount": "123.45",
//           "currency": "USD", ...}]}], "has_more": bool, "next_page": string|null}
//     `amount` is in the lowest currency unit (cents) as a decimal string: "123.45" USD is $1.23.
//   https://platform.claude.com/docs/en/build-with-claude/administration-api
//     Admin API key (`sk-ant-admin...`) in the `x-api-key` header, with `anthropic-version`.
//   https://platform.claude.com/docs/en/api/versioning (current version 2026-10-21).
// The docs mark this report as legacy in favour of /v1/organizations/analytics/cost, which needs
// 2026-01-01 or later; the cost report still works with an Admin key and gives daily buckets directly.
import Foundation

public struct AnthropicProvider: UsageProvider {
    public let id = "anthropic"
    public let title = "Anthropic"
    public let host = "api.anthropic.com"
    public let keyKind = "Admin key"
    public let kind = "cost"
    static let version = "2026-10-21"

    public init() {}

    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        return (try? Date(s, strategy: .iso8601))
            ?? (try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }

    func costURL(now: Date, page: String?) -> URL {
        var items = [("starting_at", Spending.earliest(now: now).formatted(.iso8601)), ("bucket_width", "1d"),
                     ("limit", "31")]
        if let page { items.append(("page", page)) }
        return URL(string: "https://\(host)/v1/organizations/cost_report?" + ProviderRequest.query(items))!
    }

    public func fetch(key: String, http: HTTPClient, now: Date) async -> ProviderResult {
        let request = ProviderRequest(title: title, host: host)
        let headers = ["x-api-key": key, "anthropic-version": Self.version, "Accept": "application/json"]
        var daily: [DailyCost] = []
        var currency = "USD"
        var page: String?
        for _ in 0..<3 {
            let json: JSON
            switch await request.get(costURL(now: now, page: page), headers: headers, http: http) {
            case .failure(let result, _): return result
            case .success(let j): json = j
            }
            guard let buckets = json["data"]?.array else { return request.unreadable() }
            for bucket in buckets {
                guard let start = Self.date(bucket["starting_at"]?.string) else { continue }
                var cents = 0.0
                for result in bucket["results"]?.array ?? [] {
                    cents += ProviderRequest.number(result["amount"]) ?? 0
                    if let c = result["currency"]?.string { currency = c.uppercased() }
                }
                daily.append(DailyCost(day: start, amount: cents / 100))
            }
            guard json["has_more"]?.bool == true, let next = json["next_page"]?.string else { break }
            page = next
        }
        return .cost(daily: daily, currency: currency)
    }
}
