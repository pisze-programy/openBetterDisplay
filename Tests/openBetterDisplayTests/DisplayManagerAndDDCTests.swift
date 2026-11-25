import CoreAudio
import CoreGraphics
import Foundation
import XCTest
@testable import OpenBetterDisplayCore

// MARK: - Fake DDC transport (no I²C traffic)

/// Simulated monitor implementing just enough DDC/CI to exercise `DDCController`.
private final class FakeDDCTransport: DDCTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _available = true
    private var _writeFailuresRemaining = 0
    private var _readFailuresRemaining = 0
    private var _corruptReplies = false
    private var _registers: [UInt8: (current: UInt16, max: UInt16)] = [:]
    private var _lastRequestedVCP: UInt8?
    private var _writeAttempts = 0
    private var _readAttempts = 0
    private var _invalidations = 0
    private var _setCommands: [(vcp: UInt8, value: UInt16)] = []

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var available: Bool {
        get { locked { _available } }
        set { locked { _available = newValue } }
    }
    var writeFailuresRemaining: Int {
        get { locked { _writeFailuresRemaining } }
        set { locked { _writeFailuresRemaining = newValue } }
    }
    var readFailuresRemaining: Int {
        get { locked { _readFailuresRemaining } }
        set { locked { _readFailuresRemaining = newValue } }
    }
    var corruptReplies: Bool {
        get { locked { _corruptReplies } }
        set { locked { _corruptReplies = newValue } }
    }
    var writeAttempts: Int { locked { _writeAttempts } }
    var readAttempts: Int { locked { _readAttempts } }
    var invalidations: Int { locked { _invalidations } }
    var setCommands: [(vcp: UInt8, value: UInt16)] { locked { _setCommands } }

    func setRegister(_ vcp: UInt8, current: UInt16, max: UInt16) {
        locked { _registers[vcp] = (current, max) }
    }

    func register(_ vcp: UInt8) -> (current: UInt16, max: UInt16)? {
        locked { _registers[vcp] }
    }

    func isAvailable(displayID: CGDirectDisplayID) -> Bool { available }

    func write(displayID: CGDirectDisplayID, bytes: [UInt8]) -> Bool {
        locked {
            _writeAttempts += 1
            if _writeFailuresRemaining > 0 {
                _writeFailuresRemaining -= 1
                return false
            }
            guard bytes.count >= 4 else { return false }
            switch bytes[1] {
            case DDCPacket.opcodeSetVCP where bytes.count >= 6:
                let value = UInt16(bytes[3]) << 8 | UInt16(bytes[4])
                let max = _registers[bytes[2]]?.max ?? 100
                _registers[bytes[2]] = (value, max)
                _setCommands.append((bytes[2], value))
            case DDCPacket.opcodeGetVCP:
                _lastRequestedVCP = bytes[2]
            default:
                return false
            }
            return true
        }
    }

    func read(displayID: CGDirectDisplayID, length: Int) -> [UInt8]? {
        locked {
            _readAttempts += 1
            if _readFailuresRemaining > 0 {
                _readFailuresRemaining -= 1
                return nil
            }
            guard let vcp = _lastRequestedVCP else { return nil }
            var reply: [UInt8]
            if let reg = _registers[vcp] {
                reply = [0x6E, 0x88, 0x02, 0x00, vcp, 0x00, UInt8(reg.max >> 8), UInt8(reg.max & 0xFF), UInt8(reg.current >> 8), UInt8(reg.current & 0xFF)]
            } else {
                reply = [0x6E, 0x88, 0x02, 0x01, vcp, 0x00, 0, 0, 0, 0] // unsupported VCP
            }
            reply.append(DDCPacket.checksum(seed: DDCPacket.replyChecksumSeed, bytes: reply))
            if _corruptReplies { reply[reply.count - 1] ^= 0xFF }
            return Array(reply.prefix(length))
        }
    }

    func invalidate(displayID: CGDirectDisplayID) {
        locked { _invalidations += 1 }
    }
}

/// Fake external display ID (not built-in, unknown to CoreGraphics).
private let fakeDisplayID: CGDirectDisplayID = 0x0BAD_F00D

private func makeReply(vcp: UInt8, current: UInt16, max: UInt16, result: UInt8 = 0) -> [UInt8] {
    var reply: [UInt8] = [0x6E, 0x88, 0x02, result, vcp, 0x00, UInt8(max >> 8), UInt8(max & 0xFF), UInt8(current >> 8), UInt8(current & 0xFF)]
    reply.append(DDCPacket.checksum(seed: 0x50, bytes: reply))
    return reply
}

// MARK: - DDC packet framing

