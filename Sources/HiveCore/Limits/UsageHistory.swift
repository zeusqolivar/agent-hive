import Foundation

/// Balance snapshots for services that report a balance but no history (DeepSeek, OpenRouter). Spending
/// for a period is estimated as the sum of the drops between consecutive snapshots that end in it; a rise is
/// a top-up and isn't counted. Kept for 60 days in `usage-history.json`: services, times and balances only.
public struct UsageHistory: Sendable {
    public struct Entry: Sendable, Equatable {
        public var service: String
        public var time: Date
        public var balance: Double
        public var currency: String
    }

    public static let keep: TimeInterval = 60 * 86_400
    let file: URL

    public init(file: URL) {
        self.file = file
    }

    public func entries() -> [Entry] {
        guard let data = FileManager.default.contents(atPath: file.path), let json = try? JSON.parse(data) else { return [] }
        return (json["entries"]?.array ?? []).compactMap { e in
            guard let service = e["service"]?.string, let time = e["time"]?.number, let balance = e["balance"]?.number
            else { return nil }
            return Entry(service: service, time: Date(timeIntervalSince1970: time), balance: balance,
                         currency: e["currency"]?.string ?? "")
        }
    }

    public func append(service: String, balance: Double, currency: String, at time: Date) throws {
        var all = entries().filter { time.timeIntervalSince($0.time) <= Self.keep }
        all.append(Entry(service: service, time: time, balance: balance, currency: currency))
        all.sort { $0.time < $1.time }
        let json: JSON = ["entries": .array(all.map {
            ["service": .string($0.service), "time": .int(Int($0.time.timeIntervalSince1970)),
             "balance": .double($0.balance), "currency": .string($0.currency)]
        })]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.serialized(indent: 1).write(to: file, options: .atomic)
    }

    /// The sum of balance drops whose later snapshot falls in `(from, to]`.
    public func spent(service: String, from: Date, to: Date) -> Double {
        let mine = entries().filter { $0.service == service }.sorted { $0.time < $1.time }
        var total = 0.0
        for (a, b) in zip(mine, mine.dropFirst()) where b.time > from && b.time <= to && a.currency == b.currency {
            if b.balance < a.balance { total += a.balance - b.balance }
        }
        return (total * 1_000_000).rounded() / 1_000_000
    }

    public func spent(service: String, now: Date) -> Spent {
        let p = Spending.periods(now: now)
        // Periods start at midnight UTC; a snapshot exactly at the boundary belongs to the new period.
        let edge: TimeInterval = 0.001
        return Spent(today: spent(service: service, from: p.today.addingTimeInterval(-edge), to: now),
                     week: spent(service: service, from: p.week.addingTimeInterval(-edge), to: now),
                     month: spent(service: service, from: p.month.addingTimeInterval(-edge), to: now))
    }
}
