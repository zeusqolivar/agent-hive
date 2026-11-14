import HiveCore
import SwiftUI

struct SettingsView: View {
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
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
