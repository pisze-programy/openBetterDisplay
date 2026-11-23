import SwiftUI
import AppKit
import OpenBetterDisplayCore

struct ShortcutsSettingsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject private var store: SettingsStore
    @State private var message: String?

    init(controller: AppController) {
        self.controller = controller
        self._store = ObservedObject(wrappedValue: controller.settingsStore)
    }

    var body: some View {
        Form {
            Section("Global Shortcuts") {
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    ShortcutRow(
                        action: action,
                        combo: store.settings.shortcuts[action],
                        isRegistered: controller.shortcutManager.registeredShortcuts[action] != nil,
                        onRecord: { combo in record(combo, for: action) },
                        onClear: {
                            message = nil
                            controller.updateSettings { $0.shortcuts.removeValue(forKey: action) }
                        }
                    )
                }
                if let message {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.orange)
                }
            }

            Section {
                HStack {
                    SettingsFootnote(text: "Click a field, then press a combination that includes ⌃, ⌥ or ⌘. Press Esc to cancel. Emergency Restore defaults to ⌃⌥⌘R.")
                    Spacer()
                    Button("Reset Defaults") {
                        message = nil
                        controller.updateSettings { $0.shortcuts = [.emergencyRestore: .emergencyRestoreDefault] }
                    }
                }
            }
        }
        .settingsTab()
    }

    private func record(_ combo: KeyCombo, for action: ShortcutAction) {
        if let other = store.settings.shortcuts.first(where: { $0.key != action && $0.value == combo })?.key {
            message = "\(combo.displayString) is already used by “\(other.displayName)”."
            return
        }
        message = nil
        controller.updateSettings { $0.shortcuts[action] = combo }
    }
}

private struct ShortcutRow: View {
    let action: ShortcutAction
    let combo: KeyCombo?
    let isRegistered: Bool
    let onRecord: (KeyCombo) -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.displayName)
                if combo != nil && !isRegistered {
                    Text("Not registered — combination may be in use by another app")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            KeyComboRecorder(combo: combo, onRecord: onRecord)
            Button("Clear", action: onClear)
                .controlSize(.small)
                .disabled(combo == nil)
        }
    }
}

// MARK: - Recorder

/// Click-to-record key combination field. Uses a local key-down monitor while recording.
struct KeyComboRecorder: View {
    let combo: KeyCombo?
    let onRecord: (KeyCombo) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording ? stopRecording() : startRecording()
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(isRecording ? Color.accentColor : (combo == nil ? Color.secondary : Color.primary))
                .frame(width: 130, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isRecording ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: isRecording ? 1.5 : 0.5)
                )
        }
        .buttonStyle(.plain)
        .onDisappear { stopRecording() }
    }

    private var label: String {
        if isRecording { return "Type shortcut…" }
        return combo?.displayString ?? "Not set"
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 { stopRecording(); return } // Esc
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.control, .option, .command]).isEmpty else {
            NSSound.beep()
            return
        }
        let wanted: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        let mask = UInt32(truncatingIfNeeded: flags.intersection(wanted).rawValue)
        let display = GlobalShortcutManager.modifierSymbols(fromCocoa: mask) + Self.keyName(for: event)
        stopRecording()
        onRecord(KeyCombo(keyCode: UInt32(event.keyCode), modifiers: mask, displayString: display))
    }

    private static let specialKeys: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 117: "⌦", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12"
    ]

    private static func keyName(for event: NSEvent) -> String {
        if let special = specialKeys[event.keyCode] { return special }
        let chars = event.charactersIgnoringModifiers?.uppercased() ?? ""
        return chars.isEmpty ? "Key \(event.keyCode)" : chars
    }
}