final class DDCPacketTests: XCTestCase {
    func testWritePacketFramingMatchesArm64DDC() {
        // 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x00 ^ 0x32 = 0x9A
        XCTAssertEqual(DDCPacket.makeDDCWritePacket(vcp: 0x10, value: 50), [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
        let volume = DDCPacket.makeDDCWritePacket(vcp: 0x62, value: 0x1234)
        XCTAssertEqual(Array(volume[0..<5]), [0x84, 0x03, 0x62, 0x12, 0x34])
        XCTAssertEqual(volume[5], DDCPacket.checksum(seed: 0x6E ^ 0x51, bytes: Array(volume[0..<5])))
    }

    func testReadPacketFramingMatchesM1DDC() {
        // 0x6E ^ 0x82 ^ 0x01 ^ 0x10 = 0xFD
        XCTAssertEqual(DDCPacket.makeDDCReadPacket(vcp: 0x10), [0x82, 0x01, 0x10, 0xFD])
        let input = DDCPacket.makeDDCReadPacket(vcp: 0x60)
        XCTAssertEqual(input.count, 4)
        XCTAssertEqual(input[3], 0x6E ^ 0x82 ^ 0x01 ^ 0x60)
    }

    func testChecksum() {
        XCTAssertEqual(DDCPacket.checksum(seed: 0x00, bytes: []), 0x00)
        XCTAssertEqual(DDCPacket.checksum(seed: 0x6E, bytes: []), 0x6E)
        XCTAssertEqual(DDCPacket.checksum(seed: 0xFF, bytes: [0xFF]), 0x00)
        XCTAssertEqual(DDCPacket.checksum(seed: 0x50, bytes: [0x01, 0x02, 0x04]), 0x57)
    }

    func testParseValidReply() {
        let reply = DDCPacket.parseDDCReplyPacket(makeReply(vcp: 0x10, current: 50, max: 100), expectedVCP: 0x10)
        XCTAssertEqual(reply, DDCReply(vcp: 0x10, typeCode: 0, maxValue: 100, currentValue: 50))
        // Without expected VCP and with trailing bytes (12-byte reads).
        let long = makeReply(vcp: 0x62, current: 0x0102, max: 0xFFFF) + [0x00]
        XCTAssertEqual(DDCPacket.parseDDCReplyPacket(long)?.currentValue, 0x0102)
        XCTAssertEqual(DDCPacket.parseDDCReplyPacket(long)?.maxValue, 0xFFFF)
    }

    func testParseRejectsInvalidReplies() {
        var badChecksum = makeReply(vcp: 0x10, current: 50, max: 100)
        badChecksum[10] ^= 0x01
        XCTAssertNil(DDCPacket.parseDDCReplyPacket(badChecksum, expectedVCP: 0x10))
        XCTAssertNil(DDCPacket.parseDDCReplyPacket(makeReply(vcp: 0x62, current: 50, max: 100), expectedVCP: 0x10), "wrong VCP")
        XCTAssertNil(DDCPacket.parseDDCReplyPacket(makeReply(vcp: 0x10, current: 0, max: 0, result: 0x01), expectedVCP: 0x10), "unsupported VCP result code")
        XCTAssertNil(DDCPacket.parseDDCReplyPacket(Array(makeReply(vcp: 0x10, current: 50, max: 100).prefix(10))), "short")
        XCTAssertNil(DDCPacket.parseDDCReplyPacket([]), "empty")
        var wrongOpcode: [UInt8] = [0x6E, 0x88, 0x03, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32]
        wrongOpcode.append(DDCPacket.checksum(seed: 0x50, bytes: wrongOpcode))
        XCTAssertNil(DDCPacket.parseDDCReplyPacket(wrongOpcode), "not a VCP reply opcode")
    }

    func testNormalizeAndDenormalize() {
        XCTAssertEqual(DDCPacket.normalize(raw: 50, maxValue: 100), 50)
        XCTAssertEqual(DDCPacket.normalize(raw: 100, maxValue: 200), 50)
        XCTAssertEqual(DDCPacket.normalize(raw: 5, maxValue: 0), 5, "maxValue == 0 treated as 100")
        XCTAssertEqual(DDCPacket.normalize(raw: 150, maxValue: 100), 100, "clamped to max")
        XCTAssertEqual(DDCPacket.normalize(raw: 0, maxValue: 65535), 0)
        XCTAssertEqual(DDCPacket.normalize(raw: 65535, maxValue: 65535), 100)

        XCTAssertEqual(DDCPacket.denormalize(percent: 50, maxValue: 200), 100)
        XCTAssertEqual(DDCPacket.denormalize(percent: 150, maxValue: 100), 100, "percent clamped to 100")
        XCTAssertEqual(DDCPacket.denormalize(percent: 50, maxValue: 0), 50, "maxValue == 0 treated as 100")
        XCTAssertEqual(DDCPacket.denormalize(percent: 0, maxValue: 255), 0)
        XCTAssertEqual(DDCPacket.denormalize(percent: 100, maxValue: 255), 255)
    }
}

// MARK: - DDCController with fake transport

final class DDCControllerTests: XCTestCase {
    private func makeController(_ transport: FakeDDCTransport) -> DDCController {
        DDCController(transport: transport, maxAttempts: 3, replyDelay: 0, retryDelayRange: 0...0)
    }

    func testBrightnessIsNormalizedUsingMaxValue() {
        let transport = FakeDDCTransport()
        transport.setRegister(0x10, current: 100, max: 200)
        let ddc = makeController(transport)
        XCTAssertEqual(ddc.readBrightness(displayID: fakeDisplayID), 50)

        XCTAssertTrue(ddc.writeBrightness(displayID: fakeDisplayID, value: 25))
        XCTAssertEqual(transport.register(0x10)?.current, 50, "25% of max 200")
        XCTAssertTrue(ddc.writeBrightness(displayID: fakeDisplayID, value: 250))
        XCTAssertEqual(transport.register(0x10)?.current, 200, "clamped to 100%")
    }

    func testWriteWithUnknownMaxReadsMaxFirst() {
        let transport = FakeDDCTransport()
        transport.setRegister(0x62, current: 10, max: 50)
        let ddc = makeController(transport)
        XCTAssertTrue(ddc.writeVolume(displayID: fakeDisplayID, value: 100))
        XCTAssertEqual(transport.register(0x62)?.current, 50)
        XCTAssertEqual(ddc.readVolume(displayID: fakeDisplayID), 100)
    }

    func testWriteRetriesTransientFailures() {
        let transport = FakeDDCTransport()
        transport.setRegister(0x62, current: 0, max: 100)
        let ddc = makeController(transport)
        _ = ddc.readVolume(displayID: fakeDisplayID) // caches max
        let before = transport.writeAttempts

        transport.writeFailuresRemaining = 2
        XCTAssertTrue(ddc.writeVolume(displayID: fakeDisplayID, value: 40))
        XCTAssertEqual(transport.writeAttempts - before, 3, "2 failures + 1 success")
        XCTAssertEqual(transport.register(0x62)?.current, 40)
        XCTAssertEqual(transport.invalidations, 0)
    }

    func testWriteStopsAfterThreeAttempts() {
        let transport = FakeDDCTransport()
        let ddc = makeController(transport)
        transport.writeFailuresRemaining = 10
        XCTAssertFalse(ddc.writeMute(displayID: fakeDisplayID, muted: true))
        XCTAssertEqual(transport.writeAttempts, 3)
        XCTAssertEqual(transport.invalidations, 1, "transport cache invalidated after exhausting retries")
    }

    func testReadRetriesAndExhaustion() {
        let transport = FakeDDCTransport()
        transport.setRegister(0x10, current: 70, max: 100)
        let ddc = makeController(transport)

        transport.readFailuresRemaining = 2
        XCTAssertEqual(ddc.readBrightness(displayID: fakeDisplayID), 70)
        XCTAssertEqual(transport.readAttempts, 3)

        transport.readFailuresRemaining = 3
        XCTAssertNil(ddc.readBrightness(displayID: fakeDisplayID))
        XCTAssertEqual(transport.readAttempts, 6)
    }

    func testCorruptRepliesAreRejected() {
        let transport = FakeDDCTransport()
        transport.setRegister(0x10, current: 70, max: 100)
        transport.corruptReplies = true
        let ddc = makeController(transport)
        XCTAssertNil(ddc.readBrightness(displayID: fakeDisplayID))
        XCTAssertEqual(transport.readAttempts, 3)
    }

    func testMuteUsesMCCSEncoding() {
        let transport = FakeDDCTransport()
        let ddc = makeController(transport)
        XCTAssertTrue(ddc.writeMute(displayID: fakeDisplayID, muted: true))
        XCTAssertEqual(transport.register(0x8D)?.current, 1, "1 = mute")
        XCTAssertEqual(ddc.readMute(displayID: fakeDisplayID), true)

        XCTAssertTrue(ddc.writeMute(displayID: fakeDisplayID, muted: false))
        XCTAssertEqual(transport.register(0x8D)?.current, 2, "2 = unmute")
        XCTAssertEqual(ddc.readMute(displayID: fakeDisplayID), false)

        XCTAssertEqual(DDCController.encodeMute(true), 1)
        XCTAssertEqual(DDCController.encodeMute(false), 2)
        XCTAssertTrue(DDCController.decodeMute(1))
        XCTAssertFalse(DDCController.decodeMute(2))
        XCTAssertFalse(DDCController.decodeMute(0))
    }

    func testInputSourcePresetsAndCustomValues() {
        let transport = FakeDDCTransport()
        let ddc = makeController(transport)

        XCTAssertTrue(ddc.writeInputSource(displayID: fakeDisplayID, source: .hdmi1))
        XCTAssertEqual(transport.register(0x60)?.current, 0x11)
        XCTAssertEqual(ddc.readInputSource(displayID: fakeDisplayID), .hdmi1)

        transport.setRegister(0x60, current: 0x0F, max: 0x1B)
        XCTAssertEqual(ddc.readInputSource(displayID: fakeDisplayID)?.rawValue, DDCInputSource.displayPort1.rawValue)

        XCTAssertTrue(ddc.writeInputSource(displayID: fakeDisplayID, source: .custom(0x1B)))
        XCTAssertEqual(transport.register(0x60)?.current, 0x1B)
        XCTAssertEqual(ddc.readInputSource(displayID: fakeDisplayID)?.displayName, "USB-C")

        transport.setRegister(0x60, current: 0x1200, max: 0)
        XCTAssertEqual(ddc.readInputSource(displayID: fakeDisplayID)?.rawValue, 0x12, "value reported in the high byte")
        XCTAssertEqual(DDCController.decodeInputSource(0x0011), 0x11)
        XCTAssertEqual(DDCController.decodeInputSource(0x1100), 0x11)
    }

    func testUnavailableTransportFailsGracefully() {
        let transport = FakeDDCTransport()
        transport.available = false
        let ddc = makeController(transport)
        XCTAssertNil(ddc.readBrightness(displayID: fakeDisplayID))
        XCTAssertFalse(ddc.writeBrightness(displayID: fakeDisplayID, value: 50))
        XCTAssertEqual(transport.writeAttempts, 0)
        let report = ddc.probeCapabilities(displayID: fakeDisplayID)
        XCTAssertFalse(report.hasIOAVService)
        XCTAssertNotNil(report.probeError)
    }

    func testProbeCapabilities() {
        let transport = FakeDDCTransport()
        transport.setRegister(0x10, current: 80, max: 100)
        transport.setRegister(0x60, current: 0x0F, max: 0x1B)
        let ddc = makeController(transport)
        let report = ddc.probeCapabilities(displayID: fakeDisplayID)
        XCTAssertTrue(report.hasIOAVService)
        XCTAssertTrue(report.supportsLuminance)
        XCTAssertEqual(report.currentLuminance, 80)
        XCTAssertFalse(report.supportsVolume, "VCP 0x62 reports unsupported")
        XCTAssertNil(report.currentVolume)
        XCTAssertTrue(report.supportsInputSource)
        XCTAssertEqual(report.currentInputSource?.rawValue, 0x0F)
        XCTAssertNil(report.probeError)
    }

    func testBuiltInDisplayIsNeverAddressed() {
        // The Built-in panel is discovered even while soft-disconnected (SLSGetDisplayList), so no skip is needed.
        let builtIns = [DisplayManager().builtInDisplayID()].compactMap { $0 }
            + DisplayManager.onlineDisplayIDs().filter { CGDisplayIsBuiltin($0) == 1 }
        let transport = FakeDDCTransport()
        transport.setRegister(0x10, current: 50, max: 100)
        let ddc = makeController(transport)
        for builtIn in builtIns {
            XCTAssertNil(ddc.readBrightness(displayID: builtIn))
            XCTAssertFalse(ddc.writeBrightness(displayID: builtIn, value: 10))
            XCTAssertFalse(ddc.writeMute(displayID: builtIn, muted: true))
            XCTAssertFalse(ddc.probeCapabilities(displayID: builtIn).hasIOAVService)
        }
        XCTAssertEqual(transport.writeAttempts, 0, "no I²C traffic for the Built-in panel")

        // Unknown IDs make CGDisplayIsBuiltin return -1: they must NOT be mistaken for the Built-in panel.
        XCTAssertNotEqual(CGDisplayIsBuiltin(fakeDisplayID), 1)
        XCTAssertEqual(ddc.readBrightness(displayID: fakeDisplayID), 50)
    }
}

// MARK: - DisplayManager pure helpers

final class DisplayManagerHelperTests: XCTestCase {
    private func display(_ id: CGDirectDisplayID, builtIn: Bool, online: Bool = true, enabled: Bool = true) -> DisplayInfo {
        DisplayInfo(id: id, identifier: DisplayIdentifier(vendorNumber: 1, modelNumber: id), name: "D\(id)",
                    isBuiltIn: builtIn, isMain: false, isOnline: online, isEnabled: enabled)
    }

    func testCanDisableBuiltIn() {
        XCTAssertFalse(DisplayManager.canDisableBuiltIn(displays: [display(1, builtIn: true)]))
        XCTAssertFalse(DisplayManager.canDisableBuiltIn(displays: [display(1, builtIn: true), display(2, builtIn: false, enabled: false)]))
        XCTAssertFalse(DisplayManager.canDisableBuiltIn(displays: [display(1, builtIn: true), display(2, builtIn: false, online: false)]))
        let virtualPlaceholder = DisplayInfo(
            id: 11,
            identifier: DisplayIdentifier(vendorNumber: 0x756E6B6E, modelNumber: 0x76697274),
            name: "Display 11",
            isBuiltIn: false,
            isVirtual: true,
            isMain: true,
            isOnline: true,
            isEnabled: true
        )
        XCTAssertFalse(DisplayManager.canDisableBuiltIn(displays: [display(1, builtIn: true), virtualPlaceholder]))
        XCTAssertTrue(DisplayManager.canDisableBuiltIn(displays: [display(1, builtIn: true), display(2, builtIn: false)]))
    }

    func testVirtualDisplayDetection() {
        // WindowServer headless placeholder ('unkn' / 'virt')
        XCTAssertTrue(DisplayManager.isVirtualDisplay(vendor: 0x756E6B6E, model: 0x76697274, isVirtualDeviceFlag: false))
        // Invalid / unbacked display IDs (0xFFFFFFFF or 0/0)
        XCTAssertTrue(DisplayManager.isVirtualDisplay(vendor: UInt32.max, model: UInt32.max, isVirtualDeviceFlag: false))
        XCTAssertTrue(DisplayManager.isVirtualDisplay(vendor: 0, model: 0, isVirtualDeviceFlag: false))
        // CoreDisplay kCGDisplayIsVirtualDevice == true
        XCTAssertTrue(DisplayManager.isVirtualDisplay(vendor: 19501, model: 28754, isVirtualDeviceFlag: true))
        // Real physical monitors (Samsung LC49G95T, Apple Built-in)
        XCTAssertFalse(DisplayManager.isVirtualDisplay(vendor: 19501, model: 28754, isVirtualDeviceFlag: false))
        XCTAssertFalse(DisplayManager.isVirtualDisplay(vendor: 1552, model: 41038, isVirtualDeviceFlag: false))
    }

    func testNormalizedRotation() {
        XCTAssertEqual(DisplayManager.normalizedRotation(0), 0)
        XCTAssertEqual(DisplayManager.normalizedRotation(90), 90)
        XCTAssertEqual(DisplayManager.normalizedRotation(180), 180)
        XCTAssertEqual(DisplayManager.normalizedRotation(270), 270)
        XCTAssertEqual(DisplayManager.normalizedRotation(360), 0)
        XCTAssertEqual(DisplayManager.normalizedRotation(450), 90)
        XCTAssertEqual(DisplayManager.normalizedRotation(-90), 270)
        XCTAssertNil(DisplayManager.normalizedRotation(45))
        XCTAssertNil(DisplayManager.normalizedRotation(-1))
    }

    func testReoriginPlacesTargetAtZero() {
        let bounds: [CGDirectDisplayID: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 1512, height: 982),
            3: CGRect(x: -1804, y: -1440, width: 5120, height: 1440)
        ]
        let origins = DisplayManager.reorigin(bounds: bounds, target: 3)
        XCTAssertEqual(origins?[3], CGPoint(x: 0, y: 0))
        XCTAssertEqual(origins?[1], CGPoint(x: 1804, y: 1440), "relative arrangement preserved")
        XCTAssertNil(DisplayManager.reorigin(bounds: bounds, target: 99))
    }

    func testDeduplicatedModesKeepsHiDPIAndRefreshVariants() {
        let modes = [
            DisplayModeInfo(width: 3840, height: 1080, pixelWidth: 3840, pixelHeight: 1080, refreshRate: 60, isHiDPI: false, modeIndex: 0),
            DisplayModeInfo(width: 3840, height: 1080, pixelWidth: 7680, pixelHeight: 2160, refreshRate: 60, isHiDPI: true, modeIndex: 1),
            DisplayModeInfo(width: 3840, height: 1080, pixelWidth: 7680, pixelHeight: 2160, refreshRate: 60, isHiDPI: true, modeIndex: 2), // duplicate
            DisplayModeInfo(width: 5120, height: 1440, pixelWidth: 5120, pixelHeight: 1440, refreshRate: 120, isHiDPI: false, modeIndex: 3),
            DisplayModeInfo(width: 5120, height: 1440, pixelWidth: 5120, pixelHeight: 1440, refreshRate: 60, isHiDPI: false, modeIndex: 4),
            DisplayModeInfo(width: 5120, height: 1440, pixelWidth: 5120, pixelHeight: 1440, refreshRate: 59.94, isHiDPI: false, modeIndex: 5)
        ]
        let result = DisplayManager.deduplicatedModes(modes)
        XCTAssertEqual(result.count, 5)
        XCTAssertEqual(result.map(\.modeIndex), [3, 4, 5, 1, 0], "largest first, highest Hz first, HiDPI before LoDPI")
        XCTAssertEqual(Set(result.map(\.id)).count, result.count, "ids are unique")
    }
}

// MARK: - IOAVService matching

final class AVServiceMatchingTests: XCTestCase {
    private let g9 = AVServiceCandidate(
        vendorID: 19501, productID: 28754, serialNumber: 1_129_859_672,
        productName: "LC49G95T", edidUUID: "4C2D5270-0000-0000-FFFF-010380772278", registryEntryID: 1
    )

