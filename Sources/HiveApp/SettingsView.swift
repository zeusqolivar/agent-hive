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
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
