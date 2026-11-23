import CoreGraphics
import Foundation
import ObjectiveC

// MARK: - NativeNightShiftStatus

/// Decoded `CBBlueLightClient` status. Mirrors the C struct
/// `{ BOOL active; BOOL enabled; BOOL sunSchedulePermitted; int mode; {{int,int},{int,int}} schedule; uint64 disableFlags; BOOL available; }`
/// (ObjC type encoding `{?=BBBi{?={?=ii}{?=ii}}QB}`, 40 bytes on arm64).
public struct NativeNightShiftStatus: Equatable, Sendable {
    public let active: Bool
    public let enabled: Bool
    public let sunSchedulePermitted: Bool
    public let mode: Int32
    public let fromHour: Int32
    public let fromMinute: Int32
    public let toHour: Int32
    public let toMinute: Int32
    public let disableFlags: UInt64
    public let available: Bool

    /// Byte offsets of the C struct on arm64 (natural alignment).
    enum Offset {
        static let active = 0
        static let enabled = 1
        static let sunSchedulePermitted = 2
        static let mode = 4
        static let fromHour = 8
        static let fromMinute = 12
        static let toHour = 16
        static let toMinute = 20
        static let disableFlags = 24
        static let available = 32
        static let size = 40
    }

    /// Decodes the struct from a raw buffer (internal so it can be unit tested with synthetic bytes).
    init?(rawBuffer: UnsafeRawBufferPointer) {
        guard rawBuffer.count >= Offset.size else { return nil }
        func byte(_ offset: Int) -> Bool { rawBuffer[offset] != 0 }
        func int32(_ offset: Int) -> Int32 { rawBuffer.loadUnaligned(fromByteOffset: offset, as: Int32.self) }
        active = byte(Offset.active)
        enabled = byte(Offset.enabled)
        sunSchedulePermitted = byte(Offset.sunSchedulePermitted)
        mode = int32(Offset.mode)
        fromHour = int32(Offset.fromHour)
        fromMinute = int32(Offset.fromMinute)
        toHour = int32(Offset.toHour)
        toMinute = int32(Offset.toMinute)
        disableFlags = rawBuffer.loadUnaligned(fromByteOffset: Offset.disableFlags, as: UInt64.self)
        available = byte(Offset.available)
    }
}

// MARK: - CoreBrightnessBridge

/// Native macOS Night Shift control through the private `CoreBrightness.framework` (`CBBlueLightClient`),
/// plus the pure schedule evaluator used by the hybrid (native + warm overlay) Night Shift pipeline.
public final class CoreBrightnessBridge: NightShiftBackendProtocol, @unchecked Sendable {
    static let frameworkPath = "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"

    /// Reference fallback time zone from the specification.
    public static let fallbackTimeZone: TimeZone = TimeZone(identifier: "Europe/Warsaw") ?? .current

    private let lock = NSLock()
    private var client: NSObject?
    private let clientClass: NSObject.Type?

    public init() {
        _ = DynamicLibrary.open(CoreBrightnessBridge.frameworkPath)
        clientClass = NSClassFromString("CBBlueLightClient") as? NSObject.Type
    }

    // MARK: Client

    private func blueLightClient() -> NSObject? {
        lock.lock()
        defer { lock.unlock() }
        if let client { return client }
        guard let cls = clientClass else { return nil }
        let supportsSel = NSSelectorFromString("supportsBlueLightReduction")
        if cls.responds(to: supportsSel) {
            typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
            let fn = unsafeBitCast(cls.method(for: supportsSel), to: Fn.self)
            guard fn(cls, supportsSel) else { return nil }
        }
        let instance = cls.init()
        client = instance
        return instance
    }

    /// `true` when `CBBlueLightClient` exists and the hardware supports blue light reduction.
    public var isFrameworkAvailable: Bool { blueLightClient() != nil }