    func testFullMatchScoresHighest() {
        let score = AVServiceCandidate.matchScore(candidate: g9, vendor: 19501, model: 28754, serial: 1_129_859_672, name: "LC49G95T")
        XCTAssertEqual(score, 6)
    }

    func testMismatchedIdentityScoresZero() {
        XCTAssertEqual(AVServiceCandidate.matchScore(candidate: g9, vendor: 1552, model: 28754, serial: 0, name: nil), 0)
        XCTAssertEqual(AVServiceCandidate.matchScore(candidate: g9, vendor: 19501, model: 1, serial: 0, name: nil), 0)
        XCTAssertEqual(AVServiceCandidate.matchScore(candidate: g9, vendor: 19501, model: 28754, serial: 42, name: nil), 0)
    }

    func testEDIDUUIDOnlyCandidate() {
        let uuidOnly = AVServiceCandidate(vendorID: nil, productID: nil, serialNumber: nil, productName: nil,
                                          edidUUID: "4C2D5270-0000-0000-FFFF-010380772278", registryEntryID: 2)
        XCTAssertGreaterThan(AVServiceCandidate.matchScore(candidate: uuidOnly, vendor: 0x4C2D, model: 0x7052, serial: 0, name: nil), 0)
        XCTAssertEqual(AVServiceCandidate.matchScore(candidate: uuidOnly, vendor: 0x0610, model: 0xA04E, serial: 0, name: nil), 0)
    }
}

// MARK: - CoreAudio matching

final class CoreAudioMatchingTests: XCTestCase {
    private let g9Vendor: UInt32 = 0x4C2D
    private let g9Model: UInt32 = 0x7052

