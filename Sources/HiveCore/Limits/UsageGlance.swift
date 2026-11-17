import Foundation

/// One usage source as the menu bar panel shows it: bars for plan windows, an amount for API keys, or a short
/// note saying what the source needs. Built from the `/api/limits` cards, so the panel and the Usage tab agree.
public struct UsageGlance: Sendable, Equatable, Identifiable {
    public struct Meter: Sendable, Equatable {
        public var label: String
        /// 0 to 100.
        public var used: Double
        public var resetsAt: Date?

        public init(label: String, used: Double, resetsAt: Date?) {
            self.label = label
            self.used = used
            self.resetsAt = resetsAt
        }
    }

    public enum Body: Sendable, Equatable {
        case meters([Meter])
        case amount(String, caption: String)
        case note(String)
    }

    public enum Action: Sendable, Equatable {
        /// Set up the Claude status line.
        case setUpClaude
        /// Add API keys in Settings.
        case addKeys
    }

    public var id: String
    public var title: String
    public var body: Body
    /// The numbers are older than they should be, or the last check failed.
    public var stale = false
    public var problem = false
    public var action: Action?

    public init(id: String, title: String, body: Body, stale: Bool = false, problem: Bool = false,
                action: Action? = nil) {
        self.id = id
        self.title = title
        self.body = body
        self.stale = stale
        self.problem = problem
        self.action = action
    }

    static let plans: Set<String> = ["claude", "codex", "antigravity"]

    /// Plan sources always appear; API-key services appear once they have a key. With no keys at all, one
    /// "API keys" row offers to add them.
    public static func from(_ cards: JSON) -> [UsageGlance] {
        var rows: [UsageGlance] = []
        var anyService = false, anyKey = false
        for card in cards["cards"]?.array ?? [] {
            let id = card["id"]?.string ?? "", title = card["title"]?.string ?? id
            let isPlan = plans.contains(id)
            let state = card["state"]?.string ?? ""
            if !isPlan { anyService = true }
            if !isPlan && state == "not-set-up" { continue }
            if !isPlan { anyKey = true }
            var row = UsageGlance(id: id, title: title, body: .note(""))
            row.stale = state == "stale"
            switch state {
            case "not-set-up":
                row.body = .note("Not set up")
                if id == "claude" { row.action = .setUpClaude }
            case "error":
                row.body = .note(card["message"]?.string ?? "Couldn't check")
                row.problem = true
            case "unavailable":
                row.body = .note(id == "antigravity" ? "Doesn't share its limits"
                                 : id == "claude" ? "Waiting for a terminal session"
                                 : isPlan ? "No sessions yet" : "Not checked yet")
            default:
                if let windows = card["windows"]?.array, !windows.isEmpty {
                    row.body = .meters(windows.compactMap { w in
                        guard let label = w["label"]?.string, let used = w["usedPercent"]?.number else { return nil }
                        return Meter(label: label, used: min(max(used, 0), 100),
                                     resetsAt: w["resetsAt"]?.number.map { Date(timeIntervalSince1970: $0) })
                    })
                } else if let amount = card["balance"]?["amount"]?.number {
                    let currency = card["balance"]?["currency"]?.string ?? "USD"
                    var caption = "Balance"
                    if let today = card["spent"]?["today"]?.number, today > 0 {
                        caption = "Balance · \(LimitsService.format(today, currency)) spent today"
                    }
                    row.body = .amount(LimitsService.format(amount, currency), caption: caption)
                } else if let spent = card["spent"] {
                    let currency = spent["currency"]?.string ?? "USD"
                    let today = spent["today"]?.number ?? 0, week = spent["week"]?.number ?? 0
                    row.body = .amount(LimitsService.format(today, currency),
                                       caption: "Spent today · \(LimitsService.format(week, currency)) this week")
                } else {
                    row.body = .note(card["message"]?.string ?? "No numbers yet")
                }
            }
            rows.append(row)
        }
        if anyService && !anyKey {
            rows.append(UsageGlance(id: "keys", title: "API keys", body: .note("None added"), action: .addKeys))
        }
        return rows
    }
}

public extension UsageGlance {
    /// The highest meter percentage this row reports, or nil for rows that aren't plan windows.
    var peakUsed: Double? {
        guard case .meters(let meters) = body else { return nil }
        return meters.map(\.used).max()
    }

    /// How pressed a source is: blue under 75%, orange from 75%, red from 90%. The menu bar badge and the
    /// panel's meter bars use the same thresholds, so the two always agree.
    static func tier(_ used: Double) -> UsageTier {
        used >= 90 ? .critical : used >= 75 ? .high : .normal
    }
}

public enum UsageTier: Sendable, Equatable {
    case normal, high, critical
}

public extension Array where Element == UsageGlance {
    /// The most-pressed plan meter across every source — what the menu bar badge shows at a glance.
    var peakUsed: Double? { compactMap(\.peakUsed).max() }
}
