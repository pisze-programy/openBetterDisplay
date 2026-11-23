import ApplicationServices
import Cocoa
import CoreGraphics

/// Media keys we care about (NX_KEYTYPE_*).
public enum MediaKey: Int, Sendable {
    case soundUp = 0
    case soundDown = 1
    case brightnessUp = 2
    case brightnessDown = 3
    case mute = 7

    public var isBrightness: Bool { self == .brightnessUp || self == .brightnessDown }
    public var isVolume: Bool { !isBrightness }
}

/// Decoded NX_SYSDEFINED subtype-8 payload.
public struct MediaKeyEvent: Equatable, Sendable {
    public let key: MediaKey
    public let isKeyDown: Bool
    public let isRepeat: Bool
}

/// Intercepts brightness keys (always) and volume keys (only while a monitor is the active audio output).
public final class MediaKeyInterceptor {
    public static let systemDefinedSubtype: Int16 = 8
    /// Standard macOS brightness granularity (16 steps).
    public static let defaultBrightnessStep: Double = 1.0 / 16.0
    /// Fine step used when ⌥⇧ are held.
    public static let fineBrightnessStep: Double = 1.0 / 64.0
    public static let defaultVolumeStep: Double = 1.0 / 16.0

    // MARK: Handlers (invoked on the main thread)

    /// `(delta, targetDisplayIDs)` → return true if handled (event swallowed); false passes through to macOS.
    public var onBrightnessKey: ((_ delta: Double, _ displayIDs: [CGDirectDisplayID]) -> Bool)?
    /// `(key, monitorDisplayID, step)` → return true if handled. `step` is signed for up/down, 0 for mute.
    public var onVolumeKey: ((_ key: MediaKey, _ displayID: CGDirectDisplayID, _ step: Double) -> Bool)?

    // MARK: Dependencies

    private let audioBackend: AudioBackendProtocol?
    private let activeDisplayIDsProvider: () -> [CGDirectDisplayID]
    private let targetProvider: () -> MultiMonitorBrightnessTarget
    private let isBuiltInDisplay: (CGDirectDisplayID) -> Bool

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var swallowedKeys = Set<Int>()

    public init(
        audioBackend: AudioBackendProtocol?,
        activeDisplayIDsProvider: @escaping () -> [CGDirectDisplayID],
        targetProvider: @escaping () -> MultiMonitorBrightnessTarget,
        isBuiltInDisplay: @escaping (CGDirectDisplayID) -> Bool = { CGDisplayIsBuiltin($0) == 1 }
    ) {
        self.isBuiltInDisplay = isBuiltInDisplay
        self.audioBackend = audioBackend
        self.activeDisplayIDsProvider = activeDisplayIDsProvider
        self.targetProvider = targetProvider
    }

    deinit {
        stop()
    }

    // MARK: - Accessibility

    public static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    public var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    /// Prompts the user (system dialog → System Settings) if not yet trusted. Returns current trust state.
    @discardableResult
    public func requestAccessibilityPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Lifecycle

    public var isRunning: Bool { eventTap != nil }