    private func device(_ name: String, uid: String, transport: UInt32) -> AudioOutputDeviceInfo {
        AudioOutputDeviceInfo(deviceID: 1, name: name, uid: uid, transportType: transport)
    }

    func testDisplayTransports() {
        XCTAssertTrue(CoreAudioObserver.isDisplayTransport(kAudioDeviceTransportTypeDisplayPort))
        XCTAssertTrue(CoreAudioObserver.isDisplayTransport(kAudioDeviceTransportTypeHDMI))
        XCTAssertTrue(CoreAudioObserver.isDisplayTransport(kAudioDeviceTransportTypeThunderbolt))
        XCTAssertFalse(CoreAudioObserver.isDisplayTransport(kAudioDeviceTransportTypeBuiltIn))
        XCTAssertFalse(CoreAudioObserver.isDisplayTransport(kAudioDeviceTransportTypeBluetooth))
        XCTAssertFalse(CoreAudioObserver.isDisplayTransport(kAudioDeviceTransportTypeBluetoothLE))
        XCTAssertFalse(CoreAudioObserver.isDisplayTransport(kAudioDeviceTransportTypeUSB))
        XCTAssertFalse(CoreAudioObserver.isDisplayTransport(kAudioDeviceTransportTypeVirtual))
        XCTAssertFalse(CoreAudioObserver.isDisplayTransport(kAudioDeviceTransportTypeAggregate))
        XCTAssertFalse(CoreAudioObserver.isDisplayTransport(kAudioDeviceTransportTypeAirPlay))
    }

