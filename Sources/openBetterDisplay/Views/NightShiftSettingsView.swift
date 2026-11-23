import SwiftUI
import OpenBetterDisplayCore

struct NightShiftSettingsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject private var store: SettingsStore

    init(controller: AppController) {
        self.controller = controller
        self._store = ObservedObject(wrappedValue: controller.settingsStore)
    }

    private var config: NightShiftConfig { store.settings.nightShift }

    private func update(_ change: @escaping (inout NightShiftConfig) -> Void) {
        controller.updateSettings { change(&$0.nightShift) }
    }

    private static let commonTimeZones = [
        "Europe/Warsaw", "Europe/London", "Europe/Berlin", "Europe/Paris",
        "America/New_York", "America/Chicago", "America/Los_Angeles", "Asia/Tokyo", "UTC"
    ]

    private var timeZoneOptions: [String] {
        var options = Self.commonTimeZones
        if let custom = config.timeZoneIdentifier, !options.contains(custom) { options.insert(custom, at: 0) }
        return options
    }

    private func timeBinding(hour: KeyPath<NightShiftConfig, Int>, minute: KeyPath<NightShiftConfig, Int>,
                             write: @escaping (inout NightShiftConfig, Int, Int) -> Void) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: config[keyPath: hour], minute: config[keyPath: minute], second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                let h = parts.hour ?? 0, m = parts.minute ?? 0
                update { write(&$0, h, m) }
            }
        )
    }

    private var nightShiftModeText: String {
        let status = controller.nightShiftStatus
        if status.usedNative && !status.overlayDisplayIDs.isEmpty { return "Active · Hybrid" }
        return status.usedNative ? "Active · Native" : "Active · Overlay"
    }

    var body: some View {
        Form {
            Section("Night Shift") {
                Toggle("Enable Night Shift", isOn: Binding(
                    get: { config.enabled },
                    set: { value in update { $0.enabled = value } }
                ))
                HStack {
                    Text("Status")
                    Spacer()
                    if controller.nightShiftStatus.isActive {
                        Pill(text: nightShiftModeText,
                             color: .orange, systemImage: "moon.fill")
                    } else {
                        Pill(text: config.enabled ? "Waiting for schedule" : "Off", color: .secondary)
                    }
                }
                HStack {
                    Text("Warmth")
                    Slider(value: Binding(
                        get: { config.warmth },
                        set: { value in update { $0.warmth = value } }
                    ), in: 0...1)
                    Text("\(Int((config.warmth * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }

            Section("Schedule") {
                Toggle("Use schedule", isOn: Binding(
                    get: { config.scheduleEnabled },
                    set: { value in update { $0.scheduleEnabled = value } }
                ))
                Group {
                    DatePicker("Start", selection: timeBinding(hour: \.startHour, minute: \.startMinute) { c, h, m in
                        c.startHour = h; c.startMinute = m
                    }, displayedComponents: .hourAndMinute)
                    DatePicker("End", selection: timeBinding(hour: \.endHour, minute: \.endMinute) { c, h, m in
                        c.endHour = h; c.endMinute = m
                    }, displayedComponents: .hourAndMinute)
                    Picker("Time zone", selection: Binding(
                        get: { config.timeZoneIdentifier ?? "" },
                        set: { value in update { $0.timeZoneIdentifier = value.isEmpty ? nil : value } }
                    )) {
                        Text("System Current (\(TimeZone.current.identifier))").tag("")
                        Divider()
                        ForEach(timeZoneOptions, id: \.self) { Text($0).tag($0) }
                    }
                    Stepper(value: Binding(
                        get: { config.transitionMinutes },
                        set: { value in update { $0.transitionMinutes = min(max(value, 0), 60) } }
                    ), in: 0...60, step: 5) {
                        HStack {
                            Text("Transition")
                            Spacer()
                            Text(config.transitionMinutes == 0 ? "Instant" : "\(config.transitionMinutes) min")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                .disabled(!config.scheduleEnabled)
                SettingsFootnote(text: "Default window 18:00–05:00. Warmth fades in and out over the transition time at both boundaries.")
            }

            Section("HDR") {
                Toggle("Apply software fallback in HDR", isOn: Binding(
                    get: { config.applySoftwareFallbackInHDR },
                    set: { value in update { $0.applySoftwareFallbackInHDR = value } }
                ))
                SettingsFootnote(text: "macOS Night Shift is unavailable on HDR displays; a warm overlay (hidden from screenshots) is used instead.")
            }
        }
        .settingsTab()
    }
}
