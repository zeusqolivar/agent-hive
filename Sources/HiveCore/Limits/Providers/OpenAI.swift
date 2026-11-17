// OpenAI organization costs (needs an Admin key).
// Docs (checked 2026-11-17): https://platform.openai.com/docs/api-reference/usage/costs (the page refuses
// scripted fetches, so it was checked in the official OpenAPI spec,
// https://github.com/openai/openai-openapi, path `/organization/costs`, security `AdminApiKeyAuth`).
//   GET https://api.openai.com/v1/organization/costs?start_time=<unix s>&bucket_width=1d&limit=<1-180>
//   header `Authorization: Bearer <admin key>`.
//   200: {"object": "page", "data": [{"object": "bucket", "start_time": s, "end_time": s, "results":
//         [{"object": "organization.costs.result", "amount": {"value": number, "currency": "usd"}, ...}]}],
//         "has_more": bool, "next_page": string|null}
import Foundation

public struct OpenAIProvider: UsageProvider {
    public let id = "openai"
    public let title = "OpenAI"
    public let host = "api.openai.com"
    public let keyKind = "Admin key"
    public let kind = "cost"

    public init() {}

    func costsURL(now: Date, page: String?) -> URL {
        let start = Spending.earliest(now: now)
        let days = Int(now.timeIntervalSince(start) / 86_400) + 1
        var items = [("start_time", String(Int(start.timeIntervalSince1970))), ("bucket_width", "1d"),
                     ("limit", String(min(180, days)))]
        if let page { items.append(("page", page)) }
        return URL(string: "https://\(host)/v1/organization/costs?" + ProviderRequest.query(items))!
    }

    public func fetch(key: String, http: HTTPClient, now: Date) async -> ProviderResult {
        let request = ProviderRequest(title: title, host: host)
        let headers = ["Authorization": "Bearer \(key)", "Accept": "application/json"]
        var daily: [DailyCost] = []
        var currency = "USD"
        var page: String?
        for _ in 0..<3 {
            let json: JSON
            switch await request.get(costsURL(now: now, page: page), headers: headers, http: http) {
            case .failure(let result, _): return result
            case .success(let j): json = j
            }
            guard let buckets = json["data"]?.array else { return request.unreadable() }
            for bucket in buckets {
                guard let start = bucket["start_time"]?.number else { continue }
                var amount = 0.0
                for result in bucket["results"]?.array ?? [] {
                    amount += ProviderRequest.number(result["amount"]?["value"]) ?? 0
                    if let c = result["amount"]?["currency"]?.string { currency = c.uppercased() }
                }
                daily.append(DailyCost(day: Date(timeIntervalSince1970: start), amount: amount))
            }
            guard json["has_more"]?.bool == true, let next = json["next_page"]?.string else { break }
            page = next
        }
        return .cost(daily: daily, currency: currency)
    }
}