    func testEDIDUIDFragments() {
        let fragments = CoreAudioObserver.edidUIDFragments(vendor: g9Vendor, model: g9Model)
        XCTAssertTrue(fragments.contains("4C2D5270"), "vendor big-endian + product little-endian (Apple Silicon UID)")
        XCTAssertTrue(fragments.contains("2D4C5270"), "Intel-style byte-swapped vendor")
        XCTAssertEqual(Set(fragments).count, fragments.count)
    }

    func testBuiltInSpeakersHeadphonesAndBluetoothNeverMatch() {
        let speakers = device("MacBook Pro Speakers", uid: "BuiltInSpeakerDevice", transport: kAudioDeviceTransportTypeBuiltIn)
        let headphones = device("External Headphones", uid: "BuiltInHeadphoneOutputDevice", transport: kAudioDeviceTransportTypeBuiltIn)
        let airpods = device("AirPods Pro", uid: "AA-BB-CC-DD-EE-FF:output", transport: kAudioDeviceTransportTypeBluetooth)
        let usb = device("Razer Seiren V2 Pro", uid: "AppleUSBAudioEngine:Razer", transport: kAudioDeviceTransportTypeUSB)
        let virtual = device("LC49G95T", uid: "4C2D5270-virtual", transport: kAudioDeviceTransportTypeVirtual)
        for candidate in [speakers, headphones, airpods, usb, virtual] {
            XCTAssertFalse(CoreAudioObserver.deviceMatchesDisplay(
                device: candidate, isBuiltInDisplay: false, vendor: g9Vendor, model: g9Model,
                displayName: "LC49G95T", externalDisplayCount: 1
            ), "\(candidate.name) must never be treated as monitor audio")
        }
    }

