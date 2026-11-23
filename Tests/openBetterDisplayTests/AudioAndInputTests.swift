import XCTest
import Cocoa
import Carbon.HIToolbox
import Combine
import CoreGraphics
@testable import OpenBetterDisplayCore

// MARK: - Test doubles (file-private)

fileprivate final class FakeAudioBackend: AudioBackendProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _monitorOutputs: Set<CGDirectDisplayID> = []
    private var _queried: [CGDirectDisplayID] = []

    var monitorOutputs: Set<CGDirectDisplayID> {
        get { lock.lock(); defer { lock.unlock() }; return _monitorOutputs }
        set { lock.lock(); defer { lock.unlock() }; _monitorOutputs = newValue }
    }
    var queried: [CGDirectDisplayID] { lock.lock(); defer { lock.unlock() }; return _queried }

    func isMonitorDefaultOutputDevice(displayID: CGDirectDisplayID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        _queried.append(displayID)
        return _monitorOutputs.contains(displayID)
    }
    func defaultOutputDeviceName() -> String? { "Fake" }
    func startObservingAudioOutputChanges(onChange: @escaping @Sendable () -> Void) {}
    func stopObservingAudioOutputChanges() {}
}

// MARK: - MediaKeyInterceptor (pure + routing)

final class MediaKeyInterceptorTests: XCTestCase {
    private typealias MK = MediaKeyInterceptor

    // MARK: Volume interception policy

    func testVolumeKeysOnlyInterceptedWhenMonitorIsActiveAudioOutput() {
        XCTAssertTrue(MK.shouldInterceptVolumeKey(isMonitorActiveAudioOutput: true))
        XCTAssertFalse(MK.shouldInterceptVolumeKey(isMonitorActiveAudioOutput: false),
                       "speakers / headphones / Bluetooth must pass through untouched")
    }

    func testActiveAudioMonitorReturnsNilForSpeakersHeadphonesAndBluetooth() {
        let audio = FakeAudioBackend() // default output is NOT any monitor
        let interceptor = MK(audioBackend: audio, activeDisplayIDsProvider: { [9001, 9002] }, targetProvider: { .cursorDisplay }, isBuiltInDisplay: { _ in false })
        XCTAssertNil(interceptor.activeAudioMonitor())
        XCTAssertEqual(Set(audio.queried), [9001, 9002], "every external display is consulted")
        XCTAssertFalse(MK.shouldInterceptVolumeKey(isMonitorActiveAudioOutput: interceptor.activeAudioMonitor() != nil))
    }

    func testActiveAudioMonitorFindsTheMonitorThatOwnsTheOutput() {
        let audio = FakeAudioBackend()
        audio.monitorOutputs = [9002]
        let interceptor = MK(audioBackend: audio, activeDisplayIDsProvider: { [9001, 9002] }, targetProvider: { .cursorDisplay }, isBuiltInDisplay: { _ in false })
        XCTAssertEqual(interceptor.activeAudioMonitor(), 9002)
        XCTAssertTrue(MK.shouldInterceptVolumeKey(isMonitorActiveAudioOutput: interceptor.activeAudioMonitor() != nil))
    }

    func testBuiltInDisplaysAreNeverTreatedAsMonitorAudio() {
        let audio = FakeAudioBackend()
        audio.monitorOutputs = [9001, 9002]
        let interceptor = MK(audioBackend: audio, activeDisplayIDsProvider: { [9001, 9002] }, targetProvider: { .cursorDisplay },
                             isBuiltInDisplay: { $0 == 9001 })
        XCTAssertEqual(interceptor.activeAudioMonitor(), 9002)
        XCTAssertFalse(audio.queried.contains(9001), "built-in is skipped without asking CoreAudio")
    }

    func testUnknownDisplayIDIsNotMistakenForBuiltIn() {
        // CGDisplayIsBuiltin returns -1 (not 0) for invalid IDs; only an exact 1 means built-in.
        let unknown: CGDirectDisplayID = 999_999
        let audio = FakeAudioBackend()
        audio.monitorOutputs = [unknown]
        let interceptor = MK(audioBackend: audio, activeDisplayIDsProvider: { [unknown] }, targetProvider: { .cursorDisplay })
        XCTAssertEqual(interceptor.activeAudioMonitor(), unknown, "default built-in check must not crash or misclassify unknown IDs")
        XCTAssertEqual(audio.queried, [unknown])
    }

