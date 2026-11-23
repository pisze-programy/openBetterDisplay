import SwiftUI
import OpenBetterDisplayCore

/// Brightness, hardware volume and resolution sliders for the selected display.
struct ControlsSection: View {
    @ObservedObject var controller: AppController
    let display: DisplayInfo

    var body: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 14) {
                BrightnessRow(controller: controller, display: display)
                if !display.isBuiltIn {
                    VolumeRow(controller: controller, display: display)
                }
                ResolutionRow(controller: controller, display: display)
            }
        }
    }
}

// MARK: - Brightness

private struct BrightnessRow: View {
    @ObservedObject var controller: AppController
    let display: DisplayInfo

    private var level: Double { controller.brightnessByDisplay[display.id] ?? 1.0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SliderHeader("Brightness (Combined)", systemImage: "sun.max") {
                HStack(spacing: 6) {
                    if let method = controller.brightnessMethodByDisplay[display.id] {
                        BrightnessMethodPill(method: method)
                    }
                    Text("\(Int((level * 100).rounded()))%")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "sun.min").font(.system(size: 10)).foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { level },
                        set: { controller.setBrightness($0, for: display.id) }
                    ),
                    in: 0...1
                )
                .controlSize(.small)
                Image(systemName: "sun.max.fill").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Volume

private struct VolumeRow: View {
    @ObservedObject var controller: AppController
    let display: DisplayInfo

    private var volume: Int { controller.volumeByDisplay[display.id] ?? 50 }
    private var isMuted: Bool { controller.mutedByDisplay[display.id] ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SliderHeader("Volume (Hardware)", systemImage: "speaker.wave.2") {
                Text(isMuted ? "Muted" : "\(volume)")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Button {
                    controller.toggleMute(for: display.id)
                } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(isMuted ? Color.red : Color.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isMuted ? "Unmute monitor speakers" : "Mute monitor speakers")

                Slider(
                    value: Binding(
                        get: { Double(volume) },
                        set: { controller.setVolume(Int($0.rounded()), for: display.id) }
                    ),
                    in: 0...100
                )
                .controlSize(.small)
                Image(systemName: "speaker.wave.3.fill").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .disabled(!display.supportsDDC)
            .opacity(display.supportsDDC ? 1 : 0.5)
            .help(display.supportsDDC ? "" : "This display does not expose DDC/CI audio control")
        }
    }
}

// MARK: - Resolution

/// One step on the resolution slider: unique `(width, height, isHiDPI)` with its refresh-rate variants.
struct ResolutionTier: Equatable {
    let width: Int
    let height: Int
    let isHiDPI: Bool
    let modes: [DisplayModeInfo]

    static func tiers(for display: DisplayInfo) -> [ResolutionTier] {
        struct Key: Hashable { let width: Int; let height: Int; let hiDPI: Bool }
        let grouped = Dictionary(grouping: display.availableModes) { Key(width: $0.width, height: $0.height, hiDPI: $0.isHiDPI) }
        return grouped
            .map { key, modes in
                ResolutionTier(
                    width: key.width, height: key.height, isHiDPI: key.hiDPI,
                    modes: modes.sorted { $0.refreshRate > $1.refreshRate }
                )
            }
            .sorted { lhs, rhs in
                if lhs.width != rhs.width { return lhs.width < rhs.width }
                if lhs.height != rhs.height { return lhs.height < rhs.height }
                return !lhs.isHiDPI && rhs.isHiDPI
            }
    }

    /// Picks the mode whose refresh rate is closest to `preferredRate` (highest wins ties / unknown rate).
    func bestMode(preferredRate: Double?) -> DisplayModeInfo? {
        guard let preferredRate else { return modes.first }
        return modes.min { lhs, rhs in
            let l = abs(lhs.refreshRate - preferredRate)
            let r = abs(rhs.refreshRate - preferredRate)
            return l == r ? lhs.refreshRate > rhs.refreshRate : l < r
        }
    }
}

private struct ResolutionRow: View {
    @ObservedObject var controller: AppController
    let display: DisplayInfo

    @State private var dragIndex: Double?

    private var tiers: [ResolutionTier] { ResolutionTier.tiers(for: display) }

    private func currentIndex(in tiers: [ResolutionTier]) -> Int {
        guard let current = display.currentMode else { return max(tiers.count - 1, 0) }
        return tiers.firstIndex { $0.width == current.width && $0.height == current.height && $0.isHiDPI == current.isHiDPI } ?? 0
    }

    var body: some View {
        let tiers = self.tiers
        let activeIndex = currentIndex(in: tiers)
        let shownIndex = min(max(Int((dragIndex ?? Double(activeIndex)).rounded()), 0), max(tiers.count - 1, 0))
        let shownTier = tiers.indices.contains(shownIndex) ? tiers[shownIndex] : nil
        let rate = display.currentMode?.refreshRate

        VStack(alignment: .leading, spacing: 6) {
            SliderHeader("Resolution", systemImage: "rectangle.expand.vertical") {
                HStack(spacing: 5) {
                    if let tier = shownTier {
                        if tier.isHiDPI { Pill(text: "HiDPI", color: .blue) }
                        Text(verbatim: "\(tier.width) × \(tier.height)")
                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        if let rate { Pill(text: "@ \(ModeFormat.hz(rate))", color: .secondary) }
                    } else {
                        Text("Unavailable").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            if tiers.count > 1 {
                Slider(
                    value: Binding(
                        get: { dragIndex ?? Double(activeIndex) },
                        set: { dragIndex = $0 }
                    ),
                    in: 0...Double(tiers.count - 1),
                    step: 1,
                    onEditingChanged: { editing in
                        guard !editing else { return }
                        defer { dragIndex = nil }
                        guard let index = dragIndex.map({ Int($0.rounded()) }), index != activeIndex,
                              tiers.indices.contains(index),
                              let mode = tiers[index].bestMode(preferredRate: rate) else { return }
                        controller.setDisplayMode(mode, for: display.id)
                    }
                )
                .controlSize(.small)
                HStack {
                    Text("Larger text").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                    Spacer()
                    Text("More space").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
            } else {
                Text("Only one resolution available")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
