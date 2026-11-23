import SwiftUI
import OpenBetterDisplayCore

/// Expandable utilities: Display Mode, Input Source, Mirror Display, Screen Rotation.
struct DisclosuresSection: View {
    @ObservedObject var controller: AppController
    let display: DisplayInfo
    var expandModeDisclosure: Bool = false

    var body: some View {
        GlassCard(padding: 4) {
            VStack(spacing: 0) {
                DisplayModeDisclosure(controller: controller, display: display, initialExpanded: expandModeDisclosure)
                divider
                if !display.isBuiltIn {
                    InputSourceDisclosure(controller: controller, display: display)
                    divider
                }
                MirrorDisclosure(controller: controller, display: display)
                divider
                RotationDisclosure(controller: controller, display: display)
            }
        }
    }

    private var divider: some View { Divider().padding(.horizontal, 8).opacity(0.5) }
}

// MARK: - Shared chrome

private struct Disclosure<Content: View>: View {
    let title: String
    let systemImage: String
    var detail: String? = nil
    @ViewBuilder var content: () -> Content
    @State private var expanded: Bool

    init(
        title: String,
        systemImage: String,
        detail: String? = nil,
        initialExpanded: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.detail = detail
        self.content = content
        self._expanded = State(initialValue: initialExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            content()
                .padding(.top, 4)
                .padding(.bottom, 6)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 4)
                if let detail {
                    Text(verbatim: detail)
                        .font(.system(size: 10.5, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .opacity(expanded ? 0 : 1)
                        .transaction { tx in tx.animation = nil }
                }
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }
}

private struct ChoiceRow: View {
    let title: String
    var subtitle: String? = nil
    let isSelected: Bool
    var isEnabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 12)
                Text(verbatim: title)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(hovering ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering = $0 }
        .transaction { tx in tx.animation = nil }
    }
}

// MARK: - Display mode

private struct DisplayModeDisclosure: View {
    @ObservedObject var controller: AppController
    let display: DisplayInfo
    var initialExpanded: Bool = false

    private var sortedModes: [DisplayModeInfo] {
        display.availableModes.sorted { lhs, rhs in
            if lhs.width != rhs.width { return lhs.width > rhs.width }
            if lhs.height != rhs.height { return lhs.height > rhs.height }
            if lhs.isHiDPI != rhs.isHiDPI { return !lhs.isHiDPI }
            return lhs.refreshRate > rhs.refreshRate
        }
    }

    var body: some View {
        Disclosure(
            title: "Display Mode",
            systemImage: "rectangle.on.rectangle",
            detail: display.currentMode.map(ModeFormat.compactSummary),
            initialExpanded: initialExpanded
        ) {
            if sortedModes.isEmpty {
                Text("No modes reported").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 1) {
                        ForEach(sortedModes) { mode in
                            ChoiceRow(
                                title: "\(mode.width) × \(mode.height)\(mode.isHiDPI ? " HiDPI" : "")",
                                subtitle: "@ \(ModeFormat.hz(mode.refreshRate))",
                                isSelected: ProfileStore.isSameMode(mode, display.currentMode),
                                isEnabled: !controller.isBusySwitching
                            ) {
                                controller.setDisplayMode(mode, for: display.id)
                            }
                        }
                    }
                }
                .frame(maxHeight: 190)
            }
        }
    }
}

// MARK: - Input source

private struct InputSourceDisclosure: View {
    @ObservedObject var controller: AppController
    let display: DisplayInfo

    private var current: DDCInputSource? { controller.inputSourceByDisplay[display.id] ?? nil }

    var body: some View {
        Disclosure(title: "Input Source", systemImage: "cable.connector", detail: current?.displayName) {
            VStack(spacing: 1) {
                ForEach(DDCInputSource.allPresets) { source in
                    ChoiceRow(
                        title: source.displayName,
                        isSelected: current?.rawValue == source.rawValue,
                        isEnabled: display.supportsDDC
                    ) {
                        controller.setInputSource(source, for: display.id)
                    }
                }
                if !display.supportsDDC {
                    Text("DDC/CI is not available for this display.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
        }
    }
}

// MARK: - Mirror

private struct MirrorDisclosure: View {
    @ObservedObject var controller: AppController
    let display: DisplayInfo

    private var candidates: [DisplayInfo] {
        controller.displays.filter { $0.id != display.id && $0.isEnabled && $0.isOnline }
    }

    private var currentName: String {
        guard let master = display.mirrorMasterID,
              let source = controller.displays.first(where: { $0.id == master }) else { return "Off" }
        return source.name
    }

    var body: some View {
        Disclosure(title: "Mirror Display", systemImage: "rectangle.2.swap", detail: currentName) {
            VStack(spacing: 1) {
                ChoiceRow(title: "Off", isSelected: display.mirrorMasterID == nil, isEnabled: !controller.isBusySwitching) {
                    controller.setMirror(displayID: display.id, mirrorOf: nil)
                }
                ForEach(candidates) { other in
                    ChoiceRow(
                        title: "Mirror \(other.name)",
                        isSelected: display.mirrorMasterID == other.id,
                        isEnabled: !controller.isBusySwitching
                    ) {
                        controller.setMirror(displayID: display.id, mirrorOf: other.id)
                    }
                }
                if candidates.isEmpty {
                    Text("No other active display to mirror.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
        }
    }
}

// MARK: - Rotation

private struct RotationDisclosure: View {
    @ObservedObject var controller: AppController
    let display: DisplayInfo

    var body: some View {
        Disclosure(title: "Screen Rotation", systemImage: "rotate.right", detail: "\(display.rotation)°") {
            VStack(alignment: .leading, spacing: 4) {
                Picker("Rotation", selection: Binding(
                    get: { display.rotation },
                    set: { newValue in
                        if newValue != display.rotation { controller.setRotation(newValue, for: display.id) }
                    }
                )) {
                    ForEach([0, 90, 180, 270], id: \.self) { Text("\($0)°").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!display.supportsRotation || controller.isBusySwitching)
                if !display.supportsRotation {
                    Text("Rotation is not supported by this display.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