    func testActiveAudioMonitorIsNilWithoutAudioBackendOrDisplays() {
        let noAudio = MK(audioBackend: nil, activeDisplayIDsProvider: { [9001] }, targetProvider: { .cursorDisplay })
        XCTAssertNil(noAudio.activeAudioMonitor())
        let noDisplays = MK(audioBackend: FakeAudioBackend(), activeDisplayIDsProvider: { [] }, targetProvider: { .cursorDisplay })
        XCTAssertNil(noDisplays.activeAudioMonitor())
    }

    // MARK: Brightness targets

    func testBrightnessTargetsCursorDisplay() {
        XCTAssertEqual(MK.brightnessTargets(mode: .cursorDisplay, cursorDisplayID: 3, activeDisplayIDs: [1, 3]), [3])
        XCTAssertEqual(MK.brightnessTargets(mode: .cursorDisplay, cursorDisplayID: nil, activeDisplayIDs: [1, 3]), [1],
                       "no cursor display -> first active display")
        XCTAssertEqual(MK.brightnessTargets(mode: .cursorDisplay, cursorDisplayID: nil, activeDisplayIDs: []), [])
    }

    func testBrightnessTargetsSyncAll() {
        XCTAssertEqual(MK.brightnessTargets(mode: .syncAll, cursorDisplayID: 3, activeDisplayIDs: [1, 3, 5]), [1, 3, 5])
        XCTAssertEqual(MK.brightnessTargets(mode: .syncAll, cursorDisplayID: nil, activeDisplayIDs: []), [])
    }

    // MARK: Stepping

    func testStepValueClampsToUnitRange() {
        XCTAssertEqual(MK.stepValue(current: 0.5, delta: 0.0625), 0.5625, accuracy: 1e-12)
        XCTAssertEqual(MK.stepValue(current: 0.95, delta: 0.1), 1.0)
        XCTAssertEqual(MK.stepValue(current: 0.02, delta: -0.1), 0.0)
        XCTAssertEqual(MK.stepValue(current: 5, delta: 0), 1.0)
        XCTAssertEqual(MK.stepValue(current: -5, delta: 0), 0.0)
    }

    func testStepValueIsRobustToNonFiniteInput() {
        XCTAssertEqual(MK.stepValue(current: .nan, delta: 0.1), 0.0)
        XCTAssertEqual(MK.stepValue(current: 0.4, delta: .nan), 0.4)
        XCTAssertEqual(MK.stepValue(current: 0.4, delta: .infinity), 0.4)
    }

    func testSixteenStepsTraverseTheFullRange() {
        var value = 0.0
        for _ in 0..<16 { value = MK.stepValue(current: value, delta: MK.defaultBrightnessStep) }
        XCTAssertEqual(value, 1.0, accuracy: 1e-9)
    }

    func testBrightnessStepSizes() {
        XCTAssertEqual(MK.defaultBrightnessStep, 1.0 / 16.0)
        XCTAssertEqual(MK.fineBrightnessStep, 1.0 / 64.0)
        XCTAssertEqual(MK.brightnessStep(for: []), 1.0 / 16.0)
        XCTAssertEqual(MK.brightnessStep(for: [.option]), 1.0 / 16.0)
        XCTAssertEqual(MK.brightnessStep(for: [.shift]), 1.0 / 16.0)
        XCTAssertEqual(MK.brightnessStep(for: [.option, .shift]), 1.0 / 64.0)
        XCTAssertEqual(MK.brightnessStep(for: [.option, .shift, .command]), 1.0 / 64.0)
    }

    func testBrightnessDeltaSignAndFineStep() {
        XCTAssertEqual(MK.brightnessDelta(for: .brightnessUp), 0.0625)
        XCTAssertEqual(MK.brightnessDelta(for: .brightnessDown), -0.0625)
        XCTAssertEqual(MK.brightnessDelta(for: .brightnessUp, flags: [.option, .shift]), 1.0 / 64.0)
        XCTAssertEqual(MK.brightnessDelta(for: .brightnessDown, flags: [.option, .shift]), -1.0 / 64.0)
        XCTAssertEqual(MK.brightnessDelta(for: .soundUp), 0)
        XCTAssertEqual(MK.brightnessDelta(for: .mute), 0)
    }

    // MARK: Decoding NX_SYSDEFINED data1

