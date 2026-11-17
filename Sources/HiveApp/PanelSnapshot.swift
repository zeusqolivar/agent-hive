import AppKit
import HiveCore
import SwiftUI

/// `HiveApp --panel-snapshot <file.png> [--sample] [--dark]` draws the menu bar panel into a PNG and exits, for
/// checking its layout and for the README. `--sample` uses made-up sessions and numbers instead of yours.
@MainActor
enum PanelSnapshot {
    static func runIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--panel-snapshot"), i + 1 < args.count else { return }
        let out = URL(filePath: args[i + 1])
        _ = NSApplication.shared
        let model = AppModel(live: false)
        if args.contains("--sample") { fillSample(model) } else { fillReal(model) }

        let host = NSHostingView(rootView: MenuBarPanel(model: model)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: args.contains("--dark") ? .darkAqua : .aqua)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
        do { try png.write(to: out) } catch { exit(1) }
        print("wrote \(out.path) (\(Int(size.width))x\(Int(size.height)))")
        exit(0)
    }

    private static func fillSample(_ model: AppModel) {
        model.needsYou = 2
        model.working = 3
        model.waiting = [
            .init(id: "a", name: "Checkout redesign", headline: "Asks whether to keep the old payment sheet or ship the new one"),
            .init(id: "b", name: "API docs", headline: "Waiting for permission to run the docs build"),
        ]
        model.busy = [
            .init(id: "c", name: "Search tests", headline: "Running the test suite"),
            .init(id: "d", name: "Onboarding copy", headline: "Editing WelcomeView.swift"),
        ]
        let now = Date()
        model.usage = [
            UsageGlance(id: "claude", title: "Claude plan", body: .meters([
                .init(label: "5-hour", used: 34, resetsAt: now.addingTimeInterval(2 * 3600 + 600)),
                .init(label: "Weekly", used: 78, resetsAt: now.addingTimeInterval(3 * 86400)),
            ])),
            UsageGlance(id: "codex", title: "Codex plan", body: .meters([
                .init(label: "5-hour", used: 12, resetsAt: now.addingTimeInterval(4 * 3600)),
                .init(label: "Weekly", used: 93, resetsAt: now.addingTimeInterval(86400)),
            ])),
            UsageGlance(id: "antigravity", title: "Antigravity", body: .note("Doesn't share its limits")),
            UsageGlance(id: "deepseek", title: "DeepSeek", body: .amount("$4.12", caption: "Balance · $0.38 spent today")),
            UsageGlance(id: "openai", title: "OpenAI", body: .amount("$1.50", caption: "Spent today · $9.25 this week")),
        ]
    }

    private static func fillReal(_ model: AppModel) {
        let done = DispatchSemaphore(value: 0)
        let services = Services.make(start: false)
        nonisolated(unsafe) var cards: JSON = [:]
        nonisolated(unsafe) var rows: [BoardRow] = []
        Task.detached {
            await services.board.refresh()
            rows = await services.board.snapshot().rows
            cards = await services.limits.cards()
            done.signal()
        }
        done.wait()
        let needs = rows.filter { $0.group == "needs" }, working = rows.filter { $0.group == "working" }
        model.needsYou = needs.count
        model.working = working.count
        model.waiting = needs.prefix(5).map { .init(id: $0.id, name: $0.name, headline: $0.headline) }
        model.busy = working.prefix(3).map { .init(id: $0.id, name: $0.name, headline: $0.headline) }
        model.usage = UsageGlance.from(cards)
    }
}