    /// Installs the event tap. Returns false (without prompting) if Accessibility permission is missing.
    @discardableResult
    public func start() -> Bool {
        guard eventTap == nil else { return true }
        guard AXIsProcessTrusted() else { return false }

        let mask: CGEventMask = 1 << CGEventMask(NSEvent.EventType.systemDefined.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
            let interceptor = Unmanaged<MediaKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
            return interceptor.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        return true
    }

    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: - Pure helpers (unit-testable)

    /// Volume keys are intercepted ONLY when a connected external monitor is macOS's default audio output.
    public static func shouldInterceptVolumeKey(isMonitorActiveAudioOutput: Bool) -> Bool {
        isMonitorActiveAudioOutput
    }

    /// Clamped value stepping (0...1).
    public static func stepValue(current: Double, delta: Double) -> Double {
        guard current.isFinite, delta.isFinite else { return min(max(current.isFinite ? current : 0, 0), 1) }
        return min(max(current + delta, 0), 1)
    }

    /// Decodes `NSEvent.data1` of a system-defined subtype-8 event.
    public static func decode(data1: Int) -> MediaKeyEvent? {
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let flags = data1 & 0x0000FFFF
        let state = (flags & 0xFF00) >> 8
        guard let key = MediaKey(rawValue: keyCode) else { return nil }
        guard state == 0xA || state == 0xB else { return nil }
        return MediaKeyEvent(key: key, isKeyDown: state == 0xA, isRepeat: (flags & 0x1) != 0)
    }

    /// Brightness step size for the given modifier flags (⌥⇧ → fine step).
    public static func brightnessStep(for flags: NSEvent.ModifierFlags) -> Double {
        flags.contains([.option, .shift]) ? fineBrightnessStep : defaultBrightnessStep
    }

    /// Signed delta for a brightness key.
    public static func brightnessDelta(for key: MediaKey, flags: NSEvent.ModifierFlags = []) -> Double {
        let step = brightnessStep(for: flags)
        switch key {
        case .brightnessUp: return step
        case .brightnessDown: return -step
        default: return 0
        }
    }

    /// Display under the mouse cursor (via `NSEvent.mouseLocation`), if any.
    public static func displayIDUnderCursor() -> CGDirectDisplayID? {
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens where NSMouseInRect(mouse, screen.frame, false) {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                return number.uint32Value
            }
        }
        return nil
    }

    /// Brightness target displays for a given setting.
    public static func brightnessTargets(
        mode: MultiMonitorBrightnessTarget,
        cursorDisplayID: CGDirectDisplayID?,
        activeDisplayIDs: [CGDirectDisplayID]
    ) -> [CGDirectDisplayID] {
        switch mode {
        case .syncAll:
            return activeDisplayIDs
        case .cursorDisplay:
            if let id = cursorDisplayID { return [id] }
            return activeDisplayIDs.first.map { [$0] } ?? []
        }
    }

    // MARK: - Event handling

    /// First external display whose audio device is macOS's default output.
    public func activeAudioMonitor() -> CGDirectDisplayID? {
        guard let audio = audioBackend else { return nil }
        return activeDisplayIDsProvider().first { id in
            !isBuiltInDisplay(id) && audio.isMonitorDefaultOutputDevice(displayID: id)
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == NSEvent.EventType.systemDefined.rawValue,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == MediaKeyInterceptor.systemDefinedSubtype,
              let media = MediaKeyInterceptor.decode(data1: nsEvent.data1) else {
            return Unmanaged.passUnretained(event)
        }

        let flags = nsEvent.modifierFlags
        var handled = false

        if media.key.isBrightness {
            let targets = MediaKeyInterceptor.brightnessTargets(
                mode: targetProvider(),
                cursorDisplayID: MediaKeyInterceptor.displayIDUnderCursor(),
                activeDisplayIDs: activeDisplayIDsProvider()
            )
            if !targets.isEmpty, let handler = onBrightnessKey {
                if media.isKeyDown {
                    handled = handler(MediaKeyInterceptor.brightnessDelta(for: media.key, flags: flags), targets)
                    if handled { swallowedKeys.insert(media.key.rawValue) }
                } else {
                    handled = swallowedKeys.remove(media.key.rawValue) != nil // swallow matching key-up
                }
            }
        } else {
            let monitor = activeAudioMonitor()
            if MediaKeyInterceptor.shouldInterceptVolumeKey(isMonitorActiveAudioOutput: monitor != nil),
               let monitor = monitor, let handler = onVolumeKey {
                if media.isKeyDown {
                    let step: Double
                    switch media.key {
                    case .soundUp: step = MediaKeyInterceptor.defaultVolumeStep
                    case .soundDown: step = -MediaKeyInterceptor.defaultVolumeStep
                    default: step = 0
                    }
                    handled = handler(media.key, monitor, step)
                    if handled { swallowedKeys.insert(media.key.rawValue) }
                } else {
                    handled = swallowedKeys.remove(media.key.rawValue) != nil
                }
            }
        }

        return handled ? nil : Unmanaged.passUnretained(event)
    }
}