    private func data1(key: Int, state: Int, repeatFlag: Bool = false) -> Int {
        (key << 16) | (state << 8) | (repeatFlag ? 1 : 0)
    }

    func testDecodeBrightnessKeys() {
        XCTAssertEqual(MK.decode(data1: data1(key: 2, state: 0xA)),
                       MediaKeyEvent(key: .brightnessUp, isKeyDown: true, isRepeat: false))
        XCTAssertEqual(MK.decode(data1: data1(key: 3, state: 0xA)),
                       MediaKeyEvent(key: .brightnessDown, isKeyDown: true, isRepeat: false))
    }

    func testDecodeSoundKeys() {
        XCTAssertEqual(MK.decode(data1: data1(key: 0, state: 0xA))?.key, .soundUp)
        XCTAssertEqual(MK.decode(data1: data1(key: 1, state: 0xA))?.key, .soundDown)
        XCTAssertEqual(MK.decode(data1: data1(key: 7, state: 0xA))?.key, .mute)
    }

    func testDecodeKeyUpAndRepeatFlags() {
        let up = MK.decode(data1: data1(key: 2, state: 0xB))
        XCTAssertEqual(up?.isKeyDown, false)
        XCTAssertEqual(up?.isRepeat, false)

        let repeating = MK.decode(data1: data1(key: 3, state: 0xA, repeatFlag: true))
        XCTAssertEqual(repeating?.isKeyDown, true)
        XCTAssertEqual(repeating?.isRepeat, true)
    }

    func testDecodeIgnoresUnknownKeysAndInvalidStates() {
        XCTAssertNil(MK.decode(data1: data1(key: 5, state: 0xA)), "NX_KEYTYPE_* we do not handle")
        XCTAssertNil(MK.decode(data1: data1(key: 16, state: 0xA)), "play/pause")
        XCTAssertNil(MK.decode(data1: data1(key: 2, state: 0x0)), "no key state")
        XCTAssertNil(MK.decode(data1: data1(key: 2, state: 0xC)))
        XCTAssertNil(MK.decode(data1: 0))
    }

    func testMediaKeyClassification() {
        XCTAssertTrue(MediaKey.brightnessUp.isBrightness)
        XCTAssertTrue(MediaKey.brightnessDown.isBrightness)
        XCTAssertFalse(MediaKey.brightnessUp.isVolume)
        for key in [MediaKey.soundUp, .soundDown, .mute] {
            XCTAssertTrue(key.isVolume)
            XCTAssertFalse(key.isBrightness)
        }
        XCTAssertEqual(MediaKey.soundUp.rawValue, 0)
        XCTAssertEqual(MediaKey.soundDown.rawValue, 1)
        XCTAssertEqual(MediaKey.brightnessUp.rawValue, 2)
        XCTAssertEqual(MediaKey.brightnessDown.rawValue, 3)
        XCTAssertEqual(MediaKey.mute.rawValue, 7)
        XCTAssertEqual(MK.systemDefinedSubtype, 8)
    }

    // MARK: Lifecycle (no tap is installed)

    func testFreshInterceptorIsNotRunningAndStopIsSafe() {
        let interceptor = MK(audioBackend: nil, activeDisplayIDsProvider: { [] }, targetProvider: { .syncAll })
        XCTAssertFalse(interceptor.isRunning)
        interceptor.stop()
        interceptor.stop()
        XCTAssertFalse(interceptor.isRunning)
    }
}

// MARK: - GlobalShortcutManager

@MainActor
final class GlobalShortcutManagerTests: XCTestCase {
    private var manager: GlobalShortcutManager!

    // Obscure combos (⌃⌥⇧⌘ + F18/F19) so we never collide with a running copy of the app or other tools.
    private let f19 = KeyCombo(keyCode: 80, modifiers: 0x40000 | 0x80000 | 0x20000 | 0x100000, displayString: "⌃⌥⇧⌘F19")
    private let f18 = KeyCombo(keyCode: 79, modifiers: 0x40000 | 0x80000 | 0x20000 | 0x100000, displayString: "⌃⌥⇧⌘F18")

    override func setUp() async throws { manager = GlobalShortcutManager() }

    override func tearDown() async throws {
        manager.unregisterAll()
        manager = nil
    }

