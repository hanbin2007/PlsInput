import SwiftUI
import PlsInputCore

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            Section("Game Center") {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(app.gameCenter.isAuthenticated ? (app.gameCenter.playerDisplayName ?? String(localized: "Signed in")) : String(localized: "Not signed in"))
                        .foregroundStyle(.secondary)
                }
                if !app.gameCenter.isAuthenticated {
                    Button(String(localized: "Sign in")) { app.gameCenter.authenticate() }
                }
                if let error = app.gameCenter.lastError {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle(String(localized: "Haptics"), isOn: $app.settings.hapticsEnabled)
            }
            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text("\(AppBuild.version) (\(AppBuild.number))").foregroundStyle(.secondary)
                }
                HStack {
                    Text("Config")
                    Spacer()
                    Text("v\(app.resolver.config.configVersion)").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(String(localized: "Settings"))
        .scrollContentBackground(.hidden)
        .background(Palette.background)
    }
}
