import SwiftUI
import OpenBetterDisplayCore

// MARK: - Card container

/// Compact translucent card used throughout the popover.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 10
    var tint: Color? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill((tint ?? Color.primary).opacity(tint == nil ? 0.04 : 0.12))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
    }
}

// MARK: - Pills

struct Pill: View {
    let text: String
    var color: Color = .secondary
    var systemImage: String? = nil
    var minWidth: CGFloat? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 8, weight: .bold))
            }
            Text(verbatim: text)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .frame(minWidth: minWidth)
        .background(Capsule(style: .continuous).fill(color.opacity(0.15)))
        .fixedSize()
    }
}

struct BrightnessMethodPill: View {
    let method: BrightnessMethod

    private var color: Color {
        switch method {
        case .ddc: return .green
        case .ddcWithDimming: return .teal
        case .softwareHDR: return .purple
        case .softwareFallback: return .orange
        case .nativeBuiltIn: return .blue
        }
    }

    var body: some View {
        Pill(text: method.badgeText, color: color)
    }
}

// MARK: - Section header

struct SliderHeader: View {
    let title: String
    var systemImage: String
    let trailing: () -> AnyView

    init(_ title: String, systemImage: String, @ViewBuilder trailing: @escaping () -> some View = { EmptyView() }) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = { AnyView(trailing()) }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 4)
            trailing()
        }
        .frame(height: 18)
    }
}

// MARK: - Mode formatting

enum ModeFormat {
    static func hz(_ rate: Double) -> String { "\(Int(rate.rounded()))Hz" }

    static func summary(_ mode: DisplayModeInfo) -> String {
        "\(mode.width) × \(mode.height)\(mode.isHiDPI ? " HiDPI" : "") @ \(hz(mode.refreshRate))"
    }

    static func compactSummary(_ mode: DisplayModeInfo) -> String {
        "\(mode.width) × \(mode.height) @ \(hz(mode.refreshRate))"
    }
}

// MARK: - Height preference (popover auto-sizing)

struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Status dot

struct StatusDot: View {
    let isOn: Bool
    var onColor: Color = .green
    var offColor: Color = .secondary

    var body: some View {
        Circle()
            .fill(isOn ? onColor : offColor.opacity(0.5))
            .frame(width: 7, height: 7)
    }
}
