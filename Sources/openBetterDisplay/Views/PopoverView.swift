import SwiftUI
import OpenBetterDisplayCore

/// Menu bar popover (368pt wide) following SPEC §4.1.
struct PopoverView: View {
    @ObservedObject var controller: AppController
    let openSettings: () -> Void
    let quit: () -> Void
    var expandModeDisclosure: Bool = false
    var showcaseClean: Bool = false

    @State private var contentHeight: CGFloat = 0
    @State private var dismissedErrorMessage: String?

    static let width: CGFloat = 368
    private static let footerHeight: CGFloat = 44

    private var maxScrollHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return min(max(screen - 120, 320), 760)
    }

    private var selectedDisplay: DisplayInfo? {
        guard let id = controller.selectedDisplayID else { return nil }
        return controller.displays.first { $0.id == id && $0.isEnabled }
    }

    private var visibleErrorMessage: String? {
        guard let message = controller.lastErrorMessage,
              !message.isEmpty,
              message != dismissedErrorMessage else { return nil }
        return message
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    if !controller.hasAccessibilityPermission && !showcaseClean {
                        AccessibilityBanner(controller: controller)
                            .transaction { tx in tx.animation = nil }
                    }

                    DisplayCardsSection(controller: controller)
                        .transaction { tx in tx.animation = nil }

                    if let display = selectedDisplay {
                        ControlsSection(controller: controller, display: display)
                            .transaction { tx in tx.animation = nil }
                        QuickTogglesSection(controller: controller, display: display)
                            .transaction { tx in tx.animation = nil }
                        DisclosuresSection(
                            controller: controller,
                            display: display,
                            expandModeDisclosure: expandModeDisclosure
                        )
                    } else {
                        GlassCard {
                            Text("No active display selected.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .transaction { tx in tx.animation = nil }
                        QuickTogglesSection(controller: controller, display: nil)
                            .transaction { tx in tx.animation = nil }
                    }
                }
                .padding(12)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                    }
                )
            }
            .onPreferenceChange(ContentHeightKey.self) { height in
                let rounded = ceil(height)
                if contentHeight == 0 || abs(rounded - contentHeight) >= 1.5 {
                    contentHeight = rounded
                }
            }
            .frame(height: min(max(contentHeight == 0 ? 480 : contentHeight, 120), maxScrollHeight))
            .animation(nil, value: contentHeight)

            if let message = visibleErrorMessage {
                ErrorBanner(message: message) {
                    dismissedErrorMessage = message
                }
                .transaction { tx in tx.animation = nil }
            }

            Divider().opacity(0.6)
            FooterBar(controller: controller, openSettings: openSettings, quit: quit)
                .frame(height: Self.footerHeight)
                .transaction { tx in tx.animation = nil }
        }
        .frame(width: Self.width)
        .background(.regularMaterial)
        .onChange(of: controller.lastErrorMessage) { _, newValue in
            if newValue == nil || newValue != dismissedErrorMessage {
                dismissedErrorMessage = nil
            }
        }
        .onChange(of: controller.isBusySwitching) { _, isBusy in
            if isBusy { dismissedErrorMessage = nil }
        }
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

private struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
            Text(verbatim: message)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss error")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.10))
        .overlay(alignment: .top) {
            Divider().opacity(0.5)
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
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 14, height: 14)
                    .opacity(controller.isBusySwitching ? 1 : 0)
                    .accessibilityHidden(!controller.isBusySwitching)
                    .help(controller.isBusySwitching ? "Applying display change…" : "")
                FooterButton(title: "Restore All", systemImage: "arrow.counterclockwise.circle", tint: .orange) {
                    controller.emergencyRestoreAllDisplays()
                }
                .help("Emergency restore: re-enable all displays and reset dimming/warmth (⌃⌥⌘R)")
                Color.clear.frame(width: 14, height: 14)
            }
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
