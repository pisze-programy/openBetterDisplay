import SwiftUI
import OpenBetterDisplayCore

/// 5-tab Settings window content (SPEC §4.2), ~640×500pt.
struct SettingsView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        TabView {
            GeneralSettingsView(controller: controller)
                .tabItem { Label("General", systemImage: "gearshape") }
            ProfilesSettingsView(controller: controller)
                .tabItem { Label("Displays & Profiles", systemImage: "display.2") }
            NightShiftSettingsView(controller: controller)
                .tabItem { Label("Night Shift", systemImage: "moon.stars") }
            ShortcutsSettingsView(controller: controller)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            DiagnosticsSettingsView(controller: controller)
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .frame(width: 640, height: 500)
    }
}

// MARK: - Shared helpers

extension View {
    /// Standard grouped-form tab body.
    func settingsTab() -> some View {
        self.formStyle(.grouped).scrollContentBackground(.visible)
    }
}

struct SettingsFootnote: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
