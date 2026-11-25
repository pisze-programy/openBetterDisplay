import AppKit
import CoreGraphics
import Foundation
import IOKit
import os

private let displayLogger = Logger(subsystem: "com.piszeprogramy.openbetterdisplay", category: "display")

// MARK: - DisplayManager

/// Live CoreGraphics / SkyLight display backend (`DisplayBackendProtocol`).
///
/// - Enumerates online + active displays **and** the soft-disconnected Built-in Display (which disappears
///   from `CGGetOnlineDisplayList` once disabled, but is still listed by `SLSGetDisplayList`).
/// - Every configuration change runs inside a `CGBeginDisplayConfiguration` transaction completed with
///   `.forSession`, so a logout/reboot always restores a sane configuration.
/// - Enforces the **Single-Display Guard**: the Built-in Display is never disabled unless at least one other
///   online & active external display exists.
/// - Thread-safe: configuration changes are serialized with a lock; queries may be called from any thread.
public final class DisplayManager: DisplayBackendProtocol, @unchecked Sendable {
    public typealias DDCAvailabilityProvider = @Sendable (CGDirectDisplayID) -> Bool

    private let skyLight: SkyLightBridge
    private let coreDisplay: CoreDisplayBridge
    private let ddcAvailability: DDCAvailabilityProvider

    /// Serializes display configuration transactions.
    private let configLock = NSRecursiveLock()
    /// Protects mutable state below.
    private let stateLock = NSLock()
    private var cachedBuiltInID: CGDirectDisplayID?
    /// External displays soft-disconnected by the user via our toggle (kept so the UI can turn them back ON).
    private var softDisabledExternals: [CGDirectDisplayID: DisplayInfo] = [:]
    private var reconfigurationHandler: (@Sendable () -> Void)?
    private var isObservingReconfiguration = false
    private var reconfigurationDispatchPending = false

    /// - Parameters:
    ///   - ddcAvailability: decides `DisplayInfo.supportsDDC` (defaults to `IOAVServiceBridge.shared.hasService`).
    public init(
        skyLight: SkyLightBridge = .shared,
        coreDisplay: CoreDisplayBridge = .shared,
        ddcAvailability: DDCAvailabilityProvider? = nil
    ) {
        self.skyLight = skyLight
        self.coreDisplay = coreDisplay
        self.ddcAvailability = ddcAvailability ?? { IOAVServiceBridge.shared.hasService(for: $0) }
        // Eagerly cache the Built-in Display ID while it is discoverable.
        _ = builtInDisplayID()
    }

    deinit {
        stopReconfigurationObserver()
    }

    // MARK: - Display ID lists