    func testEmergencyRestoreDefaultMapsToControlOptionCommand() {
        let cocoa = KeyCombo.emergencyRestoreDefault.modifiers
        XCTAssertEqual(cocoa, 0x1C0000)
        let carbon = GlobalShortcutManager.carbonModifiers(fromCocoa: cocoa)
        XCTAssertEqual(carbon, UInt32(controlKey | optionKey | cmdKey))
        XCTAssertEqual(carbon & UInt32(shiftKey), 0)
        XCTAssertEqual(KeyCombo.emergencyRestoreDefault.keyCode, 15)
        XCTAssertEqual(GlobalShortcutManager.cocoaModifiers(fromCarbon: carbon), 0x1C0000)
    }

    func testIndividualModifierConversion() {
        XCTAssertEqual(GlobalShortcutManager.carbonModifiers(fromCocoa: 0x40000), UInt32(controlKey))
        XCTAssertEqual(GlobalShortcutManager.carbonModifiers(fromCocoa: 0x80000), UInt32(optionKey))
        XCTAssertEqual(GlobalShortcutManager.carbonModifiers(fromCocoa: 0x20000), UInt32(shiftKey))
        XCTAssertEqual(GlobalShortcutManager.carbonModifiers(fromCocoa: 0x100000), UInt32(cmdKey))
        XCTAssertEqual(GlobalShortcutManager.carbonModifiers(fromCocoa: 0), 0)
    }

    func testAllSixteenModifierCombinationsRoundTrip() {
        let cocoaBits: [UInt32] = [0x20000, 0x40000, 0x80000, 0x100000]
        for mask in 0..<16 {
            var cocoa: UInt32 = 0
            for (i, bit) in cocoaBits.enumerated() where mask & (1 << i) != 0 { cocoa |= bit }
            let carbon = GlobalShortcutManager.carbonModifiers(fromCocoa: cocoa)
            XCTAssertEqual(GlobalShortcutManager.cocoaModifiers(fromCarbon: carbon), cocoa, "mask \(mask)")
        }
    }

    func testUnrelatedCocoaBitsAreIgnored() {
        let capsLock: UInt32 = 0x10000, numericPad: UInt32 = 0x200000, function: UInt32 = 0x800000
        XCTAssertEqual(GlobalShortcutManager.carbonModifiers(fromCocoa: capsLock | numericPad | function), 0)
        XCTAssertEqual(GlobalShortcutManager.carbonModifiers(fromCocoa: capsLock | 0x100000), UInt32(cmdKey))
    }

    func testConversionFromModifierFlags() {
        XCTAssertEqual(GlobalShortcutManager.carbonModifiers(from: [.control, .option, .command]), UInt32(controlKey | optionKey | cmdKey))
        XCTAssertEqual(GlobalShortcutManager.carbonModifiers(from: [.shift, .capsLock]), UInt32(shiftKey))
    }

    func testModifierSymbols() {
        XCTAssertEqual(GlobalShortcutManager.modifierSymbols(fromCocoa: 0x1C0000), "⌃⌥⌘")
        XCTAssertEqual(GlobalShortcutManager.modifierSymbols(fromCocoa: 0x1E0000), "⌃⌥⇧⌘")
        XCTAssertEqual(GlobalShortcutManager.modifierSymbols(fromCocoa: 0), "")
    }

    func testZeroModifierShortcutIsRejected() {
        let bare = KeyCombo(keyCode: 0, modifiers: 0, displayString: "A")
        let result = manager.register(shortcuts: [.toggleHDR: bare])
        XCTAssertEqual(result, [.toggleHDR: false])
        XCTAssertTrue(manager.registeredShortcuts.isEmpty)
    }

    func testModifierOnlyFromUnrelatedBitsIsRejected() {
        let capsOnly = KeyCombo(keyCode: 0, modifiers: 0x10000, displayString: "⇪A")
        XCTAssertEqual(manager.register(shortcuts: [.toggleHDR: capsOnly]), [.toggleHDR: false])
    }

    func testRegisterAndUnregisterRealHotKeys() {
        let result = manager.register(shortcuts: [.toggleHDR: f19, .toggleNightShift: f18])
        XCTAssertEqual(result, [.toggleHDR: true, .toggleNightShift: true])
        XCTAssertEqual(manager.registeredShortcuts, [.toggleHDR: f19, .toggleNightShift: f18])

        manager.unregisterAll()
        XCTAssertTrue(manager.registeredShortcuts.isEmpty)

        // Can re-register the very same combos after unregistering.
        XCTAssertEqual(manager.register(shortcuts: [.toggleHDR: f19]), [.toggleHDR: true])
    }

