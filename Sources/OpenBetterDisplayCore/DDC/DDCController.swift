import CoreGraphics
import Foundation

// MARK: - DDC VCP codes

public enum DDCVCPCode: UInt8, Sendable, CaseIterable {
    case luminance = 0x10
    case contrast = 0x12
    case inputSource = 0x60
    case audioSpeakerVolume = 0x62
    case audioMute = 0x8D
}

// MARK: - DDCTransport

/// Minimal I²C transport abstraction so `DDCController` can be unit tested with a fake transport
/// (no live hardware access in tests).
public protocol DDCTransport: Sendable {
    /// Whether DDC transport exists for the display.
    func isAvailable(displayID: CGDirectDisplayID) -> Bool
    func write(displayID: CGDirectDisplayID, bytes: [UInt8]) -> Bool
    func read(displayID: CGDirectDisplayID, length: Int) -> [UInt8]?
    /// Forget any cached state for the display (e.g. after a failed transfer or hotplug).
    func invalidate(displayID: CGDirectDisplayID)
}

/// Live transport backed by `IOAVServiceBridge`.
public struct IOAVServiceDDCTransport: DDCTransport {
    private let bridge: IOAVServiceBridge

    public init(bridge: IOAVServiceBridge = .shared) {
        self.bridge = bridge
    }

    public func isAvailable(displayID: CGDirectDisplayID) -> Bool {
        bridge.hasService(for: displayID)
    }

    public func write(displayID: CGDirectDisplayID, bytes: [UInt8]) -> Bool {
        guard let service = bridge.service(for: displayID) else { return false }
        return bridge.writeI2C(service: service, bytes: bytes)
    }

    public func read(displayID: CGDirectDisplayID, length: Int) -> [UInt8]? {
        guard let service = bridge.service(for: displayID) else { return nil }
        return bridge.readI2C(service: service, length: length)
    }

    public func invalidate(displayID: CGDirectDisplayID) {
        bridge.invalidateCache(displayID: displayID)
    }
}

// MARK: - DDCController

/// DDC/CI controller (`DDCBackendProtocol`) for Apple Silicon external displays.
///
/// - All transfers run on one serial queue (the I²C bus must never see interleaved transactions).
/// - Each read/write is retried up to `maxAttempts` (default 3) with a 15–40 ms back-off.
/// - Brightness and volume are normalized to `0 ... 100` using the VCP `maxValue` (guarding `maxValue == 0`).
/// - Calls are synchronous and can take ~50–250 ms: **never call from the main thread**.
public final class DDCController: DDCBackendProtocol, @unchecked Sendable {
    private let transport: DDCTransport
    private let queue = DispatchQueue(label: "com.piszeprogramy.openbetterdisplay.ddc", qos: .userInitiated)
    private let maxAttempts: Int
    private let replyDelay: TimeInterval
    private let retryDelayRange: ClosedRange<TimeInterval>

    /// Cache of VCP max values, keyed by display and VCP code (accessed only on `queue`).
    private var maxValueCache: [CGDirectDisplayID: [UInt8: UInt16]] = [:]

    /// - Parameters:
    ///   - transport: I²C transport (defaults to live `IOAVService`).
    ///   - maxAttempts: attempts per transfer (default 3).
    ///   - replyDelay: wait between a Get VCP request and reading the reply (default 40 ms).
    ///   - retryDelayRange: back-off between failed attempts (default 15–40 ms).
    public init(
        transport: DDCTransport = IOAVServiceDDCTransport(),
        maxAttempts: Int = 3,
        replyDelay: TimeInterval = 0.040,
        retryDelayRange: ClosedRange<TimeInterval> = 0.015...0.040
    ) {
        self.transport = transport
        self.maxAttempts = max(1, maxAttempts)
        self.replyDelay = max(0, replyDelay)
        self.retryDelayRange = retryDelayRange
    }

    /// Clears cached max values (call after hotplug).
    public func resetCache(displayID: CGDirectDisplayID? = nil) {
        queue.sync {
            if let displayID {
                maxValueCache.removeValue(forKey: displayID)
            } else {
                maxValueCache.removeAll()
            }
        }
    }

