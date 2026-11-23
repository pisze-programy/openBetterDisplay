import SwiftUI
import OpenBetterDisplayCore

/// Menu bar popover (~330pt wide) following SPEC §4.1.
struct PopoverView: View {
    @ObservedObject var controller: AppController
    let openSettings: () -> Void
    let quit: () -> Void

    @State private var contentHeight: CGFloat = 480

    static let width: CGFloat = 350
    private static let footerHeight: CGFloat = 44

    private var maxScrollHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return min(max(screen - 120, 320), 760)
    }

    private var selectedDisplay: DisplayInfo? {
        guard let id = controller.selectedDisplayID else { return nil }
        return controller.displays.first { $0.id == id && $0.isEnabled }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    if !controller.hasAccessibilityPermission {
                        AccessibilityBanner(controller: controller)
                    }
                    StatusBanner(controller: controller)

                    DisplayCardsSection(controller: controller)

                    if let display = selectedDisplay {
                        ControlsSection(controller: controller, display: display)
                        QuickTogglesSection(controller: controller, display: display)
                        DisclosuresSection(controller: controller, display: display)
                    } else {
                        GlassCard {
                            Text("No active display selected.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        QuickTogglesSection(controller: controller, display: nil)
                    }
                }
                .padding(12)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                    }
                )
            }
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            .frame(height: min(max(contentHeight, 120), maxScrollHeight))

            Divider().opacity(0.6)
            FooterBar(controller: controller, openSettings: openSettings, quit: quit)
                .frame(height: Self.footerHeight)
        }
        .frame(width: Self.width)
        .background(.regularMaterial)
    }
}

// MARK: - Banners

private struct AccessibilityBanner: View {
    let controller: AppController

    var body: some View {
        GlassCard(tint: .orange) {
            HStack(spacing: 10) {
                Image(systemName: "keyboard.badge.eye")
                    .font(.system(size: 18))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Enable Accessibility for Media Keys")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Needed to control external brightness & volume with keyboard keys.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button("Grant Access") {
                    controller.requestAccessibilityPermission()
                    controller.openAccessibilitySettings()
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
    }
}

private struct StatusBanner: View {
    @ObservedObject var controller: AppController

    var body: some View {
        if let message = controller.lastErrorMessage, !message.isEmpty {
            GlassCard(tint: .red) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.system(size: 11.5))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        } else if controller.isBusySwitching {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Applying display change…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - Footer

private struct FooterBar: View {
    @ObservedObject var controller: AppController
    let openSettings: () -> Void
    let quit: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            FooterButton(title: "Settings…", systemImage: "gearshape", action: openSettings)
                .keyboardShortcut(",", modifiers: .command)
                .help("Open Settings (⌘,)")
            Spacer(minLength: 0)
            FooterButton(title: "Restore All", systemImage: "arrow.counterclockwise.circle", tint: .orange) {
                controller.emergencyRestoreAllDisplays()
            }
            .help("Emergency restore: re-enable all displays and reset dimming/warmth (⌃⌥⌘R)")
            Spacer(minLength: 0)
            FooterButton(title: "Quit", systemImage: "power", action: quit)
                .keyboardShortcut("q", modifiers: .command)
                .help("Quit (⌘Q) — restores the Built-in Display first")
        }
        .padding(.horizontal, 10)
    }
}

private struct FooterButton: View {
    let title: String
    let systemImage: String
    var tint: Color = .primary
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 11))
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(tint == .primary ? Color.primary : tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.09 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