    public static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        displayList(CGGetOnlineDisplayList)
    }

    public static func activeDisplayIDs() -> [CGDirectDisplayID] {
        displayList(CGGetActiveDisplayList)
    }

    private static func displayList(
        _ fn: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError
    ) -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        guard fn(32, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(min(count, 32))))
    }

    /// Safe conversion of CoreGraphics `boolean_t` return values.
    ///
    /// CoreGraphics display query functions (`CGDisplayIsActive`, `CGDisplayIsOnline`, `CGDisplayIsBuiltin`,
    /// `CGDisplayIsInMirrorSet`, `CGDisplayIsMain`) return `-1` (`0xFFFFFFFF` as `UInt32`) when a display ID
    /// is invalid or temporarily removed from the client display table (for example during macOS headless
    /// `kCGSDisplayMovedOffConsoleInternal` transitions). Comparing `!= 0` treats `-1` as `true`!
    public static func isCGTrue(_ value: boolean_t) -> Bool {
        value == 1
    }

    /// Safe `CGDisplayMirrorsDisplay` wrapper that treats both `kCGNullDirectDisplay` (`0`) and the
    /// invalid-display error sentinel (`UInt32.max`) as `nil`.
    public static func validMirrorMaster(rawValue: CGDirectDisplayID) -> CGDirectDisplayID? {
        (rawValue == kCGNullDirectDisplay || rawValue == UInt32.max) ? nil : rawValue
    }

    /// Online & active **physical** external displays (the set the Single-Display Guard and failsafe rely on).
    /// Excludes virtual/headless placeholder displays spawned by WindowServer when all physical displays vanish.
    public func activeExternalDisplayIDs() -> [CGDirectDisplayID] {
        let active = Set(Self.activeDisplayIDs())
        return Self.onlineDisplayIDs().filter { id in
            !Self.isCGTrue(CGDisplayIsBuiltin(id)) &&
                !isVirtualDisplay(displayID: id) &&
                (active.contains(id) || Self.isCGTrue(CGDisplayIsActive(id)))
        }
    }

    /// `true` if `displayID` is a virtual/headless placeholder framebuffer rather than a real physical display.
    public func isVirtualDisplay(displayID: CGDirectDisplayID) -> Bool {
        guard !Self.isCGTrue(CGDisplayIsBuiltin(displayID)) else { return false }
        return Self.isVirtualDisplay(
            vendor: CGDisplayVendorNumber(displayID),
            model: CGDisplayModelNumber(displayID),
            isVirtualDeviceFlag: coreDisplay.isVirtualDevice(displayID: displayID)
        )
    }

    /// Pure virtual/placeholder detector (unit-testable).
    public static func isVirtualDisplay(vendor: UInt32, model: UInt32, isVirtualDeviceFlag: Bool) -> Bool {
        isVirtualDeviceFlag || DisplayIdentifier.isVirtualSentinel(vendor: vendor, model: model)
    }

    /// The Built-in Display ID, even while it is soft-disconnected (resolved via `SLSGetDisplayList`).
    public func builtInDisplayID() -> CGDirectDisplayID? {
        var candidates = Self.onlineDisplayIDs() + Self.activeDisplayIDs()
        if let all = skyLight.allKnownDisplayIDs() { candidates += all }
        if let found = candidates.first(where: { Self.isCGTrue(CGDisplayIsBuiltin($0)) }) {
            stateLock.lock()
            cachedBuiltInID = found
            stateLock.unlock()
            return found
        }
        stateLock.lock()
        defer { stateLock.unlock() }
        // `cachedBuiltInID` was already verified via `CGDisplayIsBuiltin == 1` when discovered;
        // trust it even if WindowServer temporarily drops the built-in entry during a headless transition.
        return cachedBuiltInID
    }

    /// `true` when the MacBook lid is closed (IOPMrootDomain `AppleClamshellState`).
    public static func isLidClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? Bool) ?? false
    }

    // MARK: - Pure guard helpers (unit-testable)

    /// Single-Display Guard: the Built-in Display may only be disabled while at least one other online and
    /// enabled **physical** external display exists (virtual/headless placeholders never satisfy the guard).
    public static func canDisableBuiltIn(displays: [DisplayInfo]) -> Bool {
        displays.contains { !$0.isBuiltIn && !$0.isVirtual && $0.isOnline && $0.isEnabled }
    }

    /// Whether `id` may be disabled right now without leaving the Mac with zero usable displays.
    /// - Built-in Display: requires at least one other active physical external display.
    /// - External display: allowed whenever another active physical display is on, OR the Built-in Display
    ///   is physically present (lid open) so we can automatically switch to it.
    public static func canDisableDisplay(id: CGDirectDisplayID, displays: [DisplayInfo]) -> Bool {
        guard let target = displays.first(where: { $0.id == id && !$0.isVirtual }) else { return false }
        if target.isBuiltIn {
            return canDisableBuiltIn(displays: displays)
        }
        if displays.contains(where: { $0.id != id && !$0.isVirtual && $0.isOnline && $0.isEnabled }) {
            return true
        }
        return displays.contains(where: { $0.isBuiltIn && $0.isOnline })
    }

    /// Normalizes any rotation angle to `0/90/180/270`, or `nil` if it is not a multiple of 90°.
    public static func normalizedRotation(_ rotation: Int) -> Int? {
        let value = ((rotation % 360) + 360) % 360
        return [0, 90, 180, 270].contains(value) ? value : nil
    }

    /// Origins that place `target` at `(0, 0)` while preserving the relative arrangement.
    public static func reorigin(bounds: [CGDirectDisplayID: CGRect], target: CGDirectDisplayID) -> [CGDirectDisplayID: CGPoint]? {
        guard let targetOrigin = bounds[target]?.origin else { return nil }
        return bounds.mapValues { CGPoint(x: $0.origin.x - targetOrigin.x, y: $0.origin.y - targetOrigin.y) }
    }

    /// Deduplicates and sorts modes (largest first, HiDPI before non-HiDPI at equal size, highest refresh first).
    public static func deduplicatedModes(_ modes: [DisplayModeInfo]) -> [DisplayModeInfo] {
        var seen = Set<String>()
        var result: [DisplayModeInfo] = []
        for mode in modes {
            let key = modeKey(mode)
            if seen.insert(key).inserted { result.append(mode) }
        }
        return result.sorted { a, b in
            if a.width != b.width { return a.width > b.width }
            if a.height != b.height { return a.height > b.height }
            if a.isHiDPI != b.isHiDPI { return a.isHiDPI }
            if a.pixelWidth != b.pixelWidth { return a.pixelWidth > b.pixelWidth }
            return a.refreshRate > b.refreshRate
        }
    }

    static func modeKey(_ mode: DisplayModeInfo) -> String {
        "\(mode.width)x\(mode.height)_\(mode.pixelWidth)x\(mode.pixelHeight)_\(Int((mode.refreshRate * 100).rounded()))"
    }

    // MARK: - DisplayBackendProtocol: queries

    public func getOnlineDisplays() -> [DisplayInfo] {
        let online = Self.onlineDisplayIDs()
        let active = Set(Self.activeDisplayIDs())
        let onlineSet = Set(online)
        var ids: [CGDirectDisplayID] = []
        for id in online + Array(active) where !ids.contains(id) { ids.append(id) }
        // Soft-disconnected Built-in Display (no longer in the online list, or temporarily dropped
        // from WindowServer's client table during headless `kCGSDisplayMovedOffConsoleInternal`).
        let builtIn = builtInDisplayID()
        if let builtIn, !ids.contains(builtIn) { ids.append(builtIn) }

        let lidClosed = Self.isLidClosed()
        var result = ids.map { makeDisplayInfo(id: $0, builtInID: builtIn, onlineSet: onlineSet, activeSet: active, lidClosed: lidClosed) }

        // Reconcile user-soft-disabled external displays:
        // - If an external display came back online & active (re-enabled or cable re-plugged), stop tracking it.
        // - Otherwise keep surfacing it as `isEnabled = false` so the user can toggle it back ON.
        stateLock.lock()
        for id in Array(softDisabledExternals.keys) {
            if onlineSet.contains(id) && (active.contains(id) || Self.isCGTrue(CGDisplayIsActive(id))) {
                softDisabledExternals.removeValue(forKey: id)
            }
        }
        let disabledSnapshots = Array(softDisabledExternals.values)
        stateLock.unlock()

        for snapshot in disabledSnapshots where !result.contains(where: { $0.id == snapshot.id }) {
            result.append(snapshot)
        }
        return result
    }

    private func makeDisplayInfo(
        id: CGDirectDisplayID,
        builtInID: CGDirectDisplayID?,
        onlineSet: Set<CGDirectDisplayID>,
        activeSet: Set<CGDirectDisplayID>,
        lidClosed: Bool
    ) -> DisplayInfo {
        let isBuiltIn = (builtInID == id) || Self.isCGTrue(CGDisplayIsBuiltin(id))
        let isVirtual = !isBuiltIn && isVirtualDisplay(displayID: id)
        let isActive = activeSet.contains(id) || Self.isCGTrue(CGDisplayIsActive(id))
        let mirrorMaster = Self.validMirrorMaster(rawValue: CGDisplayMirrorsDisplay(id))
        let inMirrorSet = Self.isCGTrue(CGDisplayIsInMirrorSet(id))
        let isEnabled = isActive || (onlineSet.contains(id) && mirrorMaster != nil)
        // A soft-disconnected Built-in panel is still physically present (online) unless the lid is closed.
        let isOnline = onlineSet.contains(id) || (isBuiltIn && !lidClosed)

        let (modes, current) = isEnabled ? Self.enumerateModes(displayID: id) : ([], nil)
        let supportsHDR = !isBuiltIn && !isVirtual && isEnabled && coreDisplay.supportsHDR(displayID: id)

        return DisplayInfo(
            id: id,
            identifier: DisplayIdentifier(displayID: id),
            name: displayName(for: id, isBuiltIn: isBuiltIn),
            isBuiltIn: isBuiltIn,
            isVirtual: isVirtual,
            isMain: Self.isCGTrue(CGDisplayIsMain(id)),
            isOnline: isOnline,
            isEnabled: isEnabled,
            isMirrored: inMirrorSet,
            mirrorMasterID: mirrorMaster,
            rotation: isEnabled ? Int(CGDisplayRotation(id).rounded()) : 0,
            supportsHDR: supportsHDR,
            isHDREnabled: supportsHDR && coreDisplay.isHDREnabled(displayID: id),
            currentMode: current,
            availableModes: modes,
            supportsDDC: !isBuiltIn && !isVirtual && isEnabled && ddcAvailability(id),
            supportsRotation: isEnabled && !isVirtual && supportsRotation(displayID: id)
        )
    }

    private func displayName(for id: CGDirectDisplayID, isBuiltIn: Bool) -> String {
        if Thread.isMainThread, let screen = CoreDisplayBridge.screen(for: id) {
            return screen.localizedName
        }
        if isBuiltIn { return "Built-in Display" }
        if let name = coreDisplay.productName(displayID: id), !name.isEmpty { return name }
        return "Display \(id)"
    }

    private func supportsRotation(displayID: CGDirectDisplayID) -> Bool {
        if let can = MonitorPanelBridge.shared.canChangeOrientation(displayID: displayID) { return can }
        guard let framebuffer = IOFramebufferRotation.framebuffer(for: displayID) else { return false }
        IOObjectRelease(framebuffer)
        return true
    }

    /// Enumerates usable desktop modes including duplicate low-resolution (HiDPI) modes.
    static func enumerateModes(displayID: CGDirectDisplayID) -> (modes: [DisplayModeInfo], current: DisplayModeInfo?) {
        let cgModes = copyAllModes(displayID: displayID)
        var infos: [DisplayModeInfo] = []
        for (index, mode) in cgModes.enumerated() where mode.isUsableForDesktopGUI() {
            infos.append(makeModeInfo(mode, index: index))
        }
        let modes = deduplicatedModes(infos)

        var current: DisplayModeInfo?
        if let currentMode = CGDisplayCopyDisplayMode(displayID) {
            let currentIndex = cgModes.firstIndex { $0.ioDisplayModeID == currentMode.ioDisplayModeID &&
                $0.width == currentMode.width && $0.pixelWidth == currentMode.pixelWidth } ?? -1
            let info = makeModeInfo(currentMode, index: currentIndex)
            current = modes.first { modeKey($0) == modeKey(info) } ?? info
        }
        return (modes, current)
    }

    static func copyAllModes(displayID: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode]) ?? []
    }

    static func makeModeInfo(_ mode: CGDisplayMode, index: Int) -> DisplayModeInfo {
        let isHiDPI = mode.pixelWidth > mode.width
        let refresh = mode.refreshRate
        let label: String? = refresh > 0 ? nil : "\(mode.width) × \(mode.height)\(isHiDPI ? " HiDPI" : "")"
        return DisplayModeInfo(
            width: mode.width,
            height: mode.height,
            pixelWidth: mode.pixelWidth,
            pixelHeight: mode.pixelHeight,
            refreshRate: refresh,
            isHiDPI: isHiDPI,
            modeIndex: index,
            displayLabel: label
        )
    }

    public func isBuiltInDisplayEnabled() -> Bool {
        // No built-in panel at all (desktop Mac) → nothing to restore.
        guard let id = builtInDisplayID() else { return true }
        // IMPORTANT: use `isCGTrue` (`== 1`), never `!= 0` — when WindowServer moves off-console
        // (`kCGSDisplayMovedOffConsoleInternal`), `CGDisplayIsActive(builtIn)` returns `-1`!
        if Self.activeDisplayIDs().contains(id) || Self.isCGTrue(CGDisplayIsActive(id)) { return true }
        return Self.isCGTrue(CGDisplayIsOnline(id)) && Self.isCGTrue(CGDisplayIsInMirrorSet(id))
    }

    public func isHDREnabled(displayID: CGDirectDisplayID) -> Bool {
        coreDisplay.isHDREnabled(displayID: displayID)
    }

    // MARK: - DisplayBackendProtocol: mutations

    public func setBuiltInDisplayEnabled(_ enabled: Bool) throws {
        configLock.lock()
        defer { configLock.unlock() }

        guard let builtIn = builtInDisplayID() else {
            throw DisplayError.displayNotFound(kCGNullDirectDisplay)
        }
        if !enabled {
            // Single-Display Guard.
            guard !activeExternalDisplayIDs().filter({ $0 != builtIn }).isEmpty else {
                throw DisplayError.singleDisplayGuardViolation
            }
        }
        if isBuiltInDisplayEnabled() == enabled { return }

        displayLogger.notice("Setting Built-in display \(builtIn, privacy: .public) enabled=\(enabled, privacy: .public)")
        do {
            try skyLight.setDisplayEnabled(builtIn, enabled: enabled)
        } catch {
            displayLogger.error("SLSConfigureDisplayEnabled(\(builtIn, privacy: .public), \(enabled, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            if enabled {
                // Fallback for headless off-console state (`kCGSDisplayMovedOffConsoleInternal`) where
                // WindowServer may reject a display-ID-targeted transaction: discard `.forSession` overrides.
                displayLogger.notice("Calling CGRestorePermanentDisplayConfiguration() fallback to recover Built-in display")
                CGRestorePermanentDisplayConfiguration()
                if isBuiltInDisplayEnabled() { return }
            }
            throw error
        }

        if enabled && !isBuiltInDisplayEnabled() {
            displayLogger.warning("Built-in display still inactive after SLSConfigureDisplayEnabled(true); calling CGRestorePermanentDisplayConfiguration()")
            CGRestorePermanentDisplayConfiguration()
        }
    }

    /// Enables or soft-disconnects any physical display (Built-in or external).
    ///
    /// When disabling the **last** active external display while Built-in is off (and lid is open),
    /// automatically re-enables the Built-in Display in the same transaction (with a safe two-step fallback)
    /// so macOS switches cleanly to Built-in with native scaling and never produces a black screen.
    public func setDisplayEnabled(displayID: CGDirectDisplayID, enabled: Bool) throws {
        if let builtIn = builtInDisplayID(), displayID == builtIn {
            try setBuiltInDisplayEnabled(enabled)
            return
        }

        configLock.lock()
        defer { configLock.unlock() }

        guard !isVirtualDisplay(displayID: displayID) else {
            throw DisplayError.unsupportedOperation("Virtual displays cannot be toggled.")
        }

        if enabled {
            stateLock.lock()
            let wasTrackedDisabled = softDisabledExternals.removeValue(forKey: displayID) != nil
            stateLock.unlock()

            if Self.activeDisplayIDs().contains(displayID) || Self.isCGTrue(CGDisplayIsActive(displayID)) {
                return
            }
            displayLogger.notice("Re-enabling external display \(displayID, privacy: .public) (wasTrackedDisabled=\(wasTrackedDisabled, privacy: .public))")
            try skyLight.setDisplayEnabled(displayID, enabled: true)
            return
        }

        // Disabling an external display:
        let currentDisplays = getOnlineDisplays()
        guard let target = currentDisplays.first(where: { $0.id == displayID && !$0.isBuiltIn && !$0.isVirtual }) else {
            throw DisplayError.displayNotFound(displayID)
        }
        if !target.isEnabled { return }

        let otherActiveExternals = activeExternalDisplayIDs().filter { $0 != displayID }
        let builtIn = builtInDisplayID()
        let builtInOn = builtIn != nil && isBuiltInDisplayEnabled()
        let needAutoSwitchToBuiltIn = !builtInOn && otherActiveExternals.isEmpty

        if needAutoSwitchToBuiltIn {
            guard let builtIn, !Self.isLidClosed() else {
                throw DisplayError.singleDisplayGuardViolation
            }
            displayLogger.notice("Disabling last active external display \(displayID, privacy: .public) — auto-switching Built-in display \(builtIn, privacy: .public) ON")
            do {
                try SkyLightBridge.performTransaction { config in
                    try self.skyLight.configureDisplayEnabled(config: config, displayID: builtIn, enabled: true)
                    try self.skyLight.configureDisplayEnabled(config: config, displayID: displayID, enabled: false)
                }
            } catch {
                // Safe two-step fallback: bring Built-in ON first, verify it's active, THEN disable external.
                displayLogger.warning("Atomic swap Built-in ON / external \(displayID, privacy: .public) OFF failed (\(error.localizedDescription, privacy: .public)); falling back to two-step switch")
                try setBuiltInDisplayEnabled(true)
                guard isBuiltInDisplayEnabled() else {
                    throw DisplayError.singleDisplayGuardViolation
                }
                try skyLight.setDisplayEnabled(displayID, enabled: false)
            }
            // Safety check: guarantee Built-in actually came up.
            if !isBuiltInDisplayEnabled() {
                displayLogger.error("Built-in still inactive after external swap; restoring Built-in immediately")
                try? setBuiltInDisplayEnabled(true)
            }
        } else {
            displayLogger.notice("Soft-disconnecting external display \(displayID, privacy: .public)")
            try skyLight.setDisplayEnabled(displayID, enabled: false)
        }

        let disabledSnapshot = DisplayInfo(
            id: target.id,
            identifier: target.identifier,
            name: target.name,
            isBuiltIn: false,
            isVirtual: false,
            isMain: false,
            isOnline: true,
            isEnabled: false,
            isMirrored: false,
            mirrorMasterID: nil,
            rotation: target.rotation,
            supportsHDR: false,
            isHDREnabled: false,
            currentMode: nil,
            availableModes: [],
            supportsDDC: false,
            supportsRotation: false
        )
        stateLock.lock()
        softDisabledExternals[displayID] = disabledSnapshot
        stateLock.unlock()
    }

    /// Re-enables any external displays that were soft-disconnected by the user (used on app quit).
    public func restoreSoftDisabledExternalDisplays() {
        configLock.lock()
        defer { configLock.unlock() }

        stateLock.lock()
        let ids = Array(softDisabledExternals.keys)
        softDisabledExternals.removeAll()
        stateLock.unlock()

        for id in ids {
            displayLogger.notice("Restoring soft-disabled external display \(id, privacy: .public) on teardown")
            try? skyLight.setDisplayEnabled(id, enabled: true)
        }
    }

    public func setDisplayMode(displayID: CGDirectDisplayID, mode: DisplayModeInfo) throws {
        configLock.lock()
        defer { configLock.unlock() }

        guard Self.isCGTrue(CGDisplayIsOnline(displayID)), Self.isCGTrue(CGDisplayIsActive(displayID)) else {
            throw DisplayError.displayNotFound(displayID)
        }
        let cgModes = Self.copyAllModes(displayID: displayID)
        func matches(_ m: CGDisplayMode) -> Bool {
            m.width == mode.width && m.height == mode.height &&
                m.pixelWidth == mode.pixelWidth && m.pixelHeight == mode.pixelHeight &&
                abs(m.refreshRate - mode.refreshRate) < 0.5
        }
        var target: CGDisplayMode?
        if mode.modeIndex >= 0, mode.modeIndex < cgModes.count, matches(cgModes[mode.modeIndex]) {
            target = cgModes[mode.modeIndex]
        }
        if target == nil {
            target = cgModes.first { matches($0) && $0.isUsableForDesktopGUI() } ?? cgModes.first(where: matches)
        }
        guard let target else {
            throw DisplayError.modeSwitchFailed("Mode \(mode.displayLabel) is not available on display \(displayID).")
        }
        if let current = CGDisplayCopyDisplayMode(displayID), current.ioDisplayModeID == target.ioDisplayModeID,
           current.width == target.width, current.pixelWidth == target.pixelWidth {
            return
        }
        try SkyLightBridge.performTransaction { config in
            let err = CGConfigureDisplayWithDisplayMode(config, displayID, target, nil)
            guard err == .success else { throw DisplayError.modeSwitchFailed("CGConfigureDisplayWithDisplayMode error \(err.rawValue)") }
        }
    }

    public func setMainDisplay(displayID: CGDirectDisplayID) throws {
        configLock.lock()
        defer { configLock.unlock() }

        let active = Self.activeDisplayIDs()
        guard active.contains(displayID) else { throw DisplayError.displayNotFound(displayID) }
        if Self.isCGTrue(CGDisplayIsMain(displayID)) { return }

        // Only re-origin displays that are not hardware mirrors of another display.
        var bounds: [CGDirectDisplayID: CGRect] = [:]
        for id in active where Self.validMirrorMaster(rawValue: CGDisplayMirrorsDisplay(id)) == nil {
            bounds[id] = CGDisplayBounds(id)
        }
        guard let origins = Self.reorigin(bounds: bounds, target: displayID) else {
            throw DisplayError.displayNotFound(displayID)
        }
        try SkyLightBridge.performTransaction { config in
            for (id, origin) in origins {
                let err = CGConfigureDisplayOrigin(config, id, Int32(origin.x.rounded()), Int32(origin.y.rounded()))
                guard err == .success else { throw DisplayError.configurationFailed(err.rawValue) }
            }
        }
    }

    public func setDisplayMirror(displayID: CGDirectDisplayID, mirrorOf: CGDirectDisplayID?) throws {
        configLock.lock()
        defer { configLock.unlock() }

        guard Self.isCGTrue(CGDisplayIsOnline(displayID)) else { throw DisplayError.displayNotFound(displayID) }
        if let master = mirrorOf {
            guard master != displayID else {
                throw DisplayError.unsupportedOperation("A display cannot mirror itself.")
            }
            guard Self.isCGTrue(CGDisplayIsOnline(master)), Self.isCGTrue(CGDisplayIsActive(master)) else {
                throw DisplayError.displayNotFound(master)
            }
            if Self.validMirrorMaster(rawValue: CGDisplayMirrorsDisplay(displayID)) == master { return }
        } else if Self.validMirrorMaster(rawValue: CGDisplayMirrorsDisplay(displayID)) == nil {
            return
        }
        try SkyLightBridge.performTransaction { config in
            let err = CGConfigureDisplayMirrorOfDisplay(config, displayID, mirrorOf ?? kCGNullDirectDisplay)
            guard err == .success else { throw DisplayError.configurationFailed(err.rawValue) }
        }
    }

    public func setDisplayRotation(displayID: CGDirectDisplayID, rotation: Int) throws {
        configLock.lock()
        defer { configLock.unlock() }

        guard let degrees = Self.normalizedRotation(rotation) else {
            throw DisplayError.unsupportedOperation("Rotation must be 0°, 90°, 180° or 270° (got \(rotation)°).")
        }
        guard Self.isCGTrue(CGDisplayIsOnline(displayID)), Self.isCGTrue(CGDisplayIsActive(displayID)) else {
            throw DisplayError.displayNotFound(displayID)
        }
        if Int(CGDisplayRotation(displayID).rounded()) == degrees { return }

        let monitorPanel = MonitorPanelBridge.shared
        if monitorPanel.canChangeOrientation(displayID: displayID) == true,
           monitorPanel.setOrientation(displayID: displayID, degrees: degrees) {
            return
        }
        if IOFramebufferRotation.setRotation(displayID: displayID, degrees: degrees) {
            return
        }
        throw DisplayError.unsupportedOperation("Rotation is not supported for display \(displayID).")
    }

    public func setHDREnabled(displayID: CGDirectDisplayID, enabled: Bool) throws {
        configLock.lock()
        defer { configLock.unlock() }
        try coreDisplay.setHDREnabled(displayID: displayID, enabled: enabled)
    }

    public func emergencyRestoreAllDisplays() throws {
        configLock.lock()
        defer { configLock.unlock() }

        var ids = Self.onlineDisplayIDs()
        let builtIn = builtInDisplayID()
        if let builtIn, !ids.contains(builtIn) { ids.append(builtIn) }
        stateLock.lock()
        let softDisabledIDs = Array(softDisabledExternals.keys)
        softDisabledExternals.removeAll()
        stateLock.unlock()
        for id in softDisabledIDs where !ids.contains(id) { ids.append(id) }
        let active = Set(Self.activeDisplayIDs())

        let needsEnable = ids.filter {
            !active.contains($0) && !Self.isCGTrue(CGDisplayIsActive($0)) &&
                Self.validMirrorMaster(rawValue: CGDisplayMirrorsDisplay($0)) == nil
        }
        let needsUnmirror = ids.filter { Self.validMirrorMaster(rawValue: CGDisplayMirrorsDisplay($0)) != nil }
        if needsEnable.isEmpty && needsUnmirror.isEmpty && isBuiltInDisplayEnabled() { return }

        displayLogger.notice("Emergency restore starting: needsEnable=\(needsEnable, privacy: .public) needsUnmirror=\(needsUnmirror, privacy: .public)")

        var transactionError: Error?
        if !needsEnable.isEmpty || !needsUnmirror.isEmpty {
            do {
                try SkyLightBridge.performTransaction { config in
                    for id in needsUnmirror {
                        _ = CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay)
                    }
                    if skyLight.canConfigureDisplayEnabled {
                        for id in needsEnable {
                            try? skyLight.configureDisplayEnabled(config: config, displayID: id, enabled: true)
                        }
                    }
                }
            } catch {
                transactionError = error
                displayLogger.error("Emergency restore transaction failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Last lines of defense: enable Built-in directly, then discard all `.forSession` overrides.
        if let builtIn, !isBuiltInDisplayEnabled() {
            try? skyLight.setDisplayEnabled(builtIn, enabled: true)
        }
        if let builtIn, !isBuiltInDisplayEnabled() {
            displayLogger.notice("Built-in \(builtIn, privacy: .public) still dark after transaction; calling CGRestorePermanentDisplayConfiguration()")
            CGRestorePermanentDisplayConfiguration()
        }
        if isBuiltInDisplayEnabled() { return }

        if !needsEnable.isEmpty && !skyLight.canConfigureDisplayEnabled {
            throw DisplayError.privateAPISymbolNotFound("SLSConfigureDisplayEnabled / CGSConfigureDisplayEnabled")
        }
        if let transactionError { throw transactionError }
    }

    // MARK: - Built-in brightness

    /// Sets Built-in Display brightness (`0.0 ... 1.0`) through `DisplayServices`.
    @discardableResult
    public func setBuiltInBrightness(_ value: Double) -> Bool {
        guard let id = builtInDisplayID(), Self.isCGTrue(CGDisplayIsActive(id)) else { return false }
        return skyLight.setBrightness(displayID: id, value: value)
    }

    /// Built-in Display brightness (`0.0 ... 1.0`), or `nil` if unavailable / soft-disconnected.
    public func getBuiltInBrightness() -> Double? {
        guard let id = builtInDisplayID(), Self.isCGTrue(CGDisplayIsActive(id)) else { return nil }
        return skyLight.getBrightness(displayID: id)
    }

    // MARK: - Hit testing

    /// Display containing `point` in **CoreGraphics global coordinates** (top-left origin).
    public func displayID(at point: CGPoint) -> CGDirectDisplayID? {
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &id, &count) == .success, count > 0 else { return nil }
        return id
    }

    /// Display currently under the mouse cursor.
    public func displayIDUnderMouseCursor() -> CGDirectDisplayID? {
        guard let location = CGEvent(source: nil)?.location else { return CGMainDisplayID() }
        return displayID(at: location) ?? CGMainDisplayID()
    }

    // MARK: - Reconfiguration observer

    /// Registers a `CGDisplayRegisterReconfigurationCallback`; `handler` is invoked on the main queue once
    /// per burst of reconfiguration callbacks (coalesced within one run-loop pass). Replaces any previous handler.
    public func startReconfigurationObserver(_ handler: @escaping @Sendable () -> Void) {
        stateLock.lock()
        reconfigurationHandler = handler
        let alreadyObserving = isObservingReconfiguration
        isObservingReconfiguration = true
        stateLock.unlock()

        guard !alreadyObserving else { return }
        CGDisplayRegisterReconfigurationCallback(DisplayManager.reconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
    }

    public func stopReconfigurationObserver() {
        stateLock.lock()
        let wasObserving = isObservingReconfiguration
        isObservingReconfiguration = false
        reconfigurationHandler = nil
        stateLock.unlock()

        guard wasObserving else { return }
        CGDisplayRemoveReconfigurationCallback(DisplayManager.reconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
    }

    private static let reconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
        guard let userInfo, !flags.contains(.beginConfigurationFlag) else { return }
        let manager = Unmanaged<DisplayManager>.fromOpaque(userInfo).takeUnretainedValue()
        manager.handleReconfiguration()
    }

    private func handleReconfiguration() {
        IOAVServiceBridge.shared.invalidateCache()

        stateLock.lock()
        guard isObservingReconfiguration, !reconfigurationDispatchPending else {
            stateLock.unlock()
            return
        }
        reconfigurationDispatchPending = true
        stateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            self.reconfigurationDispatchPending = false
            let handler = self.isObservingReconfiguration ? self.reconfigurationHandler : nil
            self.stateLock.unlock()
            handler?()
        }
    }
}

