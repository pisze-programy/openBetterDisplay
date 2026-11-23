import Carbon.HIToolbox
import Cocoa

/// Registers Carbon global hotkeys (no Accessibility permission needed).
@MainActor
public final class GlobalShortcutManager {
    /// 'obdp'
    private static let signature: OSType = 0x6F626470

    /// Invoked on the main actor when a registered shortcut fires.
    public var onAction: ((ShortcutAction) -> Void)?

    private var hotKeyRefs: [ShortcutAction: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?
    public private(set) var registeredShortcuts: [ShortcutAction: KeyCombo] = [:]

    public init(onAction: ((ShortcutAction) -> Void)? = nil) {
        self.onAction = onAction
    }

    deinit {
        for ref in hotKeyRefs.values { UnregisterEventHotKey(ref) }
        if let handler = eventHandlerRef { RemoveEventHandler(handler) }
    }

    // MARK: - Modifier conversion (pure)

    /// `NSEvent.ModifierFlags` raw (⌃ 0x40000, ⌥ 0x80000, ⇧ 0x20000, ⌘ 0x100000) → Carbon mask.
    public nonisolated static func carbonModifiers(fromCocoa cocoa: UInt32) -> UInt32 {
        var result: UInt32 = 0
        if cocoa & UInt32(NSEvent.ModifierFlags.control.rawValue) != 0 { result |= UInt32(controlKey) }
        if cocoa & UInt32(NSEvent.ModifierFlags.option.rawValue) != 0 { result |= UInt32(optionKey) }
        if cocoa & UInt32(NSEvent.ModifierFlags.shift.rawValue) != 0 { result |= UInt32(shiftKey) }
        if cocoa & UInt32(NSEvent.ModifierFlags.command.rawValue) != 0 { result |= UInt32(cmdKey) }
        return result
    }

    /// Carbon mask → `NSEvent.ModifierFlags` raw value (e.g. for `KeyCombo.modifiers`).
    public nonisolated static func cocoaModifiers(fromCarbon carbon: UInt32) -> UInt32 {
        var result: UInt32 = 0
        if carbon & UInt32(controlKey) != 0 { result |= UInt32(NSEvent.ModifierFlags.control.rawValue) }
        if carbon & UInt32(optionKey) != 0 { result |= UInt32(NSEvent.ModifierFlags.option.rawValue) }
        if carbon & UInt32(shiftKey) != 0 { result |= UInt32(NSEvent.ModifierFlags.shift.rawValue) }
        if carbon & UInt32(cmdKey) != 0 { result |= UInt32(NSEvent.ModifierFlags.command.rawValue) }
        return result
    }

    public nonisolated static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        carbonModifiers(fromCocoa: UInt32(truncatingIfNeeded: flags.intersection(.deviceIndependentFlagsMask).rawValue))
    }

    /// "⌃⌥⇧⌘" prefix for a Cocoa modifier mask.
    public nonisolated static func modifierSymbols(fromCocoa cocoa: UInt32) -> String {
        var s = ""
        if cocoa & UInt32(NSEvent.ModifierFlags.control.rawValue) != 0 { s += "⌃" }
        if cocoa & UInt32(NSEvent.ModifierFlags.option.rawValue) != 0 { s += "⌥" }
        if cocoa & UInt32(NSEvent.ModifierFlags.shift.rawValue) != 0 { s += "⇧" }
        if cocoa & UInt32(NSEvent.ModifierFlags.command.rawValue) != 0 { s += "⌘" }
        return s
    }

    // MARK: - Registration

    /// Replaces all registered hotkeys with `shortcuts`. Returns per-action success
    /// (false e.g. when the combo is already taken by another app or has no modifiers).
    @discardableResult
    public func register(shortcuts: [ShortcutAction: KeyCombo]) -> [ShortcutAction: Bool] {
        unregisterAll()
        installHandlerIfNeeded()

        var results: [ShortcutAction: Bool] = [:]
        for (action, combo) in shortcuts {
            // Require at least one modifier to avoid hijacking plain typing.
            let carbonMods = GlobalShortcutManager.carbonModifiers(fromCocoa: combo.modifiers)
            guard carbonMods != 0 else { results[action] = false; continue }

            let hotKeyID = EventHotKeyID(signature: GlobalShortcutManager.signature, id: GlobalShortcutManager.id(for: action))
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(combo.keyCode, carbonMods, hotKeyID, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref = ref {
                hotKeyRefs[action] = ref
                registeredShortcuts[action] = combo
                results[action] = true
            } else {
                results[action] = false
            }
        }
        return results
    }

    /// Convenience for `AppSettings.shortcuts` changes (re-registers cleanly).
    @discardableResult
    public func update(from settings: AppSettings) -> [ShortcutAction: Bool] {
        register(shortcuts: settings.shortcuts)
    }

    public func unregisterAll() {
        for ref in hotKeyRefs.values { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
        registeredShortcuts.removeAll()
    }

    // MARK: - Internals

    private nonisolated static func id(for action: ShortcutAction) -> UInt32 {
        UInt32((ShortcutAction.allCases.firstIndex(of: action) ?? 0) + 1)
    }

    private nonisolated static func action(for id: UInt32) -> ShortcutAction? {
        let index = Int(id) - 1
        guard index >= 0, index < ShortcutAction.allCases.count else { return nil }
        return ShortcutAction.allCases[index]
    }

    private func installHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event = event, let userData = userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == GlobalShortcutManager.signature,
                  let action = GlobalShortcutManager.action(for: hotKeyID.id) else {
                return OSStatus(eventNotHandledErr)
            }
            let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { manager.onAction?(action) }
            }
            return noErr
        }
        var handlerRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        if status == noErr { eventHandlerRef = handlerRef }
    }
}