    // MARK: Raw VCP access

    /// Reads a VCP feature (current & max values). Returns `nil` after `maxAttempts` failures.
    public func readVCP(displayID: CGDirectDisplayID, code: UInt8) -> DDCReply? {
        guard CGDisplayIsBuiltin(displayID) != 1 else { return nil }
        return queue.sync { readVCPLocked(displayID: displayID, code: code) }
    }

    /// Writes a raw VCP feature value. Returns `false` after `maxAttempts` failures.
    ///
    /// - Warning: Sends DDC/CI writes to the physical monitor. Never call from tests against live hardware.
    @discardableResult
    public func writeVCP(displayID: CGDirectDisplayID, code: UInt8, value: UInt16) -> Bool {
        guard CGDisplayIsBuiltin(displayID) != 1 else { return false }
        return queue.sync { writeVCPLocked(displayID: displayID, code: code, value: value) }
    }

    private func readVCPLocked(displayID: CGDirectDisplayID, code: UInt8) -> DDCReply? {
        guard transport.isAvailable(displayID: displayID) else { return nil }
        let request = DDCPacket.makeDDCReadPacket(vcp: code)
        for attempt in 0..<maxAttempts {
            if attempt > 0 { backOff() }
            guard transport.write(displayID: displayID, bytes: request) else { continue }
            if replyDelay > 0 { Thread.sleep(forTimeInterval: replyDelay) }
            guard let bytes = transport.read(displayID: displayID, length: DDCPacket.replyLength),
                  let reply = DDCPacket.parseDDCReplyPacket(bytes, expectedVCP: code)
            else { continue }
            maxValueCache[displayID, default: [:]][code] = reply.maxValue
            return reply
        }
        return nil
    }

    private func writeVCPLocked(displayID: CGDirectDisplayID, code: UInt8, value: UInt16) -> Bool {
        guard transport.isAvailable(displayID: displayID) else { return false }
        let packet = DDCPacket.makeDDCWritePacket(vcp: code, value: value)
        for attempt in 0..<maxAttempts {
            if attempt > 0 { backOff() }
            if transport.write(displayID: displayID, bytes: packet) { return true }
        }
        transport.invalidate(displayID: displayID)
        return false
    }

    private func backOff() {
        let lower = max(0, retryDelayRange.lowerBound)
        let upper = max(lower, retryDelayRange.upperBound)
        let delay = upper > lower ? Double.random(in: lower...upper) : lower
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
    }

    /// Max value for a VCP code (cached; reads it if unknown). `maxValue == 0` is reported as 100.
    private func maxValueLocked(displayID: CGDirectDisplayID, code: UInt8) -> UInt16 {
        if let cached = maxValueCache[displayID]?[code], cached != 0 { return cached }
        if let reply = readVCPLocked(displayID: displayID, code: code), reply.maxValue != 0 { return reply.maxValue }
        return 100
    }

    private func readPercent(displayID: CGDirectDisplayID, code: UInt8) -> UInt16? {
        guard let reply = readVCP(displayID: displayID, code: code) else { return nil }
        return DDCPacket.normalize(raw: reply.currentValue, maxValue: reply.maxValue)
    }

    private func writePercent(displayID: CGDirectDisplayID, code: UInt8, percent: UInt16) -> Bool {
        guard CGDisplayIsBuiltin(displayID) != 1 else { return false }
        return queue.sync {
            let maxValue = maxValueLocked(displayID: displayID, code: code)
            let raw = DDCPacket.denormalize(percent: min(percent, 100), maxValue: maxValue)
            return writeVCPLocked(displayID: displayID, code: code, value: raw)
        }
    }

    // MARK: DDCBackendProtocol

