import HiveCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            UsageSettings(model: model)
                .tabItem { Label("Usage services", systemImage: "gauge.with.dots.needle.50percent") }
        }
        .frame(width: 480)
    }
}

struct GeneralSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Toggle("Start Agent Hive at login", isOn: $model.startAtLogin)
            if let error = model.loginError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Open the window at login", isOn: $model.openWindowAtLogin)
                .disabled(!model.startAtLogin)
            Toggle("Show the menu bar icon", isOn: $model.showMenuBarIcon)
            Text("The menu bar icon shows how many sessions need you.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Picker("Keep Mac awake", selection: $model.keepAwakeMode) {
                ForEach(KeepAwakeMode.allCases, id: \.self) { mode in
                    Text(model.title(for: mode)).tag(mode)
                }
            }
            Text("Stops your Mac from going to sleep on its own, so agents keep running. The screen can still turn off, and closing the lid on battery still sleeps. \"While agents are working\" lets it sleep once every session is idle.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// API keys for the services that report balances and costs, and the Claude status line for plan limits.
struct UsageSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach(UsageProviders.all, id: \.id) { provider in
                    KeyRow(model: model, provider: provider)
                }
            } header: {
                Text("API keys")
            } footer: {
                Text("Keys are kept in your Keychain and sent only to their own service, every 15 minutes and when you click Refresh in the Usage view. OpenAI and Anthropic need an Admin key to report costs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                LabeledContent("Claude status line") {
                    if model.statusLineInstalled {
                        HStack {
                            Text("Set up").foregroundStyle(.secondary)
                            Button("Remove") { Task { await model.setStatusLine(installed: false) } }
                        }
                    } else {
                        Button("Set up") { Task { await model.setStatusLine(installed: true) } }
                    }
                }
                if let error = model.statusLineError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            } header: {
                Text("Claude plan limits")
            } footer: {
                Text("Claude Code shares your 5-hour and weekly limits only with a status line command. Set up adds a small script as your status line in ~/.claude/settings.json; it saves the limits for Agent Hive and still runs the status line you had. The figures update while you use Claude Code in a terminal. Remove puts your previous status line back.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .task { await model.refreshUsageState() }
    }
}

struct KeyRow: View {
    @Bindable var model: AppModel
    let provider: UsageProvider
    @State private var entry = ""
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                if model.savedKeys.contains(provider.id) {
                    HStack {
                        Text("Key saved").foregroundStyle(.secondary)
                        Button("Remove") { Task { await model.removeKey(for: provider.id) } }
                    }
                } else {
                    HStack {
                        SecureField(provider.keyKind, text: $entry)
                            .textContentType(.password)
                            .frame(minWidth: 160)
                            .onSubmit(save)
                        Button("Save key", action: save)
                            .disabled(entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.title)
                    Text(provider.host).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = model.keyErrors[provider.id] {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
    }

    private func save() {
        let key = entry
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        entry = ""
        saving = true
        Task {
            await model.saveKey(key, for: provider.id)
            saving = false
        }
    }
}