// MARK: - IOFramebufferRotation

/// Legacy `IOFramebuffer` rotation fallback (`IOServiceRequestProbe(kIOFBSetTransform)`), used only when
/// `MonitorPanel` cannot rotate. Apple Silicon has no `IOFramebuffer` services, so this normally reports
/// unsupported there.
enum IOFramebufferRotation {
    static let kIOFBSetTransform: UInt32 = 0x0000_0400
    static let kIOScaleSwapAxes: UInt32 = 0x1
    static let kIOScaleInvertX: UInt32 = 0x2
    static let kIOScaleInvertY: UInt32 = 0x4

    static func transform(for degrees: Int) -> UInt32? {
        switch degrees {
        case 0: return 0
        case 90: return kIOScaleSwapAxes | kIOScaleInvertX
        case 180: return kIOScaleInvertX | kIOScaleInvertY
        case 270: return kIOScaleSwapAxes | kIOScaleInvertY
        default: return nil
        }
    }

    /// Finds the `IOFramebuffer` whose `IODisplayConnect` child reports the display's vendor/product IDs.
    static func framebuffer(for displayID: CGDirectDisplayID) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        var matches: [io_service_t] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            guard let info = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName))?
                .takeRetainedValue() as? [String: Any] else { continue }
            let v = (info[kDisplayVendorID] as? NSNumber)?.uint32Value
            let p = (info[kDisplayProductID] as? NSNumber)?.uint32Value
            guard v == vendor, p == model else { continue }
            var parent: io_registry_entry_t = 0
            if IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 {
                matches.append(parent)
            }
        }
        guard matches.count == 1 else {
            matches.forEach { IOObjectRelease($0) }
            return nil
        }
        return matches[0]
    }

    static func setRotation(displayID: CGDirectDisplayID, degrees: Int) -> Bool {
        guard let code = transform(for: degrees), let framebuffer = framebuffer(for: displayID) else { return false }
        defer { IOObjectRelease(framebuffer) }
        return IOServiceRequestProbe(framebuffer, kIOFBSetTransform | (code << 16)) == KERN_SUCCESS
    }
}