    func testMonitorAudioMatchesByEDIDUID() {
        let g9Audio = device("LC49G95T", uid: "4C2D5270-0000-0000-FFFF-010380772278", transport: kAudioDeviceTransportTypeHDMI)
        XCTAssertTrue(CoreAudioObserver.deviceMatchesDisplay(
            device: g9Audio, isBuiltInDisplay: false, vendor: g9Vendor, model: g9Model,
            displayName: nil, externalDisplayCount: 2
        ))
        XCTAssertFalse(CoreAudioObserver.deviceMatchesDisplay(
            device: g9Audio, isBuiltInDisplay: true, vendor: g9Vendor, model: g9Model,
            displayName: "LC49G95T", externalDisplayCount: 1
        ), "the built-in display never owns monitor audio")
    }

    func testMonitorAudioMatchesByNameAndSingleDisplayFallback() {
        let dpAudio = device("DELL U2720Q", uid: "opaque-uid", transport: kAudioDeviceTransportTypeDisplayPort)
        XCTAssertTrue(CoreAudioObserver.deviceMatchesDisplay(
            device: dpAudio, isBuiltInDisplay: false, vendor: 0x10AC, model: 0xA0C4,
            displayName: "DELL U2720Q", externalDisplayCount: 2
        ), "name match")
        XCTAssertFalse(CoreAudioObserver.deviceMatchesDisplay(
            device: dpAudio, isBuiltInDisplay: false, vendor: g9Vendor, model: g9Model,
            displayName: "LC49G95T", externalDisplayCount: 2
        ), "another monitor's audio with two externals connected")
        XCTAssertTrue(CoreAudioObserver.deviceMatchesDisplay(
            device: dpAudio, isBuiltInDisplay: false, vendor: g9Vendor, model: g9Model,
            displayName: "LC49G95T", externalDisplayCount: 1
        ), "single external display fallback")
    }
}

// MARK: - CoreBrightnessBridge pure logic

final class CoreBrightnessBridgeLogicTests: XCTestCase {
    private func date(_ hour: Int, _ minute: Int, zone: String = "Europe/Warsaw") -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: hour, minute: minute))!
    }

    func testOvernightScheduleWithRamp() {
        let config = NightShiftConfig(enabled: true, warmth: 0.6, transitionMinutes: 20, timeZoneIdentifier: "Europe/Warsaw")
        func eval(_ h: Int, _ m: Int) -> (Bool, Double) {
            let r = CoreBrightnessBridge.evaluateSchedule(config: config, now: date(h, m))
            return (r.shouldBeActive, r.effectiveWarmth)
        }
        XCTAssertEqual(eval(17, 59).0, false)
        XCTAssertEqual(eval(18, 0).0, true)
        XCTAssertEqual(eval(18, 10).1, 0.3, accuracy: 0.001)
        XCTAssertEqual(eval(18, 20).1, 0.6, accuracy: 0.001)
        XCTAssertEqual(eval(0, 0).1, 0.6, accuracy: 0.001)
        XCTAssertEqual(eval(4, 50).1, 0.3, accuracy: 0.001)
        XCTAssertEqual(eval(5, 0).0, false)
        XCTAssertEqual(eval(12, 0).0, false)
    }

    func testMasterSwitchAndManualMode() {
        var config = NightShiftConfig(enabled: false, warmth: 0.5)
        XCTAssertFalse(CoreBrightnessBridge.evaluateSchedule(config: config, now: date(23, 0)).shouldBeActive)
        config.enabled = true
        config.scheduleEnabled = false
        let manual = CoreBrightnessBridge.evaluateSchedule(config: config, now: date(12, 0))
        XCTAssertTrue(manual.shouldBeActive)
        XCTAssertEqual(manual.effectiveWarmth, 0.5, accuracy: 0.001)
    }

    func testTimeZoneResolution() {
        let utc = CoreBrightnessBridge.resolveTimeZone("UTC")
        XCTAssertEqual(utc.secondsFromGMT(), 0)
        XCTAssertTrue(["UTC", "GMT"].contains(utc.identifier), "Foundation may canonicalize UTC as GMT")
        XCTAssertEqual(CoreBrightnessBridge.resolveTimeZone("Europe/Warsaw").identifier, "Europe/Warsaw")
        XCTAssertEqual(CoreBrightnessBridge.resolveTimeZone("Not/AZone"), TimeZone.current)
        XCTAssertEqual(CoreBrightnessBridge.resolveTimeZone(nil), TimeZone.current)
        XCTAssertEqual(CoreBrightnessBridge.fallbackTimeZone.identifier, "Europe/Warsaw")
    }

    func testNativeStatusDecodingFromRawStruct() {
        var bytes = [UInt8](repeating: 0, count: NativeNightShiftStatus.Offset.size)
        bytes[0] = 1 // active
        bytes[1] = 0 // enabled
        bytes[2] = 1 // sunSchedulePermitted
        func put32(_ value: Int32, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { for (i, b) in $0.enumerated() { bytes[offset + i] = b } }
        }
        put32(2, at: 4)
        put32(22, at: 8)
        put32(30, at: 12)
        put32(7, at: 16)
        put32(15, at: 20)
        bytes[32] = 1 // available
        let status = bytes.withUnsafeBytes { NativeNightShiftStatus(rawBuffer: $0) }
        XCTAssertEqual(status?.active, true)
        XCTAssertEqual(status?.enabled, false)
        XCTAssertEqual(status?.mode, 2)
        XCTAssertEqual(status?.fromHour, 22)
        XCTAssertEqual(status?.fromMinute, 30)
        XCTAssertEqual(status?.toHour, 7)
        XCTAssertEqual(status?.toMinute, 15)
        XCTAssertEqual(status?.available, true)
        XCTAssertNil([UInt8](repeating: 0, count: 8).withUnsafeBytes { NativeNightShiftStatus(rawBuffer: $0) })
    }
}

