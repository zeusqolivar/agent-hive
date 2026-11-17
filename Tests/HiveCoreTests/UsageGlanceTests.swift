import Foundation
import Testing
@testable import HiveCore

@Suite struct UsageGlanceTests {
    static func card(_ id: String, _ title: String, _ state: String, message: String? = nil, windows: [JSON]? = nil,
                     balance: JSON? = nil, spent: JSON? = nil) -> JSON {
        var o = JSONObject()
        o["id"] = .string(id); o["title"] = .string(title); o["state"] = .string(state)
        if let message { o["message"] = .string(message) }
        if let windows { o["windows"] = .array(windows) }
        if let balance { o["balance"] = balance }
        if let spent { o["spent"] = spent }
        return .object(o)
    }

    static func window(_ label: String, _ used: Double) -> JSON {
        var w = JSONObject()
        w["label"] = JSON.string(label)
        w["usedPercent"] = JSON.double(used)
        return .object(w)
    }

    @Test func menuBarBadgeUsesTheMostPressedMeter() {
        let cards: JSON = ["cards": .array([
            Self.card("claude", "Claude plan", "ok", windows: [Self.window("Weekly", 51), Self.window("Session", 12)]),
            Self.card("codex", "Codex plan", "ok", windows: [Self.window("Weekly", 76)]),
            Self.card("antigravity", "Antigravity", "unavailable"),
        ])]
        let rows = UsageGlance.from(cards)
        #expect(rows[0].peakUsed == 51)
        #expect(rows.peakUsed == 76)
        #expect(UsageGlance.tier(10) == .normal)
        #expect(UsageGlance.tier(75) == .high)
        #expect(UsageGlance.tier(90) == .critical)
    }

    @Test func everyPlanShowsEvenWithNoNumbers() {
        let cards: JSON = ["cards": .array([
            Self.card("claude", "Claude plan", "not-set-up"),
            Self.card("codex", "Codex plan", "unavailable", message: "No Codex session has reported limits yet."),
            Self.card("antigravity", "Antigravity", "unavailable", message: "Antigravity doesn't share its limits on this Mac."),
            Self.card("deepseek", "DeepSeek", "not-set-up"),
            Self.card("openai", "OpenAI", "not-set-up"),
        ])]
        let rows = UsageGlance.from(cards)
        #expect(rows.map(\.id) == ["claude", "codex", "antigravity", "keys"])
        #expect(rows[0].action == .setUpClaude)
        #expect(rows[1].body == .note("No sessions yet"))
        #expect(rows[2].body == .note("Doesn't share its limits"))
        #expect(rows[3].action == .addKeys)
    }

    @Test func numbersWhenThereAreSome() {
        let windows: [JSON] = [["label": "5-hour", "usedPercent": 31.6, "resetsAt": 1_800_000_000],
                               ["label": "Weekly", "usedPercent": 120.0]]
        let cards: JSON = ["cards": .array([
            Self.card("claude", "Claude plan", "ok", windows: windows),
            Self.card("deepseek", "DeepSeek", "ok", balance: ["amount": 4.12, "currency": "USD"],
                      spent: ["today": 0.5, "currency": "USD"]),
            Self.card("openai", "OpenAI", "stale", spent: ["today": 1.5, "week": 9.25, "currency": "usd"]),
            Self.card("openrouter", "OpenRouter", "error", message: "OpenRouter rejected this key."),
            Self.card("anthropic", "Anthropic", "not-set-up"),
        ])]
        let rows = UsageGlance.from(cards)
        #expect(rows.map(\.id) == ["claude", "deepseek", "openai", "openrouter"])
        #expect(rows[0].body == .meters([
            .init(label: "5-hour", used: 31.6, resetsAt: Date(timeIntervalSince1970: 1_800_000_000)),
            .init(label: "Weekly", used: 100, resetsAt: nil),
        ]))
        #expect(rows[1].body == .amount("$4.12", caption: "Balance · $0.50 spent today"))
        #expect(rows[2].body == .amount("$1.50", caption: "Spent today · $9.25 this week"))
        #expect(rows[2].stale)
        #expect(rows[3].problem && rows[3].body == .note("OpenRouter rejected this key."))
    }
}
