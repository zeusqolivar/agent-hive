import HiveCore
import AppKit
import SwiftUI

/// The menu bar extra: a hexagon with the number of sessions that need you, and a colour-coded usage badge
/// that fills in proportion to the most-pressed plan window (blue → orange at 75% → red at 90%).
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: model.needsYou > 0 ? "hexagon.fill" : "hexagon")
            if let used = model.usage.peakUsed {
                Text(usageText(used)).monospacedDigit().font(.caption)
            }
            if model.needsYou > 0 { Text("\(model.needsYou)").monospacedDigit() }
            if model.keepingAwake { Image(systemName: "cup.and.saucer.fill") }
        }
        .accessibilityLabel(accessibilityText)
    }

    /// The percentage, coloured by how close the plan is to its limit. An attributed string, because the
    /// menu bar tints plain Text and plain Images monochrome and drops custom images entirely.
    private func usageText(_ used: Double) -> AttributedString {
        var text = AttributedString("\(Int(used.rounded()))%")
        text.foregroundColor = UsageBadge.tint(UsageGlance.tier(used))
        return text
    }

    private var accessibilityText: String {
        var parts = [model.needsYou == 1 ? "Agent Hive, 1 session needs you"
                                         : "Agent Hive, \(model.needsYou) sessions need you"]
        if let used = model.usage.peakUsed { parts.append("\(Int(used.rounded())) percent of your highest plan limit used") }
        if model.keepingAwake { parts.append("keeping the Mac awake") }
        return parts.joined(separator: ", ")
    }
}

/// The menu bar's usage badge: a capsule track with a coloured fill. Drawn as a non-template image, because
/// the system tints template images monochrome and the whole point is that the colour carries the warning.
enum UsageBadge {
    static func tint(_ tier: UsageTier) -> Color {
        switch tier {
        case .normal: .blue
        case .high: .orange
        case .critical: .red
        }
    }

    static func color(for tier: UsageTier) -> NSColor {
        switch tier {
        case .normal: .systemBlue
        case .high: .systemOrange
        case .critical: .systemRed
        }
    }

