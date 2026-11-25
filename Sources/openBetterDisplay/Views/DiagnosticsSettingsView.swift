import SwiftUI
import OpenBetterDisplayCore

struct DiagnosticsSettingsView: View {
    @ObservedObject var controller: AppController

    private var audioMonitor: DisplayInfo? {
        guard let id = controller.audioMonitorDisplayID else { return nil }
        return controller.displays.first { $0.id == id }
    }

    private var activeDisplays: [DisplayInfo] {
        controller.displays.filter { !$0.isVirtual && $0.isEnabled }
    }

    var body: some View {
        Form {
            Section("Accessibility") {
                HStack {
                    StatusDot(isOn: controller.hasAccessibilityPermission, onColor: .green, offColor: .orange)
                    Text(controller.hasAccessibilityPermission ? "Granted — media keys active" : "Not granted — media keys disabled")
                    Spacer()
                    Button("Request Permission") { controller.requestAccessibilityPermission() }
                        .controlSize(.small)
                        .disabled(controller.hasAccessibilityPermission)
                    Button("Open System Settings") { controller.openAccessibilitySettings() }
                        .controlSize(.small)
                }
                SettingsFootnote(text: "Status refreshes automatically once you grant access in System Settings › Privacy & Security › Accessibility.")
            }

            Section("Audio Output") {
                LabeledContent("Default output") {
                    Text(controller.defaultAudioOutputName ?? "Unknown")
                }
                LabeledContent("Monitor audio") {
                    if let monitor = audioMonitor {
                        Pill(text: "Output is \(monitor.name) — volume keys use DDC", color: .green, systemImage: "checkmark")
                    } else {
                        Pill(text: "Not a monitor — volume keys pass through to macOS", color: .secondary)
                    }
                }
            }

            Section("DDC/CI Capability") {
                if activeDisplays.isEmpty {
                    Text("No active displays.").foregroundStyle(.secondary)
                }
                ForEach(activeDisplays) { display in
                    DDCCard(controller: controller, display: display)
                }
            }
        }
        .settingsTab()
    }
}

private struct DDCCard: View {
    @ObservedObject var controller: AppController
    let display: DisplayInfo

    private var report: DDCCapabilityReport? { controller.lastDDCReports[display.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                Text(display.name).font(.system(size: 13, weight: .semibold))
                if display.supportsHDR {
                    Pill(text: display.isHDREnabled ? "HDR On" : "HDR Off", color: display.isHDREnabled ? .purple : .secondary)
                }
                Spacer()
                Button("Probe DDC") { controller.probeDDC(for: display.id) }
                    .controlSize(.small)
                    .disabled(display.isBuiltIn)
                    .help(display.isBuiltIn ? "The Built-in Display is controlled natively" : "Read DDC/CI capabilities")
            }

            if display.isBuiltIn {
                Text("Native brightness control — DDC/CI is not used.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else if let report {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    row("IOAVService", ok: report.hasIOAVService, detail: report.hasIOAVService ? "Matched" : "No match")
                    row("Luminance (0x10)", ok: report.supportsLuminance,
                        detail: report.currentLuminance.map { "\($0)" } ?? (report.supportsLuminance ? "—" : "Unsupported"))
                    row("Volume (0x62)", ok: report.supportsVolume,
                        detail: report.currentVolume.map { "\($0)" } ?? (report.supportsVolume ? "—" : "Unsupported"))
                    row("Input Source (0x60)", ok: report.supportsInputSource,
                        detail: report.currentInputSource?.displayName ?? (report.supportsInputSource ? "—" : "Unsupported"))
                }
                if let error = report.probeError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
            } else {
                Text("Not probed yet. Click “Probe DDC” to read this monitor's capabilities.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func row(_ title: String, ok: Bool, detail: String) -> some View {
        GridRow {
            HStack(spacing: 6) {
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(ok ? Color.green : Color.secondary)
                Text(title)
            }
            Text(detail)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
    }
}
