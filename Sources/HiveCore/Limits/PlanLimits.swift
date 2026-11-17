import Foundation

/// The `/api/limits` card shape: `{id, title, kind, state, windows?, balance?, spent?, updatedAt, message?}`.
/// `state` is `ok`, `stale`, `error`, `unavailable` or `not-set-up`; times are Unix seconds.
public enum PlanCards {
    /// Figures older than this are marked stale.
    public static let staleAfter: TimeInterval = 5 * 3600

    static func card(id: String, title: String, kind: String, state: String, windows: [JSON]? = nil,
                     balance: JSON? = nil, spent: JSON? = nil, updatedAt: Int? = nil, message: String? = nil,
                     extra: KeyValuePairs<String, JSON> = [:]) -> JSON {
        var o = JSONObject(["id": .string(id), "title": .string(title), "kind": .string(kind), "state": .string(state)])
        if let windows { o["windows"] = .array(windows) }
        if let balance { o["balance"] = balance }
        if let spent { o["spent"] = spent }
        o["updatedAt"] = JSON(updatedAt)
        if let message { o["message"] = .string(message) }
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    static func window(_ label: String, used: JSON, resetsAt: Int?) -> JSON {
        ["label": .string(label), "usedPercent": used, "resetsAt": JSON(resetsAt)]
    }

    /// Drops windows that have reset since they were reported, and says whether what's left is stale.
    static func current(_ windows: [(json: JSON, resetsAt: Int?)], updatedAt: Int, now: Date) -> (windows: [JSON], stale: Bool) {
        let t = Int(now.timeIntervalSince1970)
        let live = windows.filter { ($0.resetsAt ?? Int.max) > t }.map(\.json)
        return (live, live.isEmpty || now.timeIntervalSince1970 - Double(updatedAt) > staleAfter)
    }

    public static func antigravity() -> JSON {
        card(id: "antigravity", title: "Antigravity", kind: "plan", state: "unavailable",
             message: "Antigravity doesn't share its limits on this Mac.")
    }
}

/// The Claude plan's 5-hour and weekly windows, saved by the opt-in status line script.
public enum ClaudeLimits {
    static let labels = [("five_hour", "5-hour"), ("seven_day", "Weekly"), ("spend_limit", "Spend limit")]

    public static func read(paths: HivePaths, now: Date) -> JSON {
        let installed = StatusLineInstaller(paths: paths).isInstalled
        let extra: KeyValuePairs<String, JSON> = ["installed": .bool(installed)]
        guard let data = FileManager.default.contents(atPath: paths.claudeLimitsFile.path),
              let saved = try? JSON.parse(data), let limits = saved["rate_limits"]?.object,
              let savedAt = saved["savedAt"]?.int else {
            if installed {
                return PlanCards.card(id: "claude", title: "Claude plan", kind: "plan", state: "unavailable",
                                      message: "Waiting for a Claude Code session in a terminal to report your limits.",
                                      extra: extra)
            }
            return PlanCards.card(id: "claude", title: "Claude plan", kind: "plan", state: "not-set-up",
                                  message: "Set up the Claude status line to see your plan limits. It updates while you use Claude Code in a terminal.",
                                  extra: extra)
        }
        var windows: [(JSON, Int?)] = []
        for (key, label) in labels {
            guard let w = limits[key], let used = w["used_percentage"], used.number != nil else { continue }
            let resets = w["resets_at"]?.number.map { Int($0) }
            windows.append((PlanCards.window(label, used: used, resetsAt: resets), resets))
        }
        let (live, stale) = PlanCards.current(windows, updatedAt: savedAt, now: now)
        return PlanCards.card(id: "claude", title: "Claude plan", kind: "plan", state: stale ? "stale" : "ok",
                              windows: live, updatedAt: savedAt,
                              message: stale ? "Last reported by a Claude Code session in a terminal." : nil,
                              extra: extra)
    }
}

/// Codex's primary and secondary windows, from the latest `token_count` event that carried `rate_limits` in the
/// newest `~/.codex/sessions/**/rollout-*.jsonl`.
///
/// Shape (codex-rs, checked 2026-11-17: https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs
/// `TokenCountEvent`, `RateLimitSnapshot`, `RateLimitWindow`; rollout envelope in codex-rs/history/src/rollout_payload.rs;
/// token_count events are persisted per codex-rs/rollout/src/policy.rs):
/// `{"timestamp": "...Z", "type": "event_msg", "payload": {"type": "token_count", "info": ..., "rate_limits":
/// {"primary": {"used_percent": 0-100, "window_minutes": n|null, "resets_at": unix s|null}, "secondary": ...,
/// "plan_type": ...}}}`. Older Codex versions wrote `resets_in_seconds` instead of `resets_at`.
public enum CodexLimits {
    static let tailBytes = 512 * 1024

    public static func label(minutes: Int?) -> String {
        guard let m = minutes, m > 0 else { return "Window" }
        if m == 10_080 { return "Weekly" }
        if m % 1440 == 0 { return "\(m / 1440)-day" }
        if m % 60 == 0 { return "\(m / 60)-hour" }
        return "\(m)-minute"
    }

    public static func read(paths: HivePaths, now: Date) -> JSON {
        for file in newestRollouts(paths.codexSessions, limit: 5) {
            guard let (event, time) = latestRateLimits(file) else { continue }
            var windows: [(JSON, Int?)] = []
            for key in ["primary", "secondary"] {
                guard let w = event[key], let used = w["used_percent"], used.number != nil else { continue }
                var resets = w["resets_at"]?.number.map { Int($0) }
                if resets == nil, let left = w["resets_in_seconds"]?.number { resets = time + Int(left) }
                let minutes = w["window_minutes"]?.number.map { Int($0) }
                windows.append((PlanCards.window(label(minutes: minutes), used: used, resetsAt: resets), resets))
            }
            guard !windows.isEmpty else { continue }
            let (live, stale) = PlanCards.current(windows, updatedAt: time, now: now)
            return PlanCards.card(id: "codex", title: "Codex plan", kind: "plan", state: stale ? "stale" : "ok",
                                  windows: live, updatedAt: time,
                                  message: stale ? "From your last Codex session." : nil)
        }
        return PlanCards.card(id: "codex", title: "Codex plan", kind: "plan", state: "unavailable",
                              message: "No Codex session has reported limits yet.")
    }

    /// Rollout files, most recently changed first (newest name first on a tie).
    static func newestRollouts(_ root: URL, limit: Int) -> [URL] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var found: [(URL, Date)] = []
        for case let url as URL in e where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            found.append((url, date))
        }
        found.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.lastPathComponent > $1.0.lastPathComponent }
        return found.prefix(limit).map(\.0)
    }

    /// The last `rate_limits` object in a rollout's tail, with its line's time.
    static func latestRateLimits(_ file: URL) -> (JSON, Int)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let json = try? JSON.parse(String(line)), json["type"] == "event_msg",
                  json["payload"]?["type"] == "token_count", let limits = json["payload"]?["rate_limits"],
                  limits.object != nil else { continue }
            let stamp = json["timestamp"]?.string ?? ""
            let date = (try? Date(stamp, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
                ?? (try? Date(stamp, strategy: .iso8601))
            guard let date else { continue }
            return (limits, Int(date.timeIntervalSince1970))
        }
        return nil
    }
}
