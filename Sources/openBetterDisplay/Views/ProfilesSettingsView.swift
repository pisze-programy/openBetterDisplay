import SwiftUI
import OpenBetterDisplayCore

struct ProfilesSettingsView: View {
    @ObservedObject var controller: AppController
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                if controller.profiles.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "display.trianglebadge.exclamationmark")
                            .font(.system(size: 26))
                            .foregroundStyle(.tertiary)
                        Text("No remembered monitors yet")
                            .font(.system(size: 13, weight: .medium))
                        Text("Profiles are captured automatically when you connect an external monitor.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    ForEach(controller.profiles) { profile in
                        ProfileCard(controller: controller, profile: profile)
                    }
                }
            } header: {
                Text("Remembered Monitors")
            }

            Section {
                HStack {
                    SettingsFootnote(text: "Forgetting a profile never changes the monitor; it will be captured again on next connect.")
                    Spacer()
                    Button("Reset All Profiles", role: .destructive) { confirmReset = true }
                        .disabled(controller.profiles.isEmpty)
                }
            }
        }
        .settingsTab()
        .confirmationDialog("Reset all monitor profiles?", isPresented: $confirmReset) {
            Button("Reset All Profiles", role: .destructive) { controller.resetProfiles() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All remembered monitor settings will be deleted.")
        }
    }
}

private struct ProfileCard: View {
    let controller: AppController
    let profile: MonitorProfile

    private func save(_ change: (inout MonitorProfile) -> Void) {
        var copy = profile
        change(&copy)
        controller.profileStore.saveProfile(copy)
    }

    private var summary: [String] {
        var parts = [
            "\(profile.targetWidth) × \(profile.targetHeight)\(profile.targetIsHiDPI ? " HiDPI" : "") @ \(ModeFormat.hz(profile.targetRefreshRate))",
            "HDR \(profile.hdrEnabled ? "On" : "Off")",
            "Brightness \(Int((profile.combinedBrightness * 100).rounded()))%",
            "Built-in \(profile.builtInDisplayEnabled ? "On" : "Off")"
        ]
        if profile.rotation != 0 { parts.append("Rotation \(profile.rotation)°") }
        return parts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName).font(.system(size: 13, weight: .semibold))
                    Text(profile.identifier.storageKey)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button(role: .destructive) {
                    controller.deleteProfile(forKey: profile.identifier.storageKey)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .controlSize(.small)
            }

            HStack(spacing: 5) {
                ForEach(summary, id: \.self) { Pill(text: $0, color: .secondary) }
            }
            .lineLimit(1)

            Toggle("Auto-restore profile on connect", isOn: Binding(
                get: { profile.autoRestoreOnConnect },
                set: { value in save { $0.autoRestoreOnConnect = value } }
            ))
            Toggle("Auto-disable Built-in Display on connect", isOn: Binding(
                get: { profile.autoDisableBuiltInOnConnect },
                set: { value in
                    save {
                        $0.autoDisableBuiltInOnConnect = value
                        // The hotplug restore requires both flags: auto-disable AND "Built-in off" target state.
                        $0.builtInDisplayEnabled = !value
                    }
                }
            ))
        }
        .padding(.vertical, 4)
    }
}
