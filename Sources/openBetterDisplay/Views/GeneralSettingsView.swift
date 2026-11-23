import SwiftUI
import OpenBetterDisplayCore

struct GeneralSettingsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject private var store: SettingsStore
    @State private var loginError: String?

    init(controller: AppController) {
        self.controller = controller
        self._store = ObservedObject(wrappedValue: controller.settingsStore)
    }

    private var settings: AppSettings { store.settings }

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { controller.launchAtLoginEnabled },
                    set: { newValue in
                        do {
                            try controller.setLaunchAtLogin(newValue)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                        }
                    }
                ))
                if let loginError {
                    Label(loginError, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.red)
                }
                if controller.launchAtLoginManager.requiresApproval {
                    HStack {
                        SettingsFootnote(text: "Approval required in System Settings › Login Items.")
                        Spacer()
                        Button("Open Login Items") { controller.launchAtLoginManager.openSystemSettingsLoginItems() }
                            .controlSize(.small)
                    }
                }
            }

            Section("Brightness Keys") {
                Picker("Brightness key target", selection: Binding(
                    get: { settings.brightnessTarget },
                    set: { value in controller.updateSettings { $0.brightnessTarget = value } }
                )) {
                    ForEach(MultiMonitorBrightnessTarget.allCases, id: \.self) { target in
                        Text(target.displayName).tag(target)
                    }
                }
                .pickerStyle(.radioGroup)
                SettingsFootnote(text: "Controls which display(s) the keyboard brightness keys adjust. Requires Accessibility permission.")
            }

            Section("On-Screen Display") {
                Toggle("Show OSD HUD", isOn: Binding(
                    get: { settings.showOSD },
                    set: { value in controller.updateSettings { $0.showOSD = value } }
                ))
                HStack {
                    Text("Duration")
                    Slider(
                        value: Binding(
                            get: { settings.osdDurationSeconds },
                            set: { value in controller.updateSettings { $0.osdDurationSeconds = (value * 10).rounded() / 10 } }
                        ),
                        in: 0.8...3.5,
                        step: 0.1
                    )
                    Text(String(format: "%.1f s", settings.osdDurationSeconds))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                .disabled(!settings.showOSD)
            }
        }
        .settingsTab()
    }
}
