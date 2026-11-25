import AppKit
import CoreGraphics
import Foundation
import ObjectiveC

// MARK: - CoreDisplayBridge

/// Dynamically resolved HDR control for external displays.
///
/// Resolution order for both querying and toggling HDR:
/// 1. `CoreDisplay.framework`: `CoreDisplay_Display_{Supports,Is,Set}HDRMode*`
/// 2. `SkyLight.framework`: `SLSDisplay{Supports,Is,Set}HDRMode*`
/// 3. `MonitorPanel.framework`: `MPDisplay.hasHDRModes` / `preferHDRModes` / `setPreferHDRModes:`
///
/// A missing symbol never crashes; the capability simply reports `false`.
public final class CoreDisplayBridge: @unchecked Sendable {
    public static let shared = CoreDisplayBridge()

    static let coreDisplayPath = "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay"

    typealias DisplayBoolFn = @convention(c) (CGDirectDisplayID) -> Bool
    /// Return value is unknown/unused, declared `Void` (safe on arm64: the result register is simply ignored).
    typealias CDSetHDRFn = @convention(c) (CGDirectDisplayID, Bool) -> Void
    /// `CGError SLSDisplaySetHDRModeEnabled(CGDirectDisplayID, bool, int, int)`
    typealias SLSSetHDRFn = @convention(c) (CGDirectDisplayID, Bool, Int32, Int32) -> Int32
    /// `CFDictionaryRef CoreDisplay_DisplayCreateInfoDictionary(CGDirectDisplayID)` (+1 retained)
    typealias CreateInfoDictionaryFn = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?

    private let cdSupportsHDR: DisplayBoolFn?
    private let cdIsHDREnabled: DisplayBoolFn?
    private let cdSetHDR: CDSetHDRFn?
    private let slsSupportsHDR: DisplayBoolFn?
    private let slsIsHDREnabled: DisplayBoolFn?
    private let slsSetHDR: SLSSetHDRFn?
    private let createInfoDictionary: CreateInfoDictionaryFn?

    /// Serializes HDR switching so two toggles never race each other.
    private let switchLock = NSLock()

    private init() {
        let coreDisplay = DynamicLibrary.open(CoreDisplayBridge.coreDisplayPath)
        let skyLight = DynamicLibrary.open(SkyLightBridge.skyLightPath)

        cdSupportsHDR = coreDisplay?.symbol("CoreDisplay_Display_SupportsHDRMode").map { unsafeBitCast($0, to: DisplayBoolFn.self) }
        cdIsHDREnabled = coreDisplay?.symbol("CoreDisplay_Display_IsHDRModeEnabled").map { unsafeBitCast($0, to: DisplayBoolFn.self) }
        cdSetHDR = coreDisplay?.symbol("CoreDisplay_Display_SetHDRModeEnabled").map { unsafeBitCast($0, to: CDSetHDRFn.self) }
        slsSupportsHDR = skyLight?.symbol("SLSDisplaySupportsHDRMode").map { unsafeBitCast($0, to: DisplayBoolFn.self) }
        slsIsHDREnabled = skyLight?.symbol("SLSDisplayIsHDRModeEnabled").map { unsafeBitCast($0, to: DisplayBoolFn.self) }
        slsSetHDR = skyLight?.symbol("SLSDisplaySetHDRModeEnabled").map { unsafeBitCast($0, to: SLSSetHDRFn.self) }
        createInfoDictionary = coreDisplay?.symbol("CoreDisplay_DisplayCreateInfoDictionary").map { unsafeBitCast($0, to: CreateInfoDictionaryFn.self) }
    }

    public var canToggleHDR: Bool {
        cdSetHDR != nil || slsSetHDR != nil || MonitorPanelBridge.shared.isAvailable
    }

    // MARK: HDR queries

    /// Whether the display exposes an "HDR mode" toggle. Built-in XDR panels (always-on EDR) report `false`.
    public func supportsHDR(displayID: CGDirectDisplayID) -> Bool {
        guard CGDisplayIsBuiltin(displayID) != 1 else { return false }
        if let fn = cdSupportsHDR, fn(displayID) { return true }
        if let fn = slsSupportsHDR, fn(displayID) { return true }
        if MonitorPanelBridge.shared.hasHDRModes(displayID: displayID) == true { return true }
        if let edr = Self.maximumPotentialEDR(displayID: displayID), edr > 1.0 { return true }
        return false
    }