// MARK: - Read-only host checks (no setters, no DDC traffic)

final class ReadOnlyHostTests: XCTestCase {
    func testPrivateBridgesResolveWithoutCrashing() {
        _ = SkyLightBridge.shared.canConfigureDisplayEnabled
        _ = SkyLightBridge.shared.canControlBuiltInBrightness
        if let ids = SkyLightBridge.shared.allKnownDisplayIDs() {
            XCTAssertFalse(ids.contains(kCGNullDirectDisplay))
        }
        _ = CoreDisplayBridge.shared.canToggleHDR
        _ = IOAVServiceBridge.shared.isAvailable
        _ = CoreBrightnessBridge().nativeStatus()
    }

    func testBuiltInNeverReportsHDRToggle() {
        let manager = DisplayManager()
        var builtIns = DisplayManager.onlineDisplayIDs().filter { CGDisplayIsBuiltin($0) == 1 }
        if let id = manager.builtInDisplayID() { builtIns.append(id) } // includes a soft-disconnected panel
        for id in builtIns {
            XCTAssertFalse(CoreDisplayBridge.shared.supportsHDR(displayID: id))
            XCTAssertFalse(CoreDisplayBridge.shared.isHDREnabled(displayID: id))
        }
        for display in manager.getOnlineDisplays() where display.isBuiltIn {
            XCTAssertFalse(display.supportsHDR, "Built-in reports no HDR toggle regardless of isEnabled")
            XCTAssertFalse(display.isHDREnabled)
        }
    }

