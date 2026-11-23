import CoreGraphics
import Foundation

/// Snapshot of the scheduler's last evaluation.
public struct NightShiftStatus: Equatable, Sendable {
    public var isActive: Bool
    public var effectiveWarmth: Double
    public var usedNative: Bool
    public var overlayDisplayIDs: [CGDirectDisplayID]
}

/// Hybrid Night Shift: native CoreBrightness where supported + warm overlay fallback elsewhere (external / HDR).
@MainActor
public final class NightShiftScheduler {
    public static let evaluationInterval: TimeInterval = 30
    public nonisolated static let fallbackTimeZoneIdentifier = "Europe/Warsaw"

    private let backend: NightShiftBackendProtocol
    private let overlay: OverlayBackendProtocol
    private let displayProvider: () -> [DisplayInfo]

    public private(set) var config: NightShiftConfig
    public private(set) var status = NightShiftStatus(isActive: false, effectiveWarmth: 0, usedNative: false, overlayDisplayIDs: [])
    public var onStatusChange: ((NightShiftStatus) -> Void)?
    /// Injectable clock for tests.
    public var now: () -> Date = { Date() }

    private var timer: Timer?
    private var weEnabledNative = false
    private var overlayTinted: Set<CGDirectDisplayID> = []

    public init(
        backend: NightShiftBackendProtocol,
        overlay: OverlayBackendProtocol,
        config: NightShiftConfig = NightShiftConfig(),
        displayProvider: @escaping () -> [DisplayInfo]
    ) {
        self.backend = backend
        self.overlay = overlay
        self.config = config
        self.displayProvider = displayProvider
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Lifecycle

    public var isRunning: Bool { timer != nil }

    /// Starts the 30-second periodic evaluation (and evaluates immediately).
    public func start() {
        guard timer == nil else { applyNow(); return }
        let t = Timer(timeInterval: NightShiftScheduler.evaluationInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.applyNow() }
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
        applyNow()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Replaces the config and re-evaluates immediately.
    public func update(config: NightShiftConfig) {
        self.config = config
        applyNow()
    }

    // MARK: - Pure schedule math

    public nonisolated static func resolveTimeZone(_ config: NightShiftConfig) -> TimeZone {
        TimeZone(identifier: config.timeZoneIdentifier ?? "")
            ?? TimeZone.current
    }

    /// Evaluates the schedule. `enabled` is the master switch; `scheduleEnabled == false` means always-on while enabled.
    public nonisolated static func evaluate(config: NightShiftConfig, now: Date) -> (shouldBeActive: Bool, effectiveWarmth: Double) {
        let warmth = config.warmth.isFinite ? min(max(config.warmth, 0), 1) : 0
        guard config.enabled else { return (false, 0) }
        guard config.scheduleEnabled else { return (true, warmth) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = resolveTimeZone(config)
        let comps = calendar.dateComponents([.hour, .minute, .second], from: now)
        let nowMin = Double(comps.hour ?? 0) * 60 + Double(comps.minute ?? 0) + Double(comps.second ?? 0) / 60

        let day = 1440.0
        let start = Double(min(max(config.startHour, 0), 23) * 60 + min(max(config.startMinute, 0), 59))
        let end = Double(min(max(config.endHour, 0), 23) * 60 + min(max(config.endMinute, 0), 59))

        var duration = end - start
        if duration <= 0 { duration += day }       // overnight (e.g. 18:00–05:00)
        if end == start { duration = day }          // degenerate: whole day

        var offset = nowMin - start
        if offset < 0 { offset += day }
        guard offset < duration else { return (false, 0) }

        let transition = min(Double(max(config.transitionMinutes, 0)), duration / 2)
        guard transition > 0 else { return (true, warmth) }
        let edgeDistance = min(offset, duration - offset)
        let factor = min(max(edgeDistance / transition, 0), 1)
        return (true, warmth * factor)
    }

    public func evaluate(now: Date? = nil) -> (shouldBeActive: Bool, effectiveWarmth: Double) {
        NightShiftScheduler.evaluate(config: config, now: now ?? self.now())
    }

    // MARK: - Application

    /// Evaluates the schedule at the current time and applies native + overlay tinting.
    @discardableResult
    public func applyNow() -> NightShiftStatus {
        let result = evaluate()
        let displays = displayProvider().filter { $0.isOnline && $0.isEnabled }
        var usedNative = false
        var overlayIDs: Set<CGDirectDisplayID> = []

        var nativeHandled = false
        for display in displays {
            let nativeCapable = backend.isSupported(displayID: display.id) && !display.isHDREnabled
            if nativeCapable {
                if !nativeHandled {
                    nativeHandled = applyNative(result)
                }
                if nativeHandled {
                    usedNative = true
                    continue
                }
            }
            // Software fallback: external displays, HDR, or native unsupported/failed.
            let hdrAllowed = !display.isHDREnabled || config.applySoftwareFallbackInHDR
            if result.shouldBeActive && hdrAllowed && result.effectiveWarmth > 0 {
                overlay.setNightShiftWarmth(displayID: display.id, warmth: result.effectiveWarmth)
                overlayIDs.insert(display.id)
            } else {
                overlay.setNightShiftWarmth(displayID: display.id, warmth: 0)
            }
        }

        // Clear tint on displays that were tinted before but no longer qualify / disappeared.
        for stale in overlayTinted.subtracting(overlayIDs) {
            overlay.setNightShiftWarmth(displayID: stale, warmth: 0)
        }
        overlayTinted = overlayIDs

        // If native isn't needed any more but we enabled it earlier, turn it off.
        if !nativeHandled && weEnabledNative {
            _ = backend.setNativeNightShiftEnabled(false)
            weEnabledNative = false
        }

        let newStatus = NightShiftStatus(
            isActive: result.shouldBeActive,
            effectiveWarmth: result.effectiveWarmth,
            usedNative: result.shouldBeActive && usedNative,
            overlayDisplayIDs: overlayIDs.sorted()
        )
        if newStatus != status {
            status = newStatus
            onStatusChange?(newStatus)
        } else {
            status = newStatus
        }
        return newStatus
    }

    private func applyNative(_ result: (shouldBeActive: Bool, effectiveWarmth: Double)) -> Bool {
        if result.shouldBeActive && result.effectiveWarmth > 0 {
            let okWarmth = backend.setNativeNightShiftWarmth(result.effectiveWarmth)
            let okEnable = backend.setNativeNightShiftEnabled(true)
            if okEnable { weEnabledNative = true }
            return okWarmth || okEnable
        } else if weEnabledNative {
            // Only turn off what we turned on; never override the user's own system schedule.
            let ok = backend.setNativeNightShiftEnabled(false)
            if ok { weEnabledNative = false }
            return ok
        }
        return true
    }

    /// Removes all tinting we applied (emergency restore / quit).
    public func restoreNeutral() {
        stop()
        for id in overlayTinted { overlay.setNightShiftWarmth(displayID: id, warmth: 0) }
        for display in displayProvider() { overlay.setNightShiftWarmth(displayID: display.id, warmth: 0) }
        overlayTinted.removeAll()
        if weEnabledNative {
            _ = backend.setNativeNightShiftEnabled(false)
            weEnabledNative = false
        }
        status = NightShiftStatus(isActive: false, effectiveWarmth: 0, usedNative: false, overlayDisplayIDs: [])
        onStatusChange?(status)
    }

    /// Human-readable window, e.g. "18:00–05:00".
    public var scheduleDescription: String {
        String(format: "%02d:%02d–%02d:%02d", config.startHour, config.startMinute, config.endHour, config.endMinute)
    }
}
