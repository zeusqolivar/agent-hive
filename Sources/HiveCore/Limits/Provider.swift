import Foundation

/// What one check of a usage service found. Messages are short, written for the card, and never include the
/// key or the service's own error text (which can quote part of the key).
public enum ProviderResult: Sendable, Equatable {
    /// Money left (nil when the service doesn't say), and spending when the service reports it itself.
    case balance(amount: Double?, currency: String, spent: Spent?)
    /// Cost per UTC day.
    case cost(daily: [DailyCost], currency: String)
    /// The service refused the key: automatic checks pause until the key changes or Refresh is clicked.
    case authFailed(String)
    case failed(String)
}

public struct DailyCost: Sendable, Equatable {
    /// The start of the UTC day.
    public var day: Date
    public var amount: Double

    public init(day: Date, amount: Double) {
        self.day = day
        self.amount = amount
    }
}

/// Spending today, this week (from Monday) and this month, in UTC.
public struct Spent: Sendable, Equatable {
    public var today: Double
    public var week: Double
    public var month: Double

    public init(today: Double, week: Double, month: Double) {
        self.today = today
        self.week = week
        self.month = month
    }
}

/// A service that reports a balance or costs for an API key.
public protocol UsageProvider: Sendable {
    /// The Keychain account name and card id: `deepseek`, `openrouter`, `openai`, `anthropic`.
    var id: String { get }
    var title: String { get }
    /// The only host the key is ever sent to.
    var host: String { get }
    /// What kind of key Settings asks for.
    var keyKind: String { get }
    func fetch(key: String, http: HTTPClient, now: Date) async -> ProviderResult
}

public enum UsageProviders {
    public static let all: [UsageProvider] = [DeepSeekProvider(), OpenRouterProvider(), OpenAIProvider(), AnthropicProvider()]
}

/// UTC day, week and month boundaries, shared by the cost providers and the balance-history estimates.
public enum Spending {
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    public static func periods(now: Date) -> (today: Date, week: Date, month: Date) {
        let today = utc.startOfDay(for: now)
        let weekday = utc.component(.weekday, from: today)  // 1 = Sunday
        let week = today.addingTimeInterval(-86_400 * Double((weekday + 5) % 7))
        let month = utc.date(from: utc.dateComponents([.year, .month], from: today)) ?? today
        return (today, week, month)
    }

    /// The earliest day a check needs: the start of the week or of the month, whichever is first.
    public static func earliest(now: Date) -> Date {
        let p = periods(now: now)
        return min(p.week, p.month)
    }

    public static func spent(_ daily: [DailyCost], now: Date) -> Spent {
        let p = periods(now: now)
        let end = p.today.addingTimeInterval(86_400)
        func sum(_ from: Date) -> Double {
            daily.filter { $0.day >= from && $0.day < end }.reduce(0) { $0 + $1.amount }
        }
        return Spent(today: sum(p.today), week: sum(p.week), month: sum(p.month))
    }
}

/// One GET to a provider, with the checks every provider shares: only its own host, and errors turned into
/// short messages.
struct ProviderRequest: Sendable {
    enum Outcome {
        case success(JSON)
        case failure(ProviderResult, status: Int)
    }

    let title: String
    let host: String

    func get(_ url: URL, headers: [String: String], http: HTTPClient) async -> Outcome {
        guard url.scheme == "https", url.host == host else {
            return .failure(.failed("Agent Hive only sends this key to \(host)."), status: 0)
        }
        let status: Int
        let body: Data
        do {
            (status, body) = try await http.get(url, headers: headers)
        } catch {
            return .failure(.failed("Couldn't reach \(title)."), status: 0)
        }
        switch status {
        case 401, 403: return .failure(.authFailed("\(title) rejected this key."), status: status)
        case 429: return .failure(.failed("\(title) is limiting requests. Agent Hive will try again later."), status: status)
        case 200..<300: break
        default: return .failure(.failed("\(title) answered with HTTP \(status)."), status: status)
        }
        guard let json = try? JSON.parse(body), json.object != nil else {
            return .failure(.failed("\(title) sent an answer Agent Hive couldn't read."), status: status)
        }
        if let error = json["error"], !error.isNull {
            if let code = error["code"]?.int, code == 401 || code == 403 {
                return .failure(.authFailed("\(title) rejected this key."), status: code)
            }
            return .failure(.failed("\(title) reported an error."), status: status)
        }
        return .success(json)
    }

    func unreadable() -> ProviderResult { .failed("\(title) sent an answer Agent Hive couldn't read.") }

    /// A number, or a number written as a string (DeepSeek and Anthropic send amounts as strings).
    static func number(_ value: JSON?) -> Double? {
        if let n = value?.number { return n }
        if let s = value?.string { return Double(Text.strip(s)) }
        return nil
    }

    /// `a=b&c=d`, keeping `:` readable (as the providers' docs write timestamps) and escaping the rest.
    static func query(_ items: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~:")
        return items.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }
}
