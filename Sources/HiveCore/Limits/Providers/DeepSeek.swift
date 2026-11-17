// DeepSeek balance.
// Docs (checked 2026-11-17): https://api-docs.deepseek.com/api/get-user-balance
//   GET https://api.deepseek.com/user/balance, header `Authorization: Bearer <API key>`.
//   200: {"is_available": bool, "balance_infos": [{"currency": "CNY"|"USD", "total_balance": "110.00",
//         "granted_balance": "10.00", "topped_up_balance": "100.00"}]}; amounts are strings.
import Foundation

public struct DeepSeekProvider: UsageProvider {
    public let id = "deepseek"
    public let title = "DeepSeek"
    public let host = "api.deepseek.com"
    public let keyKind = "API key"

    public init() {}

    public func fetch(key: String, http: HTTPClient, now: Date) async -> ProviderResult {
        let request = ProviderRequest(title: title, host: host)
        let url = URL(string: "https://\(host)/user/balance")!
        switch await request.get(url, headers: ["Authorization": "Bearer \(key)", "Accept": "application/json"], http: http) {
        case .failure(let result, _):
            return result
        case .success(let json):
            let balances: [(currency: String, amount: Double)] = (json["balance_infos"]?.array ?? []).compactMap {
                guard let currency = $0["currency"]?.string, let amount = ProviderRequest.number($0["total_balance"])
                else { return nil }
                return (currency, amount)
            }
            // One card shows one balance: the first currency with money in it, else the first.
            guard let pick = balances.first(where: { $0.amount > 0 }) ?? balances.first else { return request.unreadable() }
            return .balance(amount: pick.amount, currency: pick.currency, spent: nil)
        }
    }
}