    public func isHDREnabled(displayID: CGDirectDisplayID) -> Bool {
        guard CGDisplayIsBuiltin(displayID) != 1 else { return false }
        if let fn = cdIsHDREnabled { return fn(displayID) }
        if let fn = slsIsHDREnabled { return fn(displayID) }
        if let prefer = MonitorPanelBridge.shared.preferHDRModes(displayID: displayID) { return prefer }
        return false
    }

    // MARK: HDR toggle

    /// Switches HDR mode, trying each backend in order and verifying the resulting state.
    /// Blocks up to `verifyTimeout` per backend while the display re-trains; call off the main thread.
    ///
    /// - Warning: Mutates the live display configuration. Never call from tests.
    public func setHDREnabled(displayID: CGDirectDisplayID, enabled: Bool, verifyTimeout: TimeInterval = 2.5) throws {
        guard CGDisplayIsOnline(displayID) != 0 else { throw DisplayError.displayNotFound(displayID) }
        guard supportsHDR(displayID: displayID) else {
            throw DisplayError.unsupportedOperation("Display \(displayID) does not support HDR mode.")
        }

        switchLock.lock()
        defer { switchLock.unlock() }

        if isHDREnabled(displayID: displayID) == enabled { return }

        var attempts: [() -> Void] = []
        if let fn = cdSetHDR { attempts.append { fn(displayID, enabled) } }
        if let fn = slsSetHDR { attempts.append { _ = fn(displayID, enabled, 0, 0) } }
        if MonitorPanelBridge.shared.isAvailable {
            attempts.append { _ = MonitorPanelBridge.shared.setPreferHDRModes(displayID: displayID, enabled: enabled) }
        }
        guard !attempts.isEmpty else {
            throw DisplayError.privateAPISymbolNotFound("CoreDisplay_Display_SetHDRModeEnabled / SLSDisplaySetHDRModeEnabled / MPDisplay")
        }

        for attempt in attempts {
            attempt()
            if waitForHDRState(displayID: displayID, expected: enabled, timeout: verifyTimeout) { return }
        }
        throw DisplayError.unsupportedOperation("HDR mode did not switch to \(enabled ? "ON" : "OFF") on display \(displayID).")
    }

    private func waitForHDRState(displayID: CGDirectDisplayID, expected: Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if isHDREnabled(displayID: displayID) == expected { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return isHDREnabled(displayID: displayID) == expected
    }

    // MARK: Display info

    /// `true` when CoreDisplay marks this display as a virtual/headless framebuffer
    /// (`kCGDisplayIsVirtualDevice` or `DisplayIsSLVDExclusive`).
    public func isVirtualDevice(displayID: CGDirectDisplayID) -> Bool {
        guard let fn = createInfoDictionary,
              let dict = fn(displayID)?.takeRetainedValue() as? [String: Any]
        else { return false }
        if (dict["kCGDisplayIsVirtualDevice"] as? NSNumber)?.boolValue == true { return true }
        if (dict["DisplayIsSLVDExclusive"] as? NSNumber)?.boolValue == true { return true }
        return false
    }

    /// Localized product name from `CoreDisplay_DisplayCreateInfoDictionary` (thread-safe, works for
    /// displays without an `NSScreen`, e.g. a soft-disconnected Built-in panel returns `nil` here though).
    public func productName(displayID: CGDirectDisplayID) -> String? {
        guard let fn = createInfoDictionary,
              let dict = fn(displayID)?.takeRetainedValue() as? [String: Any],
              let names = dict["DisplayProductName"] as? [String: String],
              !names.isEmpty
        else { return nil }
        let preferred = Locale.preferredLanguages.map { $0.replacingOccurrences(of: "-", with: "_") }
        for language in preferred {
            if let name = names[language] { return name }
            if let name = names.first(where: { $0.key.hasPrefix(language.prefix(2)) })?.value { return name }
        }
        return names["en_US"] ?? names.values.sorted().first
    }

    // MARK: NSScreen helpers

    /// Main-thread only (AppKit); returns `nil` when called from a background thread.
    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        guard Thread.isMainThread else { return nil }
        return NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    static func maximumPotentialEDR(displayID: CGDirectDisplayID) -> CGFloat? {
        screen(for: displayID)?.maximumPotentialExtendedDynamicRangeColorComponentValue
    }
}

// MARK: - MonitorPanelBridge

/// Optional bridge to `MonitorPanel.framework` (`MPDisplayMgr` / `MPDisplay`) used for HDR and rotation
/// fallbacks. All selectors are validated with `responds(to:)` before being invoked via typed `IMP` casts.
final class MonitorPanelBridge: @unchecked Sendable {
    static let shared = MonitorPanelBridge()

    static let path = "/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel"

