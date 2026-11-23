import SwiftUI
import OpenBetterDisplayCore

/// 5-tab Settings window content (SPEC §4.2), ~640×500pt.
struct SettingsView: View {
    @ObservedObject var controller: AppController
    @State private var selectedTab: Int

    init(controller: AppController, initialTab: Int = 0) {
        self.controller = controller
        self._selectedTab = State(initialValue: (0...4).contains(initialTab) ? initialTab : 0)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView(controller: controller)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(0)
            ProfilesSettingsView(controller: controller)
                .tabItem { Label("Displays & Profiles", systemImage: "display.2") }
                .tag(1)
            NightShiftSettingsView(controller: controller)
                .tabItem { Label("Night Shift", systemImage: "moon.stars") }
                .tag(2)
            ShortcutsSettingsView(controller: controller)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                .tag(3)
            DiagnosticsSettingsView(controller: controller)
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
                .tag(4)
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