    public func probeCapabilities(displayID: CGDirectDisplayID) -> DDCCapabilityReport {
        let name = CoreDisplayBridge.shared.productName(displayID: displayID) ?? "Display \(displayID)"
        guard CGDisplayIsBuiltin(displayID) != 1 else {
            return DDCCapabilityReport(displayID: displayID, displayName: name, hasIOAVService: false,
                                       probeError: "Built-in displays do not support DDC/CI.")
        }
        guard transport.isAvailable(displayID: displayID) else {
            return DDCCapabilityReport(displayID: displayID, displayName: name, hasIOAVService: false,
                                       probeError: "No IOAVService found for this display.")
        }
        let luminance = readVCP(displayID: displayID, code: DDCVCPCode.luminance.rawValue)
        let volume = readVCP(displayID: displayID, code: DDCVCPCode.audioSpeakerVolume.rawValue)
        let input = readVCP(displayID: displayID, code: DDCVCPCode.inputSource.rawValue)
        let anySuccess = luminance != nil || volume != nil || input != nil
        return DDCCapabilityReport(
            displayID: displayID,
            displayName: name,
            hasIOAVService: true,
            supportsLuminance: luminance != nil,
            currentLuminance: luminance.map { DDCPacket.normalize(raw: $0.currentValue, maxValue: $0.maxValue) },
            supportsVolume: volume != nil,
            currentVolume: volume.map { DDCPacket.normalize(raw: $0.currentValue, maxValue: $0.maxValue) },
            supportsInputSource: input != nil,
            currentInputSource: input.map { DDCInputSource(rawValue: Self.decodeInputSource($0.currentValue)) },
            probeError: anySuccess ? nil : "Display did not answer DDC/CI VCP requests (it may be locked, e.g. in HDR mode)."
        )
    }

    public func readBrightness(displayID: CGDirectDisplayID) -> UInt16? {
        readPercent(displayID: displayID, code: DDCVCPCode.luminance.rawValue)
    }

    public func writeBrightness(displayID: CGDirectDisplayID, value: UInt16) -> Bool {
        writePercent(displayID: displayID, code: DDCVCPCode.luminance.rawValue, percent: value)
    }

    public func readVolume(displayID: CGDirectDisplayID) -> UInt16? {
        readPercent(displayID: displayID, code: DDCVCPCode.audioSpeakerVolume.rawValue)
    }

    public func writeVolume(displayID: CGDirectDisplayID, value: UInt16) -> Bool {
        writePercent(displayID: displayID, code: DDCVCPCode.audioSpeakerVolume.rawValue, percent: value)
    }

    /// MCCS VCP 0x8D: `1` = muted, `2` = unmuted.
    public func readMute(displayID: CGDirectDisplayID) -> Bool? {
        guard let reply = readVCP(displayID: displayID, code: DDCVCPCode.audioMute.rawValue) else { return nil }
        return Self.decodeMute(reply.currentValue)
    }

    public func writeMute(displayID: CGDirectDisplayID, muted: Bool) -> Bool {
        writeVCP(displayID: displayID, code: DDCVCPCode.audioMute.rawValue, value: Self.encodeMute(muted))
    }

    public func readInputSource(displayID: CGDirectDisplayID) -> DDCInputSource? {
        guard let reply = readVCP(displayID: displayID, code: DDCVCPCode.inputSource.rawValue) else { return nil }
        return DDCInputSource(rawValue: Self.decodeInputSource(reply.currentValue))
    }

    public func writeInputSource(displayID: CGDirectDisplayID, source: DDCInputSource) -> Bool {
        writeVCP(displayID: displayID, code: DDCVCPCode.inputSource.rawValue, value: source.rawValue)
    }

    // MARK: Pure value codecs

    /// MCCS mute encoding: `1` = mute, `2` = unmute.
    public static func encodeMute(_ muted: Bool) -> UInt16 { muted ? 1 : 2 }

    /// MCCS mute decoding: only `1` means muted (`2`, and non-standard `0`, mean unmuted).
    public static func decodeMute(_ raw: UInt16) -> Bool { (raw & 0xFF) == 1 }

    /// Input source values live in the low byte; some monitors report them in the high byte instead.
    public static func decodeInputSource(_ raw: UInt16) -> UInt16 {
        let low = raw & 0x00FF
        return low != 0 ? low : (raw >> 8)
    }
}