    /// Reads the current native Night Shift status, or `nil` if unavailable.
    public func nativeStatus() -> NativeNightShiftStatus? {
        guard let client = blueLightClient() else { return nil }
        let sel = NSSelectorFromString("getBlueLightStatus:")
        guard client.responds(to: sel) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
        let fn = unsafeBitCast(client.method(for: sel), to: Fn.self)
        // Over-allocate to stay safe if Apple ever appends fields to the struct.
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 128, alignment: 16)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 128)
        guard fn(client, sel, buffer) else { return nil }
        return NativeNightShiftStatus(rawBuffer: UnsafeRawBufferPointer(start: buffer, count: 128))
    }

    /// Current native strength `0.0 ... 1.0`, or `nil`.
    public func nativeStrength() -> Double? {
        guard let client = blueLightClient() else { return nil }
        let sel = NSSelectorFromString("getStrength:")
        guard client.responds(to: sel) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Float>) -> Bool
        var value: Float = 0
        guard unsafeBitCast(client.method(for: sel), to: Fn.self)(client, sel, &value), value.isFinite else { return nil }
        return Double(min(max(value, 0), 1))
    }

    // MARK: NightShiftBackendProtocol

    /// Native Night Shift is considered usable on a display when CoreBrightness is available and reports
    /// itself available, the display is online, and the display is **not** in HDR mode (where macOS
    /// suspends Night Shift — the warm overlay fallback must be used instead).
    public func isSupported(displayID: CGDirectDisplayID) -> Bool {
        guard CGDisplayIsOnline(displayID) != 0 || CGDisplayIsActive(displayID) != 0 else { return false }
        guard let status = nativeStatus(), status.available else { return false }
        if CoreDisplayBridge.shared.isHDREnabled(displayID: displayID) { return false }
        return true
    }

    public func isNativeNightShiftActive() -> Bool {
        guard let status = nativeStatus() else { return false }
        return status.active
    }

    public func setNativeNightShiftEnabled(_ enabled: Bool) -> Bool {
        guard let client = blueLightClient() else { return false }
        if let status = nativeStatus(), !status.available { return false }
        let sel = NSSelectorFromString("setEnabled:")
        guard client.responds(to: sel) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Bool
        return unsafeBitCast(client.method(for: sel), to: Fn.self)(client, sel, enabled)
    }

    public func setNativeNightShiftWarmth(_ warmth: Double) -> Bool {
        guard warmth.isFinite, let client = blueLightClient() else { return false }
        if let status = nativeStatus(), !status.available { return false }
        let sel = NSSelectorFromString("setStrength:commit:")
        guard client.responds(to: sel) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, Float, Bool) -> Bool
        let strength = Float(min(max(warmth, 0), 1))
        return unsafeBitCast(client.method(for: sel), to: Fn.self)(client, sel, strength, true)
    }

    public func evaluateSchedule(config: NightShiftConfig, now: Date) -> (shouldBeActive: Bool, effectiveWarmth: Double) {
        CoreBrightnessBridge.evaluateSchedule(config: config, now: now)
    }

    // MARK: Pure schedule math

    /// Resolves the schedule time zone: a valid `identifier` wins, otherwise the Mac's current time zone,
    /// and `Europe/Warsaw` only if the system time zone cannot be determined.
    public static func resolveTimeZone(_ identifier: String?) -> TimeZone {
        if let identifier, !identifier.isEmpty, let zone = TimeZone(identifier: identifier) {
            return zone
        }
        let current = TimeZone.current
        return current.identifier.isEmpty ? fallbackTimeZone : current
    }

    /// Pure, deterministic Night Shift schedule evaluation.
    ///
    /// Semantics:
    /// - `config.enabled == false` → master switch off: `(false, 0)`.
    /// - `config.enabled && !config.scheduleEnabled` → manual ON: `(true, warmth)`.
    /// - Scheduled: active inside `[start, end)` in the resolved time zone; windows that cross midnight
    ///   (e.g. `18:00–05:00`) are handled. `start == end` means "all day".
    /// - Gradual ramp: warmth ramps **in** linearly over the first `transitionMinutes` after `start` and
    ///   ramps **out** over the last `transitionMinutes` before `end` (each ramp is capped at half the window).
    public static func evaluateSchedule(config: NightShiftConfig, now: Date) -> (shouldBeActive: Bool, effectiveWarmth: Double) {
        guard config.enabled else { return (false, 0) }
        let warmth = config.warmth.isFinite ? min(max(config.warmth, 0), 1) : 0
        guard config.scheduleEnabled else { return (true, warmth) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = resolveTimeZone(config.timeZoneIdentifier)
        let comps = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: now)

        let daySeconds = 86_400.0
        let nowSeconds = Double(comps.hour ?? 0) * 3600 + Double(comps.minute ?? 0) * 60 +
            Double(comps.second ?? 0) + Double(comps.nanosecond ?? 0) / 1_000_000_000

        func seconds(hour: Int, minute: Int) -> Double {
            Double(min(max(hour, 0), 23)) * 3600 + Double(min(max(minute, 0), 59)) * 60
        }
        let start = seconds(hour: config.startHour, minute: config.startMinute)
        let end = seconds(hour: config.endHour, minute: config.endMinute)

        if start == end { return (true, warmth) }

        func wrap(_ value: Double) -> Double {
            let r = value.truncatingRemainder(dividingBy: daySeconds)
            return r < 0 ? r + daySeconds : r
        }
        let windowLength = wrap(end - start)
        let elapsed = wrap(nowSeconds - start)
        guard elapsed < windowLength else { return (false, 0) }

        let ramp = min(Double(max(config.transitionMinutes, 0)) * 60, windowLength / 2)
        guard ramp > 0 else { return (true, warmth) }

        let remaining = windowLength - elapsed
        let factor = min(1, elapsed / ramp, remaining / ramp)
        return (true, warmth * max(0, factor))
    }
}