    private let lock = NSLock()
    private let managerClass: NSObject.Type?
    private var cachedManager: NSObject?

    private init() {
        _ = DynamicLibrary.open(MonitorPanelBridge.path)
        managerClass = NSClassFromString("MPDisplayMgr") as? NSObject.Type
    }

    var isAvailable: Bool { managerClass != nil }

    private func manager() -> NSObject? {
        lock.lock()
        defer { lock.unlock() }
        if let cachedManager { return cachedManager }
        guard let cls = managerClass else { return nil }
        let sharedSel = NSSelectorFromString("sharedMgr")
        var mgr: NSObject?
        if cls.responds(to: sharedSel) {
            mgr = (cls as AnyObject).perform(sharedSel)?.takeUnretainedValue() as? NSObject
        }
        if mgr == nil { mgr = cls.init() }
        cachedManager = mgr
        return mgr
    }

    func display(for displayID: CGDirectDisplayID) -> NSObject? {
        guard let mgr = manager() else { return nil }
        let sel = NSSelectorFromString("displayWithID:")
        if mgr.responds(to: sel) {
            typealias Fn = @convention(c) (AnyObject, Selector, Int32) -> Unmanaged<AnyObject>?
            let fn = unsafeBitCast(mgr.method(for: sel), to: Fn.self)
            if let display = fn(mgr, sel, Int32(bitPattern: displayID))?.takeUnretainedValue() as? NSObject {
                return display
            }
        }
        // Fallback: scan `displays` and compare `displayID`.
        let displaysSel = NSSelectorFromString("displays")
        guard mgr.responds(to: displaysSel),
              let displays = mgr.perform(displaysSel)?.takeUnretainedValue() as? [NSObject]
        else { return nil }
        return displays.first { ObjCRuntime.callInt32($0, "displayID").map { CGDirectDisplayID(bitPattern: $0) } == displayID }
    }

    func hasHDRModes(displayID: CGDirectDisplayID) -> Bool? {
        display(for: displayID).flatMap { ObjCRuntime.callBool($0, "hasHDRModes") }
    }

    func preferHDRModes(displayID: CGDirectDisplayID) -> Bool? {
        display(for: displayID).flatMap { ObjCRuntime.callBool($0, "preferHDRModes") }
    }

    @discardableResult
    func setPreferHDRModes(displayID: CGDirectDisplayID, enabled: Bool) -> Bool {
        guard let display = display(for: displayID) else { return false }
        return ObjCRuntime.callVoidBool(display, "setPreferHDRModes:", enabled)
    }

    func canChangeOrientation(displayID: CGDirectDisplayID) -> Bool? {
        display(for: displayID).flatMap { ObjCRuntime.callBool($0, "canChangeOrientation") }
    }

    func orientation(displayID: CGDirectDisplayID) -> Int? {
        display(for: displayID).flatMap { ObjCRuntime.callInt32($0, "orientation") }.map(Int.init)
    }

    @discardableResult
    func setOrientation(displayID: CGDirectDisplayID, degrees: Int) -> Bool {
        guard let display = display(for: displayID) else { return false }
        return ObjCRuntime.callVoidInt32(display, "setOrientation:", Int32(degrees))
    }
}

// MARK: - ObjCRuntime

/// Typed `IMP` invocation helpers. Each helper validates `responds(to:)` and returns `nil`/`false`
/// instead of crashing when a selector does not exist on the running macOS version.
enum ObjCRuntime {
    static func callBool(_ object: NSObject, _ selectorName: String) -> Bool? {
        let sel = NSSelectorFromString(selectorName)
        guard object.responds(to: sel) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: sel), to: Fn.self)(object, sel)
    }

    static func callInt32(_ object: NSObject, _ selectorName: String) -> Int32? {
        let sel = NSSelectorFromString(selectorName)
        guard object.responds(to: sel) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Int32
        return unsafeBitCast(object.method(for: sel), to: Fn.self)(object, sel)
    }

    @discardableResult
    static func callVoidBool(_ object: NSObject, _ selectorName: String, _ value: Bool) -> Bool {
        let sel = NSSelectorFromString(selectorName)
        guard object.responds(to: sel) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(object.method(for: sel), to: Fn.self)(object, sel, value)
        return true
    }

    @discardableResult
    static func callVoidInt32(_ object: NSObject, _ selectorName: String, _ value: Int32) -> Bool {
        let sel = NSSelectorFromString(selectorName)
        guard object.responds(to: sel) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, Int32) -> Void
        unsafeBitCast(object.method(for: sel), to: Fn.self)(object, sel, value)
        return true
    }
}
