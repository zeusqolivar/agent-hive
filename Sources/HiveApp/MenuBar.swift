import HiveCore
import AppKit
import SwiftUI

/// The menu bar extra: a hexagon with the number of sessions that need you.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: model.needsYou > 0 ? "hexagon.fill" : "hexagon")
            if model.needsYou > 0 { Text("\(model.needsYou)").monospacedDigit() }
            if model.keepingAwake { Image(systemName: "cup.and.saucer.fill") }
        }
        .accessibilityLabel((model.needsYou == 1 ? "Agent Hive, 1 session needs you"
                             : "Agent Hive, \(model.needsYou) sessions need you")
                            + (model.keepingAwake ? ", keeping the Mac awake" : ""))
    }
}

struct MenuBarMenu: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Open Agent Hive") { show(nil) }
            .keyboardShortcut("o")
        if !model.waiting.isEmpty {
            Divider()
            Text(model.needsYou == 1 ? "1 session needs you" : "\(model.needsYou) sessions need you")
            ForEach(model.waiting) { session in
                Button("\(session.name): \(session.headline)") { show("#/agents/\(session.id)") }
            }
        }
        Divider()
        Picker(model.keepingAwake ? "Keeping Mac awake" : "Keep Mac awake", selection: $model.keepAwakeMode) {
            ForEach(KeepAwakeMode.allCases, id: \.self) { mode in
                Text(model.title(for: mode)).tag(mode)
            }
        }
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Button("Quit Agent Hive") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func show(_ route: String?) {
        model.route = route
        openWindow(id: "main")
        NSApp.activate()
    }
}