    func testRegisterReplacesPreviousSetCleanly() {
        manager.register(shortcuts: [.toggleHDR: f19])
        let second = manager.register(shortcuts: [.toggleBuiltIn: f19])
        XCTAssertEqual(second, [.toggleBuiltIn: true], "old registration was released first")
        XCTAssertEqual(manager.registeredShortcuts, [.toggleBuiltIn: f19])
    }

    func testUpdateFromSettingsReRegisters() {
        var settings = AppSettings(shortcuts: [.toggleHDR: f19])
        XCTAssertEqual(manager.update(from: settings), [.toggleHDR: true])
        XCTAssertEqual(manager.registeredShortcuts, [.toggleHDR: f19])

        settings.shortcuts = [.toggleNightShift: f18]
        XCTAssertEqual(manager.update(from: settings), [.toggleNightShift: true])
        XCTAssertEqual(manager.registeredShortcuts, [.toggleNightShift: f18])

        settings.shortcuts = [:]
        XCTAssertTrue(manager.update(from: settings).isEmpty)
        XCTAssertTrue(manager.registeredShortcuts.isEmpty)
    }

    func testMixedValidAndInvalidShortcuts() {
        let bad = KeyCombo(keyCode: 0, modifiers: 0, displayString: "A")
        let result = manager.register(shortcuts: [.toggleHDR: f19, .toggleBuiltIn: bad])
        XCTAssertEqual(result[.toggleHDR], true)
        XCTAssertEqual(result[.toggleBuiltIn], false)
        XCTAssertEqual(Set(manager.registeredShortcuts.keys), [.toggleHDR])
    }

    func testDefaultSettingsOnlyShipEmergencyRestore() {
        XCTAssertEqual(Array(AppSettings.default.shortcuts.keys), [.emergencyRestore])
        XCTAssertEqual(AppSettings.default.shortcuts[.emergencyRestore], .emergencyRestoreDefault)
    }
}

// MARK: - OSDHUDController

@MainActor
final class OSDHUDControllerTests: XCTestCase {
    private var hud: OSDHUDController!

    override func setUp() async throws {
        _ = NSApplication.shared
        hud = OSDHUDController()
    }

    override func tearDown() async throws {
        hud.hide(animated: false)
        hud.currentPanel?.close()
        hud = nil
    }

    // MARK: Pure helpers

    func testSymbolNames() {
        XCTAssertEqual(OSDHUDController.symbolName(for: OSDItem(kind: .brightness, value: 0.5, title: "B")), "sun.max.fill")
        XCTAssertEqual(OSDHUDController.symbolName(for: OSDItem(kind: .mute, isMuted: true, title: "M")), "speaker.slash.fill")
        XCTAssertEqual(OSDHUDController.symbolName(for: OSDItem(kind: .notice, title: "N")), "display")
    }

    func testVolumeSymbolFollowsLevelAndMute() {
        func symbol(_ value: Double?, muted: Bool = false) -> String {
            OSDHUDController.symbolName(for: OSDItem(kind: .volume, value: value, isMuted: muted, title: "V"))
        }
        XCTAssertEqual(symbol(0.0), "speaker.fill")
        XCTAssertEqual(symbol(nil), "speaker.fill")
        XCTAssertEqual(symbol(0.2), "speaker.wave.1.fill")
        XCTAssertEqual(symbol(0.5), "speaker.wave.2.fill")
        XCTAssertEqual(symbol(0.67), "speaker.wave.3.fill")
        XCTAssertEqual(symbol(1.0), "speaker.wave.3.fill")
        XCTAssertEqual(symbol(0.9, muted: true), "speaker.slash.fill")
    }

    func testProgressValueClampsAndHandlesMuteAndMissingValue() {
        func progress(_ kind: OSDItem.Kind, _ value: Double?, muted: Bool = false) -> Double? {
            OSDHUDController.progressValue(for: OSDItem(kind: kind, value: value, isMuted: muted, title: "T"))
        }
        XCTAssertEqual(progress(.brightness, 0.4), 0.4)
        XCTAssertEqual(progress(.brightness, 1.7), 1.0)
        XCTAssertEqual(progress(.brightness, -0.3), 0.0)
        XCTAssertEqual(progress(.volume, 0.8), 0.8)
        XCTAssertEqual(progress(.volume, 0.8, muted: true), 0.0, "muted volume shows an empty bar")
        XCTAssertEqual(progress(.mute, nil), 0.0)
        XCTAssertEqual(progress(.mute, 0.9), 0.0)
        XCTAssertNil(progress(.notice, nil), "notices without a value have no bar")
        XCTAssertNil(progress(.brightness, nil))
    }

