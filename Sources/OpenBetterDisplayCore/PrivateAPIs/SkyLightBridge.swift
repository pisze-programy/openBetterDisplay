import CoreGraphics
import Darwin
import Foundation

// MARK: - SkyLightBridge

/// Dynamically resolved bridge to private WindowServer (`SkyLight`) and `DisplayServices` symbols.
///
/// Every symbol is resolved lazily with `dlopen`/`dlsym`; a missing symbol never crashes the app,
/// it simply makes the corresponding capability report `false` / throw `privateAPISymbolNotFound`.
public final class SkyLightBridge: @unchecked Sendable {
    public static let shared = SkyLightBridge()

    // MARK: Paths

    static let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    static let coreGraphicsPath = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
    static let displayServicesPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"

    // MARK: C function signatures

    /// `CGError SLSConfigureDisplayEnabled(CGDisplayConfigRef config, CGDirectDisplayID display, bool enabled)`
    typealias ConfigureDisplayEnabledFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    /// `CGError SLSGetDisplayList(uint32_t max, CGDirectDisplayID *displays, uint32_t *count)`
    typealias GetDisplayListFn = @convention(c) (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError
    /// `int DisplayServicesGetBrightness(CGDirectDisplayID display, float *brightness)`
    typealias DSGetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    /// `int DisplayServicesSetBrightness(CGDirectDisplayID display, float brightness)`
    typealias DSSetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    /// `bool DisplayServicesCanChangeBrightness(CGDirectDisplayID display)`
    typealias DSCanChangeBrightnessFn = @convention(c) (CGDirectDisplayID) -> Bool

    // MARK: Resolved symbols

    private let configureDisplayEnabledFn: ConfigureDisplayEnabledFn?
    private let getDisplayListFn: GetDisplayListFn?
    private let dsGetBrightnessFn: DSGetBrightnessFn?
    private let dsSetBrightnessFn: DSSetBrightnessFn?
    private let dsCanChangeBrightnessFn: DSCanChangeBrightnessFn?

    /// Name of the symbol actually used for enabling/disabling displays (diagnostics).
    public let configureDisplayEnabledSymbolName: String?

    private init() {
        let skyLight = DynamicLibrary.open(SkyLightBridge.skyLightPath)
        let coreGraphics = DynamicLibrary.open(SkyLightBridge.coreGraphicsPath)
        let displayServices = DynamicLibrary.open(SkyLightBridge.displayServicesPath)

        if let sym = skyLight?.symbol("SLSConfigureDisplayEnabled") {
            configureDisplayEnabledFn = unsafeBitCast(sym, to: ConfigureDisplayEnabledFn.self)
            configureDisplayEnabledSymbolName = "SLSConfigureDisplayEnabled"
        } else if let sym = coreGraphics?.symbol("CGSConfigureDisplayEnabled") {
            configureDisplayEnabledFn = unsafeBitCast(sym, to: ConfigureDisplayEnabledFn.self)
            configureDisplayEnabledSymbolName = "CGSConfigureDisplayEnabled"
        } else {
            configureDisplayEnabledFn = nil
            configureDisplayEnabledSymbolName = nil
        }

        if let sym = skyLight?.symbol("SLSGetDisplayList") ?? coreGraphics?.symbol("CGSGetDisplayList") {
            getDisplayListFn = unsafeBitCast(sym, to: GetDisplayListFn.self)
        } else {
            getDisplayListFn = nil
        }

        dsGetBrightnessFn = displayServices?.symbol("DisplayServicesGetBrightness").map { unsafeBitCast($0, to: DSGetBrightnessFn.self) }
        dsSetBrightnessFn = displayServices?.symbol("DisplayServicesSetBrightness").map { unsafeBitCast($0, to: DSSetBrightnessFn.self) }
        dsCanChangeBrightnessFn = displayServices?.symbol("DisplayServicesCanChangeBrightness").map { unsafeBitCast($0, to: DSCanChangeBrightnessFn.self) }
    }

    // MARK: Capabilities

    public var canConfigureDisplayEnabled: Bool { configureDisplayEnabledFn != nil }
    public var canListAllDisplays: Bool { getDisplayListFn != nil }
    public var canControlBuiltInBrightness: Bool { dsGetBrightnessFn != nil && dsSetBrightnessFn != nil }

    // MARK: Display list

    /// Returns every display known to WindowServer, **including soft-disconnected displays** that no longer
    /// appear in `CGGetOnlineDisplayList` (e.g. a disabled Built-in Display). Empty slots (vendor 0 & model 0
    /// & not built-in) are filtered out. Returns `nil` if the private symbol is unavailable.
    public func allKnownDisplayIDs() -> [CGDirectDisplayID]? {
        guard let fn = getDisplayListFn else { return nil }
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        let err = ids.withUnsafeMutableBufferPointer { fn(UInt32($0.count), $0.baseAddress, &count) }
        guard err == .success else { return nil }
        return ids.prefix(Int(min(count, 32))).filter { id in
            id != kCGNullDirectDisplay &&
                (CGDisplayIsBuiltin(id) == 1 || CGDisplayVendorNumber(id) != 0 || CGDisplayModelNumber(id) != 0 || CGDisplayIsOnline(id) != 0)
        }
    }

    // MARK: Enable / disable

    /// Adds an enable/disable request to an already open configuration transaction.
    public func configureDisplayEnabled(config: CGDisplayConfigRef?, displayID: CGDirectDisplayID, enabled: Bool) throws {
        guard let fn = configureDisplayEnabledFn else {
            throw DisplayError.privateAPISymbolNotFound("SLSConfigureDisplayEnabled / CGSConfigureDisplayEnabled")
        }
        let err = fn(config, displayID, enabled)
        guard err == .success else { throw DisplayError.configurationFailed(err.rawValue) }
    }

    /// Enables or disables a display inside a full session-scoped transaction:
    /// `CGBeginDisplayConfiguration` → `SLSConfigureDisplayEnabled` → `CGCompleteDisplayConfiguration(.forSession)`.
    ///
    /// - Warning: Mutates the live display configuration. Never call from tests.
    public func setDisplayEnabled(_ displayID: CGDirectDisplayID, enabled: Bool) throws {
        try SkyLightBridge.performTransaction { config in
            try self.configureDisplayEnabled(config: config, displayID: displayID, enabled: enabled)
        }
    }

    /// Runs `body` inside a CoreGraphics display configuration transaction, completing with
    /// `.forSession` (so logout/reboot always restores a sane state) or cancelling on any thrown error.
    public static func performTransaction(
        option: CGConfigureOption = .forSession,
        _ body: (CGDisplayConfigRef?) throws -> Void
    ) throws {
        var config: CGDisplayConfigRef?
        let beginErr = CGBeginDisplayConfiguration(&config)
        guard beginErr == .success, let config else {
            throw DisplayError.configurationFailed(beginErr.rawValue)
        }
        do {
            try body(config)
        } catch {
            CGCancelDisplayConfiguration(config)
            throw error
        }
        let completeErr = CGCompleteDisplayConfiguration(config, option)
        guard completeErr == .success else {
            throw DisplayError.configurationFailed(completeErr.rawValue)
        }
    }

    // MARK: Built-in brightness (DisplayServices)

    public func canChangeBrightness(displayID: CGDirectDisplayID) -> Bool {
        guard let fn = dsCanChangeBrightnessFn else { return canControlBuiltInBrightness }
        return fn(displayID)
    }

    /// Returns brightness `0.0 ... 1.0` or `nil` if unavailable.
    public func getBrightness(displayID: CGDirectDisplayID) -> Double? {
        guard let fn = dsGetBrightnessFn else { return nil }
        var value: Float = 0
        guard fn(displayID, &value) == 0, value.isFinite else { return nil }
        return Double(min(max(value, 0), 1))
    }

    /// Sets brightness `0.0 ... 1.0`. Returns `false` if the symbol is missing or the call failed.
    @discardableResult
    public func setBrightness(displayID: CGDirectDisplayID, value: Double) -> Bool {
        guard let fn = dsSetBrightnessFn, value.isFinite else { return false }
        return fn(displayID, Float(min(max(value, 0), 1))) == 0
    }
}

// MARK: - DynamicLibrary

/// Tiny `dlopen` wrapper shared by the private API bridges. Handles are intentionally never closed
/// (system frameworks stay loaded for the lifetime of the process anyway).
struct DynamicLibrary: @unchecked Sendable {
    let path: String
    let handle: UnsafeMutableRawPointer

    static func open(_ path: String) -> DynamicLibrary? {
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else { return nil }
        return DynamicLibrary(path: path, handle: handle)
    }

    func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        dlsym(handle, name)
    }

    /// Looks a symbol up in the global namespace of the process (all loaded images).
    static func globalSymbol(_ name: String) -> UnsafeMutableRawPointer? {
        guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
        return dlsym(handle, name)
    }
}
