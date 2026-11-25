import SwiftUI
import OpenBetterDisplayCore

/// Top card: Built-in + external displays with selection and the Built-in ON/OFF toggle.
struct DisplayCardsSection: View {
    @ObservedObject var controller: AppController

    private var orderedDisplays: [DisplayInfo] {
        let visible = controller.displays.filter { !$0.isVirtual && ($0.isBuiltIn || $0.isOnline || $0.isEnabled) }
        return visible.sorted { lhs, rhs in
            if lhs.isBuiltIn != rhs.isBuiltIn { return lhs.isBuiltIn }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            ForEach(orderedDisplays) { display in
                DisplayCard(controller: controller, display: display)
            }
            if orderedDisplays.isEmpty {
                GlassCard {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Detecting displays…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct DisplayCard: View {
    @ObservedObject var controller: AppController
    let display: DisplayInfo

    private var isSelected: Bool { controller.selectedDisplayID == display.id && display.isEnabled }

    private var hasActiveExternal: Bool { controller.primaryExternalDisplay != nil }

    private var subtitle: String {
        if display.isBuiltIn && !controller.isBuiltInEnabled { return "Off" }
        if !display.isEnabled { return display.isMirrored ? "Mirrored" : "Disabled" }
        if let mode = display.currentMode { return ModeFormat.summary(mode) }
        return "Active"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                .font(.system(size: 18))
                .foregroundStyle(display.isEnabled ? Color.accentColor : Color.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(display.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if display.isMain { Pill(text: "M", color: .accentColor) }
                    if display.isHDREnabled { Pill(text: "HDR", color: .purple) }
                }
                .frame(height: 18)
                Text(verbatim: subtitle)
                    .font(.system(size: 11, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(height: 14, alignment: .leading)
            }

            Spacer(minLength: 4)

            if display.isBuiltIn {
                Toggle("", isOn: Binding(
                    get: { controller.isBuiltInEnabled },
                    set: { controller.setBuiltInDisplayEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                // Turning ON must always stay possible; turning OFF requires an active external display.
                .disabled(controller.isBusySwitching || (controller.isBuiltInEnabled && !hasActiveExternal))
                .help(controller.isBuiltInEnabled && !hasActiveExternal
                      ? "Connect an external display first"
                      : (controller.isBuiltInEnabled ? "Turn Built-in Display off" : "Turn Built-in Display on"))
            } else {
                StatusDot(isOn: display.isEnabled)
                    .help(display.isEnabled ? "Active" : "Inactive")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(isSelected ? 0.10 : 0.0))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                              lineWidth: isSelected ? 1.5 : 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            if display.isEnabled { controller.selectedDisplayID = display.id }
        }
        .opacity(display.isEnabled ? 1 : 0.7)
    }
}
