import CoreGraphics
import Foundation

/// Result of `CombinedBrightnessController.calculateCurve`.
public typealias BrightnessCurveResult = (ddcValue: UInt16?, overlayDimming: Double, method: BrightnessMethod)

/// Coordinates DDC hardware brightness with the software dimming overlay ("Combined Brightness").
@MainActor
public final class CombinedBrightnessController {
    public nonisolated static let defaultKneePoint: Double = 0.20
    /// Max overlay dimming used below the knee in DDC mode.
    public nonisolated static let kneeMaxDimming: Double = 0.75
    /// Max overlay dimming used in pure software mode (HDR / no DDC).
    public nonisolated static let softwareMaxDimming: Double = 0.80

    private let displayBackend: DisplayBackendProtocol?
    private let ddcBackend: DDCBackendProtocol?
    private let overlay: OverlayBackendProtocol
    public var kneePoint: Double

    /// When true, DDC writes happen on a background serial queue (latest value wins) so key-repeat never
    /// blocks the main thread; failures fall back to the overlay asynchronously. Default false (synchronous).
    public var asyncDDCWrites: Bool

    /// Fired on the main actor when the active method changes outside a direct `applyBrightness` return
    /// (e.g. a DDC write fails asynchronously and the controller falls back to the software overlay).
    public var onMethodChange: ((CGDirectDisplayID, BrightnessMethod) -> Void)?

    private var levels: [CGDirectDisplayID: Double] = [:]
    private var methods: [CGDirectDisplayID: BrightnessMethod] = [:]
    private var ddcFailed: Set<CGDirectDisplayID> = []
    private var lastHDRState: [CGDirectDisplayID: Bool] = [:]

    private let ddcQueue = DispatchQueue(label: "com.piszeprogramy.openbetterdisplay.ddc-brightness", qos: .userInitiated)
    private let generationLock = NSLock()
    nonisolated(unsafe) private var generations: [CGDirectDisplayID: Int] = [:]

    public init(
        displayBackend: DisplayBackendProtocol? = nil,
        ddcBackend: DDCBackendProtocol?,
        overlay: OverlayBackendProtocol,
        kneePoint: Double = CombinedBrightnessController.defaultKneePoint,
        asyncDDCWrites: Bool = false
    ) {
        self.displayBackend = displayBackend
        self.ddcBackend = ddcBackend
        self.overlay = overlay
        self.kneePoint = kneePoint
        self.asyncDDCWrites = asyncDDCWrites
    }

    // MARK: - Pure curve

    public nonisolated static func calculateCurve(
        level: Double,
        isBuiltIn: Bool,
        isHDREnabled: Bool,
        supportsDDC: Bool,
        kneePoint: Double = 0.20
    ) -> BrightnessCurveResult {
        let l = level.isFinite ? min(max(level, 0), 1) : 0
        let knee = min(max(kneePoint, 0.01), 0.95)

        if isBuiltIn {
            return (nil, 0, .nativeBuiltIn)
        }
        if isHDREnabled {
            return (nil, (1.0 - l) * softwareMaxDimming, .softwareHDR)
        }
        if supportsDDC {
            if l >= knee {
                let ddc = (l - knee) / (1.0 - knee) * 100.0
                return (UInt16(min(max(ddc.rounded(), 0), 100)), 0, .ddc)
            } else {
                let dim = (knee - l) / knee * kneeMaxDimming
                return (0, min(max(dim, 0), kneeMaxDimming), .ddcWithDimming)
            }
        }
        return (nil, (1.0 - l) * softwareMaxDimming, .softwareFallback)
    }

    // MARK: - Live application

