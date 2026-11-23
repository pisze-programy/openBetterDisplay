import SwiftUI
import OpenBetterDisplayCore

/// HDR, Main Display and Night Shift quick toggles.
struct QuickTogglesSection: View {
    @ObservedObject var controller: AppController
    let display: DisplayInfo?

    var body: some View {
        GlassCard(padding: 4) {
            VStack(spacing: 0) {
                if let display, display.supportsHDR {
                    ToggleRow(title: "Enable HDR Mode", systemImage: "sparkles.tv", isOn: Binding(
                        get: { display.isHDREnabled },
                        set: { controller.setHDREnabled($0, for: display.id) }
                    ))
                    .disabled(controller.isBusySwitching)
                    rowDivider
                }
                if let display, !display.isMain, display.isEnabled {
                    ActionRow(title: "Set as Main Display", systemImage: "menubar.dock.rectangle") {
                        controller.setMainDisplay(display.id)
                    }
                    .disabled(controller.isBusySwitching)
                    rowDivider
                }
                NightShiftRow(controller: controller)
            }
        }
    }

    private var rowDivider: some View { Divider().padding(.horizontal, 8).opacity(0.5) }
}

// MARK: - Rows

struct ToggleRow: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool
    var badge: AnyView? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .frame(width: 18)
            Text(title).font(.system(size: 12.5))
            if let badge { badge }
            Spacer(minLength: 4)
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

private struct ActionRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(title).font(.system(size: 12.5))
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct NightShiftRow: View {
    @ObservedObject var controller: AppController
    @ObservedObject private var store: SettingsStore

    init(controller: AppController) {
        self.controller = controller
        self._store = ObservedObject(wrappedValue: controller.settingsStore)
    }

    private var config: NightShiftConfig { store.settings.nightShift }

    private var badge: (text: String, color: Color, icon: String?) {
        if config.enabled && controller.nightShiftStatus.isActive {
            return ("Active", .orange, "moon.fill")
        }
        if config.enabled && config.scheduleEnabled {
            return ("Scheduled \(controller.nightShiftScheduleDescription)", .secondary, "clock")
        }
        if config.enabled { return ("On", .orange, "moon.fill") }
        return ("Off", .secondary, nil)
    }

    var body: some View {
        let badge = self.badge
        ToggleRow(
            title: "Night Shift",
            systemImage: config.enabled && controller.nightShiftStatus.isActive ? "moon.fill" : "moon",
            isOn: Binding(
                get: { config.enabled },
                set: { newValue in
                    if newValue != store.settings.nightShift.enabled { controller.toggleNightShift() }
                }
            ),
            badge: AnyView(Pill(text: badge.text, color: badge.color, systemImage: badge.icon))
        )
    }
}