    static func image(used: Double, tier: UsageTier) -> NSImage {
        let size = NSSize(width: 24, height: 11), barHeight: CGFloat = 6, scale: CGFloat = 2
        // A real bitmap, not a lazy drawingHandler: the menu bar's snapshot does not reliably invoke the
        // handler, and the badge then renders as nothing at all.
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let bar = NSRect(x: 0, y: (size.height - barHeight) / 2, width: size.width, height: barHeight)
        NSColor.secondaryLabelColor.withAlphaComponent(0.4).setFill()
        NSBezierPath(roundedRect: bar, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()

        let fraction = max(0.12, min(1, used / 100))
        let filled = NSRect(x: 0, y: bar.minY, width: max(barHeight, size.width * fraction), height: barHeight)
        color(for: tier).setFill()
        NSBezierPath(roundedRect: filled, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = false
        return image
    }
}

/// What opens from the menu bar icon: a panel showing, at a glance, the sessions that need you, what's
/// working, every usage source with its numbers, and keeping the Mac awake. Nothing hides in a submenu.
struct MenuBarPanel: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            // No scroll view: inside the menu bar window one collapses to zero height. The lists are capped
            // instead (five sessions waiting, five working), so the panel stays a sensible height.
            content
            Divider()
            keepAwake
            Divider()
            footer
        }
        .frame(width: 340)
        .task { if model.live { await model.refreshUsageState() } }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            usage
            sessions
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Agent Hive").font(.headline)
                Text(statusLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusLine: String {
        var parts: [String] = []
        if model.needsYou > 0 { parts.append(model.needsYou == 1 ? "1 needs you" : "\(model.needsYou) need you") }
        if model.working > 0 { parts.append("\(model.working) working") }
        return parts.isEmpty ? "No sessions are busy" : parts.joined(separator: ", ")
    }

    // MARK: Sessions

    @ViewBuilder private var sessions: some View {
        if model.waiting.isEmpty && model.busy.isEmpty {
            Label("Nothing needs you right now", systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if !model.waiting.isEmpty {
            section("Needs you") {
                ForEach(model.waiting) { session in
                    SessionRow(session: session, needsYou: true) { show("#/agents/\(session.id)") }
                }
                if model.needsYou > model.waiting.count {
                    moreButton(model.needsYou - model.waiting.count)
                }
            }
        }
        if !model.busy.isEmpty {
            section("Working") {
                ForEach(model.busy) { session in
                    SessionRow(session: session, needsYou: false) { show("#/agents/\(session.id)") }
                }
                if model.working > model.busy.count {
                    moreButton(model.working - model.busy.count)
                }
            }
        }
    }

    private func moreButton(_ count: Int) -> some View {
        Button("\(count) more") { show(nil) }
            .buttonStyle(.link)
            .font(.caption)
            .padding(.leading, 26)
    }

    // MARK: Usage

    private var usage: some View {
        section("Usage", trailing: {
            Button {
                Task { await model.checkUsageNow() }
            } label: {
                if model.refreshingUsage {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(model.refreshingUsage)
            .help("Check now")
            .accessibilityLabel("Check usage now")
        }) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.usage) { row in
                    UsageRow(row: row) { action in
                        switch action {
                        case .setUpClaude: Task { await model.setStatusLine(installed: true) }
                        case .addKeys: settings()
                        }
                    } open: { show("#/usage") }
                }
            }
            if let error = model.statusLineError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: Keep awake and footer

    private var keepAwake: some View {
        HStack {
            Label(model.keepingAwake ? "Keeping Mac awake" : "Keep Mac awake",
                  systemImage: model.keepingAwake ? "cup.and.saucer.fill" : "cup.and.saucer")
                .font(.callout)
                .lineLimit(1)
                .fixedSize()
            Spacer()
            Picker("Keep Mac awake", selection: $model.keepAwakeMode) {
                ForEach(KeepAwakeMode.allCases, id: \.self) { mode in
                    Text(shortTitle(mode)).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var footer: some View {
        HStack {
            Button("Open Agent Hive") { show(nil) }
                .buttonStyle(.bordered)
                .keyboardShortcut("o")
            Spacer()
            Button { settings() } label: { Image(systemName: "gearshape") }
                .help("Settings")
                .accessibilityLabel("Settings")
                .keyboardShortcut(",")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help("Quit Agent Hive")
                .accessibilityLabel("Quit Agent Hive")
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Helpers

    /// Shorter than the menu's titles, so the picker fits beside its label.
    private func shortTitle(_ mode: KeepAwakeMode) -> String {
        switch mode {
        case .off: "Off"
        case .whileWorking: "While working"
        case .always: "Always"
        case .oneHour: model.minutesLeft.map { "1 hour (\($0) min left)" } ?? "For 1 hour"
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        section(title, trailing: { EmptyView() }, content: content)
    }

    private func section<Trailing: View, Content: View>(_ title: String, @ViewBuilder trailing: () -> Trailing,
                                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                trailing()
            }
            content()
        }
    }

    private func show(_ route: String?) {
        model.route = route
        openWindow(id: "main")
        NSApp.activate()
    }

    private func settings() {
        NSApp.activate()
        openSettings()
    }
}

/// A session in the panel: who it is and, in a line or two, what it's doing or asking.
private struct SessionRow: View {
    let session: AppModel.Waiting
    let needsYou: Bool
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: needsYou ? "hand.raised.fill" : "circle.fill")
                    .font(needsYou ? .callout : .system(size: 7))
                    .foregroundStyle(needsYou ? Color.orange : Color.green)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(session.name).font(.callout.weight(.medium)).lineLimit(1)
                        AgentTag(agent: session.agent)
                    }
                    Text(session.headline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(needsYou ? 2 : 1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.07) : .clear, in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, -6)
        .accessibilityLabel("\(session.name), \(session.agent), \(session.headline)")
        .accessibilityHint("Opens this session in Agent Hive")
    }
}

/// A usage source: a plan's windows as bars with a one-line summary, an API key's amount, or what it needs.
private struct UsageRow: View {
    let row: UsageGlance
    let act: (UsageGlance.Action) -> Void
    let open: () -> Void

    var body: some View {
        switch row.body {
        case .meters(let meters):
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    title.font(.subheadline).foregroundStyle(.secondary)
                    if let top = meters.max(by: { $0.used < $1.used }) {
                        Text("\(Int(top.used.rounded()))% of your \(Self.limitName(top.label)) used.")
                            .font(.headline)
                    }
                }
                Divider()
                ForEach(meters, id: \.label) { MeterRow(meter: $0) }
            }
        case .amount(let amount, let caption):
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    title.font(.callout)
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(amount).font(.headline).monospacedDigit()
            }
        case .note(let note):
            HStack(alignment: .firstTextBaseline) {
                title.font(.callout)
                Spacer(minLength: 12)
                if let action = row.action {
                    Button(action == .setUpClaude ? "Set up" : "Add keys") { act(action) }
                        .controlSize(.small)
                } else {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(row.problem ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }
            }
        }
    }

    /// "Weekly" → "weekly limit", "Spend limit" → "spend limit".
    static func limitName(_ label: String) -> String {
        let name = label.lowercased()
        return name.hasSuffix("limit") ? name : name + " limit"
    }

    private var title: some View {
        HStack(spacing: 4) {
            Text(row.title)
            if row.stale {
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("These numbers are from an earlier check.")
                    .accessibilityLabel("From an earlier check")
            }
        }
        .onTapGesture(perform: open)
    }
}

/// One plan window: its name and the percentage used, a bar that turns orange from 75% and red from 90%, and
/// when it resets. Stacked rather than in columns, so nothing is cut off in the narrow panel.
private struct MeterRow: View {
    let meter: UsageGlance.Meter

    private var tint: Color {
        meter.used >= 90 ? .red : meter.used >= 75 ? .orange : .blue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(meter.label).font(.callout)
                Spacer(minLength: 8)
                Text("\(Int(meter.used.rounded()))% used")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(tint).frame(width: max(4, geo.size.width * meter.used / 100))
                }
            }
            .frame(height: 5)
            if let resets = meter.resetsAt, resets > Date() {
                Text("Resets \(Self.when(resets))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(meter.label), \(Int(meter.used.rounded())) percent used")
        .accessibilityValue(meter.resetsAt.map { "Resets \(Self.when($0))" } ?? "")
    }

    /// "3:40 PM" today, "tomorrow 9:00 AM", otherwise "Tuesday 8:00 AM".
    static func when(_ date: Date, now: Date = Date()) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow \(time)"
        }
        return "\(date.formatted(.dateTime.weekday(.wide))) \(time)"
    }
}

/// Which agent a session belongs to, as a small capsule beside its name.
private struct AgentTag: View {
    let agent: String

    private var tint: Color {
        switch agent {
        case "Antigravity": .blue
        case "Codex": .teal
        default: .orange
        }
    }

    var body: some View {
        Text(agent)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.15), in: Capsule())
            .fixedSize()
            .accessibilityHidden(true)
    }
}