    func testGetOnlineDisplaysEnumeratesHostConsistently() {
        let manager = DisplayManager()
        let displays = manager.getOnlineDisplays()
        XCTAssertEqual(Set(displays.map(\.id)).count, displays.count, "no duplicate display IDs")
        for display in displays {
            XCTAssertFalse(display.name.isEmpty)
            XCTAssertTrue([0, 90, 180, 270].contains(display.rotation))
            XCTAssertEqual(Set(display.availableModes.map(\.id)).count, display.availableModes.count, "modes deduplicated")
            for mode in display.availableModes {
                XCTAssertEqual(mode.isHiDPI, mode.pixelWidth > mode.width)
            }
            if display.isBuiltIn {
                XCTAssertFalse(display.supportsDDC)
                XCTAssertFalse(display.supportsHDR)
            }
            if !display.isEnabled {
                XCTAssertTrue(display.availableModes.isEmpty)
            }
        }
        if let builtInID = manager.builtInDisplayID() {
            XCTAssertTrue(displays.contains { $0.id == builtInID && $0.isBuiltIn }, "soft-disconnected Built-in still listed")
            let entry = displays.first { $0.id == builtInID }
            XCTAssertEqual(entry?.isEnabled, manager.isBuiltInDisplayEnabled())
        }
        let activeExternal = manager.activeExternalDisplayIDs()
        XCTAssertEqual(DisplayManager.canDisableBuiltIn(displays: displays), !activeExternal.isEmpty)
    }
}
