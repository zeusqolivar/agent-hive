import Foundation

/// How Agent Hive keeps the Mac from sleeping on its own.
public enum KeepAwakeMode: String, CaseIterable, Sendable {
    case off, whileWorking, always, oneHour

    /// A value read back from settings; anything unknown means off.
    public init(stored: String?) {
        self = stored.flatMap(KeepAwakeMode.init(rawValue:)) ?? .off
    }

    public var title: String {
        switch self {
        case .off: "Off"
        case .whileWorking: "While agents are working"
        case .always: "Always"
        case .oneHour: "For 1 hour"
        }
    }
}

/// When to hold the Mac awake. Pure rules, so the app only has to apply the answer.
public enum KeepAwakePolicy {
    public static let oneHour: TimeInterval = 3600

    /// `whileWorking` covers sessions that are working or waiting on you, so nothing sleeps mid-task.
    public static func shouldStayAwake(mode: KeepAwakeMode, working: Int, needsYou: Int, now: Date, until: Date?) -> Bool {
        switch mode {
        case .off: false
        case .always: true
        case .whileWorking: working + needsYou > 0
        case .oneHour: until.map { now < $0 } ?? false
        }
    }

    public static func oneHourFrom(_ now: Date) -> Date { now.addingTimeInterval(oneHour) }

    /// The one-hour mode has run out and should switch itself off.
    public static func expired(mode: KeepAwakeMode, now: Date, until: Date?) -> Bool {
        mode == .oneHour && !(until.map { now < $0 } ?? false)
    }

    public static func minutesLeft(now: Date, until: Date) -> Int {
        max(0, Int((until.timeIntervalSince(now) / 60).rounded(.up)))
    }
}