    func testPanelFrameIsBottomCenterOfVisibleFrame() {
        let visible = NSRect(x: 0, y: 25, width: 1440, height: 875)
        let frame = OSDHUDController.panelFrame(visibleFrame: visible)
        XCTAssertEqual(frame.size, OSDHUDController.panelSize)
        XCTAssertEqual(frame.midX, visible.midX, accuracy: 0.001)
        XCTAssertEqual(frame.minY, visible.minY + OSDHUDController.bottomMargin, accuracy: 0.001)
    }

    func testPanelFrameOnSecondaryScreenWithNegativeOrigin() {
        let visible = NSRect(x: -1920, y: 100, width: 1920, height: 1055)
        let frame = OSDHUDController.panelFrame(visibleFrame: visible, size: NSSize(width: 100, height: 40))
        XCTAssertEqual(frame.origin.x, -1920 + 960 - 50, accuracy: 0.001)
        XCTAssertEqual(frame.origin.y, 100 + OSDHUDController.bottomMargin, accuracy: 0.001)
        XCTAssertEqual(frame.size, NSSize(width: 100, height: 40))
    }

    func testDefaultsAndApplySettings() {
        XCTAssertTrue(hud.isEnabled)
        XCTAssertEqual(hud.duration, OSDHUDController.defaultDuration)
        XCTAssertEqual(OSDHUDController.defaultDuration, 1.8)

        hud.apply(settings: AppSettings(showOSD: false, osdDurationSeconds: 4.5))
        XCTAssertFalse(hud.isEnabled)
        XCTAssertEqual(hud.duration, 4.5)
    }

    // MARK: Panel behaviour

    func testDisabledHUDNeverCreatesAPanel() {
        hud.isEnabled = false
        hud.show(OSDItem(kind: .brightness, value: 0.5, title: "Brightness"))
        XCTAssertNil(hud.currentPanel)
        XCTAssertFalse(hud.isVisible)
    }

    func testPanelIsTranslucentClickThroughNonActivatingAndCaptureInvisible() throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "no screens available (headless)")
        hud.show(OSDItem(kind: .brightness, value: 0.5, title: "Brightness", subtitle: "DDC"), duration: 5)

        let panel = try XCTUnwrap(hud.currentPanel)
        XCTAssertTrue(hud.isVisible)
        XCTAssertEqual(panel.sharingType, .none)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.backgroundColor, .clear)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertEqual(panel.level.rawValue, OverlayManager.overlayWindowLevel.rawValue + 1, "HUD sits above the dimming overlay")
        XCTAssertTrue(panel.contentView is NSVisualEffectView)
        XCTAssertEqual(panel.frame.size, OSDHUDController.panelSize)
        XCTAssertFalse(NSApp.isActive && panel.isKeyWindow, "must not steal focus")
    }

    func testPanelIsReusedAcrossShowCalls() throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "no screens available (headless)")
        hud.show(OSDItem(kind: .brightness, value: 0.2, title: "Brightness"), duration: 5)
        let first = hud.currentPanel
        hud.show(OSDItem(kind: .volume, value: 0.7, title: "Volume"), duration: 5)
        XCTAssertTrue(first === hud.currentPanel)
    }

    func testHideTakesTheHUDAwayImmediatelyWhenNotAnimated() throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "no screens available (headless)")
        hud.show(OSDItem(kind: .notice, title: "Built-in Display Restored"), duration: 5)
        XCTAssertTrue(hud.isVisible)
        hud.hide(animated: false)
        XCTAssertFalse(hud.isVisible)
    }

    func testHUDAutoHidesAfterItsDuration() async throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "no screens available (headless)")
        hud.show(OSDItem(kind: .brightness, value: 0.5, title: "Brightness"), duration: 0.2)
        XCTAssertTrue(hud.isVisible)

        let deadline = Date().addingTimeInterval(4)
        while hud.isVisible && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(hud.isVisible, "HUD should fade out and order out by itself")
    }
}

// MARK: - SettingsStore

