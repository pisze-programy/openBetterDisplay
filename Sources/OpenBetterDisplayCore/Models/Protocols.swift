import Cocoa
import CoreGraphics
import Foundation

// MARK: - DisplayError

public enum DisplayError: LocalizedError, Equatable, Sendable {
    case displayNotFound(CGDirectDisplayID)
    case singleDisplayGuardViolation
    case unsupportedOperation(String)
    case configurationFailed(Int32)
    case modeSwitchFailed(String)
    case privateAPISymbolNotFound(String)
    case ddcCommunicationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .displayNotFound(let id):
            return "Display with ID \(id) not found or offline."
        case .singleDisplayGuardViolation:
            return "Cannot disable the built-in display because no active external display is connected."
        case .unsupportedOperation(let reason):
            return "Operation unsupported: \(reason)"
        case .configurationFailed(let code):
            return "Display reconfiguration failed with CoreGraphics error code \(code)."
        case .modeSwitchFailed(let reason):
            return "Failed to set display mode: \(reason)"
        case .privateAPISymbolNotFound(let sym):
            return "Required private API symbol '\(sym)' could not be resolved."
        case .ddcCommunicationFailed(let detail):
            return "DDC/CI communication failed: \(detail)"
        }
    }
}

// MARK: - DisplayBackendProtocol

public protocol DisplayBackendProtocol: Sendable {
    func getOnlineDisplays() -> [DisplayInfo]
    func setBuiltInDisplayEnabled(_ enabled: Bool) throws
    func isBuiltInDisplayEnabled() -> Bool
    func setDisplayMode(displayID: CGDirectDisplayID, mode: DisplayModeInfo) throws
    func setMainDisplay(displayID: CGDirectDisplayID) throws
    func setDisplayMirror(displayID: CGDirectDisplayID, mirrorOf: CGDirectDisplayID?) throws
    func setDisplayRotation(displayID: CGDirectDisplayID, rotation: Int) throws
    func setHDREnabled(displayID: CGDirectDisplayID, enabled: Bool) throws
    func isHDREnabled(displayID: CGDirectDisplayID) -> Bool
    func emergencyRestoreAllDisplays() throws
}

// MARK: - DDCBackendProtocol

public protocol DDCBackendProtocol: Sendable {
    func probeCapabilities(displayID: CGDirectDisplayID) -> DDCCapabilityReport
    func readBrightness(displayID: CGDirectDisplayID) -> UInt16?
    func writeBrightness(displayID: CGDirectDisplayID, value: UInt16) -> Bool
    func readVolume(displayID: CGDirectDisplayID) -> UInt16?
    func writeVolume(displayID: CGDirectDisplayID, value: UInt16) -> Bool
    func readMute(displayID: CGDirectDisplayID) -> Bool?
    func writeMute(displayID: CGDirectDisplayID, muted: Bool) -> Bool
    func readInputSource(displayID: CGDirectDisplayID) -> DDCInputSource?
    func writeInputSource(displayID: CGDirectDisplayID, source: DDCInputSource) -> Bool
}

// MARK: - AudioBackendProtocol

public protocol AudioBackendProtocol: Sendable {
    func isMonitorDefaultOutputDevice(displayID: CGDirectDisplayID) -> Bool
    func defaultOutputDeviceName() -> String?
    func startObservingAudioOutputChanges(onChange: @escaping @Sendable () -> Void)
    func stopObservingAudioOutputChanges()
}

// MARK: - OverlayBackendProtocol

@MainActor
public protocol OverlayBackendProtocol: AnyObject {
    func setDimmingLevel(displayID: CGDirectDisplayID, level: Double)
    func setNightShiftWarmth(displayID: CGDirectDisplayID, warmth: Double)
    func removeAllOverlays()
}

// MARK: - NightShiftBackendProtocol

public protocol NightShiftBackendProtocol: Sendable {
    func isSupported(displayID: CGDirectDisplayID) -> Bool
    func isNativeNightShiftActive() -> Bool
    func setNativeNightShiftEnabled(_ enabled: Bool) -> Bool
    func setNativeNightShiftWarmth(_ warmth: Double) -> Bool
    func evaluateSchedule(config: NightShiftConfig, now: Date) -> (shouldBeActive: Bool, effectiveWarmth: Double)
}
