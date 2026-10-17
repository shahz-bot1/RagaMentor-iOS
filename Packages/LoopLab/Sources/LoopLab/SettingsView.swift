import SwiftUI
import DesignSystem

/// Settings (user request 2026-10-17): app identity at a glance —
/// version and build number, so the installed build can be verified
/// against a release before testing. Read from the app bundle.
public struct SettingsView: View {
    public init() {}

    @AppStorage("ragamentor-theme") private var theme = "dark"

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    public var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $theme) {
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                }
                .pickerStyle(.segmented)
            }
            Section("App") {
                LabeledContent("App", value: "RagaMentor")
                LabeledContent("Version", value: version)
                LabeledContent("Build", value: build)
            }
            Section {
                Text("Harmonium samples: tonejs-instruments (CC BY 3.0).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Studio.bg.ignoresSafeArea())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}
