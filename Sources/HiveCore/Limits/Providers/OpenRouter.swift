// OpenRouter credits and key usage.
// Docs (checked 2026-11-17):
//   https://openrouter.ai/docs/api/api-reference/api-keys/get-current-api-key
//     GET https://openrouter.ai/api/v1/key, `Authorization: Bearer <key>`, any key.
//     200: {"data": {"limit": number|null, "limit_remaining": number|null, "limit_reset": string|null,
//           "usage": n, "usage_daily": n, "usage_weekly": n, "usage_monthly": n, "is_management_key": bool, ...}}
//     (USD; daily/weekly/monthly are the current UTC day, week and month).
//   https://openrouter.ai/docs/api/api-reference/credits/get-remaining-credits
//     GET https://openrouter.ai/api/v1/credits, management key only (403 "Only management keys can perform
//     this operation" otherwise). 200: {"data": {"total_credits": n, "total_usage": n}}.
//   Errors: {"error": {"code": 401, "message": "..."}}.
import Foundation

public struct OpenRouterProvider: UsageProvider {
    public let id = "openrouter"
    public let title = "OpenRouter"
    public let host = "openrouter.ai"
    public let keyKind = "API key"

    public init() {}

    public func fetch(key: String, http: HTTPClient, now: Date) async -> ProviderResult {
        let request = ProviderRequest(title: title, host: host)
        let headers = ["Authorization": "Bearer \(key)", "Accept": "application/json"]
        let info: JSON
        switch await request.get(URL(string: "https://\(host)/api/v1/key")!, headers: headers, http: http) {
        case .failure(let result, _): return result
        case .success(let json): info = json["data"] ?? .null
        }
        guard info.object != nil else { return request.unreadable() }
        let n = ProviderRequest.number
        var spent: Spent?
        if let day = n(info["usage_daily"]), let week = n(info["usage_weekly"]), let month = n(info["usage_monthly"]) {
            spent = Spent(today: day, week: week, month: month)
        }
        // Credits left on the account need a management key; a regular key falls back to its own limit.
        var amount = n(info["limit_remaining"])
        if case .success(let credits) = await request.get(URL(string: "https://\(host)/api/v1/credits")!,
                                                           headers: headers, http: http),
           let total = n(credits["data"]?["total_credits"]), let used = n(credits["data"]?["total_usage"]) {
            amount = total - used
        }
        return .balance(amount: amount, currency: "USD", spent: spent)
    }
}