@MainActor
final class SettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "com.piszeprogramy.openbetterdisplay.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func testFreshStoreLoadsDefaults() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.settings, AppSettings.default)
        XCTAssertNil(defaults.data(forKey: SettingsStore.defaultsKey), "nothing is written until something changes")
    }

    func testRoundTripThroughUserDefaults() {
        let store = SettingsStore(defaults: defaults)
        var custom = AppSettings.default
        custom.launchAtLogin = true
        custom.brightnessTarget = .syncAll
        custom.showOSD = false
        custom.osdDurationSeconds = 3.25
        custom.nightShift = NightShiftConfig(enabled: true, scheduleEnabled: false, startHour: 20, startMinute: 15,
                                             endHour: 6, endMinute: 45, warmth: 0.8, transitionMinutes: 30,
                                             applySoftwareFallbackInHDR: false, timeZoneIdentifier: "Europe/Warsaw")
        custom.shortcuts = [
            .emergencyRestore: .emergencyRestoreDefault,
            .toggleHDR: KeyCombo(keyCode: 4, modifiers: 0x1C0000, displayString: "⌃⌥⌘H")
        ]
        store.settings = custom

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.settings, custom)
        XCTAssertEqual(reloaded.settings.shortcuts[.toggleHDR]?.displayString, "⌃⌥⌘H")
        XCTAssertEqual(reloaded.settings.nightShift.timeZoneIdentifier, "Europe/Warsaw")
    }

    func testUpdateMutatesPersistsAndNotifies() {
        let store = SettingsStore(defaults: defaults)
        var notifications: [AppSettings] = []
        store.onChange = { notifications.append($0) }

        store.update { $0.nightShift.enabled = true; $0.osdDurationSeconds = 2.5 }

        XCTAssertTrue(store.settings.nightShift.enabled)
        XCTAssertEqual(store.settings.osdDurationSeconds, 2.5)
        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications.first, store.settings)
        XCTAssertEqual(SettingsStore(defaults: defaults).settings, store.settings)
    }

    func testNoOpChangesDoNotPersistOrNotify() {
        let store = SettingsStore(defaults: defaults)
        var count = 0
        store.onChange = { _ in count += 1 }
        store.update { _ in }
        store.settings = AppSettings.default
        XCTAssertEqual(count, 0)
        XCTAssertNil(defaults.data(forKey: SettingsStore.defaultsKey))
    }

    func testResetToDefaults() {
        let store = SettingsStore(defaults: defaults)
        store.update { $0.launchAtLogin = true; $0.brightnessTarget = .syncAll }
        XCTAssertNotEqual(store.settings, AppSettings.default)

        store.resetToDefaults()

        XCTAssertEqual(store.settings, AppSettings.default)
        XCTAssertEqual(SettingsStore(defaults: defaults).settings, AppSettings.default)
    }

    func testReloadPicksUpExternalWrites() throws {
        let store = SettingsStore(defaults: defaults)
        var external = AppSettings.default
        external.showOSD = false
        external.osdDurationSeconds = 9
        defaults.set(try JSONEncoder().encode(external), forKey: SettingsStore.defaultsKey)

        XCTAssertTrue(store.settings.showOSD, "not observed until reload")
        store.reload()
        XCTAssertEqual(store.settings, external)
    }

    func testCorruptDataFallsBackToDefaults() {
        defaults.set(Data("garbage".utf8), forKey: SettingsStore.defaultsKey)
        XCTAssertEqual(SettingsStore(defaults: defaults).settings, AppSettings.default)
        XCTAssertEqual(SettingsStore.load(defaults: defaults), AppSettings.default)
    }

    func testCustomKeysAreIsolated() {
        let a = SettingsStore(defaults: defaults, key: "a")
        let b = SettingsStore(defaults: defaults, key: "b")
        a.update { $0.launchAtLogin = true }
        XCTAssertTrue(SettingsStore(defaults: defaults, key: "a").settings.launchAtLogin)
        XCTAssertFalse(b.settings.launchAtLogin)
        XCTAssertFalse(SettingsStore(defaults: defaults, key: "b").settings.launchAtLogin)
    }

    func testPublishedSettingsEmitToObservers() {
        let store = SettingsStore(defaults: defaults)
        var received: [AppSettings] = []
        let cancellable = store.$settings.dropFirst().sink { received.append($0) }
        store.update { $0.showOSD = false }
        cancellable.cancel()
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.showOSD, false)
    }
}