    /// Applies `level` (0...1) to a display and returns the method actually used.
    /// If a DDC write fails at runtime the controller seamlessly switches to the software overlay.
    /// Pass `builtInSetter` for the built-in panel (its presence marks the display as built-in).
    @discardableResult
    public func applyBrightness(
        _ level: Double,
        for displayID: CGDirectDisplayID,
        supportsDDC: Bool,
        isHDREnabled: Bool,
        builtInSetter: ((Double) -> Void)? = nil
    ) -> BrightnessMethod {
        let clamped = level.isFinite ? min(max(level, 0), 1) : 0
        levels[displayID] = clamped
        let isBuiltIn = builtInSetter != nil

        if let previous = lastHDRState[displayID], previous != isHDREnabled {
            ddcFailed.remove(displayID) // HDR transitions can change DDC availability; retry.
        }
        lastHDRState[displayID] = isHDREnabled

        if isBuiltIn {
            builtInSetter?(clamped)
            overlay.setDimmingLevel(displayID: displayID, level: 0)
            methods[displayID] = .nativeBuiltIn
            return .nativeBuiltIn
        }

        let effectiveDDC = supportsDDC && ddcBackend != nil && !ddcFailed.contains(displayID)
        let curve = CombinedBrightnessController.calculateCurve(
            level: clamped,
            isBuiltIn: false,
            isHDREnabled: isHDREnabled,
            supportsDDC: effectiveDDC,
            kneePoint: kneePoint
        )

        if let ddcValue = curve.ddcValue, let ddc = ddcBackend {
            if asyncDDCWrites {
                overlay.setDimmingLevel(displayID: displayID, level: curve.overlayDimming)
                methods[displayID] = curve.method
                dispatchAsyncDDC(ddc, displayID: displayID, value: ddcValue)
                return curve.method
            }
            if ddc.writeBrightness(displayID: displayID, value: ddcValue) {
                overlay.setDimmingLevel(displayID: displayID, level: curve.overlayDimming)
                methods[displayID] = curve.method
                return curve.method
            }
            return fallBackToSoftware(displayID: displayID, level: clamped)
        }

        overlay.setDimmingLevel(displayID: displayID, level: curve.overlayDimming)
        methods[displayID] = curve.method
        return curve.method
    }

    /// Convenience for `DisplayInfo`.
    @discardableResult
    public func applyBrightness(
        _ level: Double,
        for display: DisplayInfo,
        builtInSetter: ((Double) -> Void)? = nil
    ) -> BrightnessMethod {
        applyBrightness(
            level,
            for: display.id,
            supportsDDC: display.supportsDDC,
            isHDREnabled: display.isHDREnabled,
            builtInSetter: display.isBuiltIn ? (builtInSetter ?? { _ in }) : nil
        )
    }

    /// Adjusts brightness relative to the last known level (default 0.5 when unknown).
    @discardableResult
    public func stepBrightness(
        by delta: Double,
        for display: DisplayInfo,
        builtInSetter: ((Double) -> Void)? = nil
    ) -> (level: Double, method: BrightnessMethod) {
        let current = levels[display.id] ?? 0.5
        let next = min(max(current + delta, 0), 1)
        let method = applyBrightness(next, for: display, builtInSetter: builtInSetter)
        return (next, method)
    }

    public func level(for displayID: CGDirectDisplayID) -> Double? { levels[displayID] }
    public func method(for displayID: CGDirectDisplayID) -> BrightnessMethod? { methods[displayID] }
    public func hasDDCFailed(for displayID: CGDirectDisplayID) -> Bool { ddcFailed.contains(displayID) }

    /// Allows DDC to be retried (e.g. after re-plug).
    public func resetDDCFailure(for displayID: CGDirectDisplayID) {
        ddcFailed.remove(displayID)
    }

    /// Forgets a display (disconnect) and clears its overlay dimming.
    public func forget(displayID: CGDirectDisplayID) {
        levels.removeValue(forKey: displayID)
        methods.removeValue(forKey: displayID)
        ddcFailed.remove(displayID)
        lastHDRState.removeValue(forKey: displayID)
        overlay.setDimmingLevel(displayID: displayID, level: 0)
    }

    // MARK: - Internals

    private func fallBackToSoftware(displayID: CGDirectDisplayID, level: Double) -> BrightnessMethod {
        ddcFailed.insert(displayID)
        let curve = CombinedBrightnessController.calculateCurve(
            level: level, isBuiltIn: false, isHDREnabled: false, supportsDDC: false, kneePoint: kneePoint
        )
        overlay.setDimmingLevel(displayID: displayID, level: curve.overlayDimming)
        let changed = methods[displayID] != .softwareFallback
        methods[displayID] = .softwareFallback
        if changed { onMethodChange?(displayID, .softwareFallback) }
        return .softwareFallback
    }

    private nonisolated func isLatestGeneration(_ displayID: CGDirectDisplayID, _ generation: Int) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generations[displayID] == generation
    }

    private func dispatchAsyncDDC(_ ddc: DDCBackendProtocol, displayID: CGDirectDisplayID, value: UInt16) {
        generationLock.lock()
        let generation = (generations[displayID] ?? 0) + 1
        generations[displayID] = generation
        generationLock.unlock()

        ddcQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.isLatestGeneration(displayID, generation) else { return }

            let ok = ddc.writeBrightness(displayID: displayID, value: value)
            if !ok {
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    // Ignore stale failures if a newer write was issued meanwhile.
                    guard self.isLatestGeneration(displayID, generation), let level = self.levels[displayID] else { return }
                    _ = self.fallBackToSoftware(displayID: displayID, level: level)
                }
            }
        }
    }
}
