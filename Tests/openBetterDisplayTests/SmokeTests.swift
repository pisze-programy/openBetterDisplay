import XCTest
import CoreGraphics
@testable import OpenBetterDisplayCore

final class SmokeTests: XCTestCase {

    func testDisplayIdentifierStorageKey() {
        let withSerial = DisplayIdentifier(vendorNumber: 1552, modelNumber: 29012, serialNumber: 889911)
        XCTAssertEqual(withSerial.storageKey, "V1552_M29012_S889911")

        let withUUID = DisplayIdentifier(vendorNumber: 1552, modelNumber: 29012, serialNumber: 0, uuidString: "ABCD-EF01")
        XCTAssertEqual(withUUID.storageKey, "V1552_M29012_UUID_ABCD-EF01")

        let minimal = DisplayIdentifier(vendorNumber: 1552, modelNumber: 29012, serialNumber: 0, uuidString: nil)
        XCTAssertEqual(minimal.storageKey, "V1552_M29012")
    }

    func testNightShiftConfigDefaults() {
        let config = NightShiftConfig()
        XCTAssertFalse(config.enabled)
        XCTAssertTrue(config.scheduleEnabled)
        XCTAssertEqual(config.startHour, 18)
        XCTAssertEqual(config.startMinute, 0)
        XCTAssertEqual(config.endHour, 5)
        XCTAssertEqual(config.endMinute, 0)
        XCTAssertEqual(config.warmth, 0.5, accuracy: 0.001)
        XCTAssertEqual(config.transitionMinutes, 20)
        XCTAssertTrue(config.applySoftwareFallbackInHDR)
        XCTAssertNil(config.timeZoneIdentifier)
    }

    func testDisplayIdentifierCodableRoundTrip() throws {
        let original = DisplayIdentifier(vendorNumber: 1953, modelNumber: 3120, serialNumber: 42, uuidString: "1234-5678")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DisplayIdentifier.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testDisplayModeInfoCodableRoundTrip() throws {
        let original = DisplayModeInfo(
            id: "5120x1440@120",
            width: 5120,
            height: 1440,
            pixelWidth: 5120,
            pixelHeight: 1440,
            refreshRate: 120.0,
            isHiDPI: false,
            modeIndex: 1,
            displayLabel: "5120 × 1440 @ 120Hz"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DisplayModeInfo.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testDDCInputSourcePresetsAndCodableRoundTrip() throws {
        XCTAssertEqual(DDCInputSource.displayPort1.rawValue, 0x0F)
        XCTAssertEqual(DDCInputSource.displayPort2.rawValue, 0x10)
        XCTAssertEqual(DDCInputSource.hdmi1.rawValue, 0x11)
        XCTAssertEqual(DDCInputSource.hdmi2.rawValue, 0x12)
        XCTAssertEqual(DDCInputSource.usbC.rawValue, 0x1B)

        let custom = DDCInputSource.custom(0x05, name: "VGA")
        let data = try JSONEncoder().encode(custom)
        let decoded = try JSONDecoder().decode(DDCInputSource.self, from: data)
        XCTAssertEqual(custom, decoded)
    }

    func testMonitorProfileCodableRoundTrip() throws {
        let identifier = DisplayIdentifier(vendorNumber: 1552, modelNumber: 29012, serialNumber: 100)
        let profile = MonitorProfile(
            identifier: identifier,
            displayName: "Samsung LC49G95T",
            targetWidth: 5120,
            targetHeight: 1440,
            targetPixelWidth: 5120,
            targetPixelHeight: 1440,
            targetRefreshRate: 120.0,
            targetIsHiDPI: false,
            hdrEnabled: true,
            combinedBrightness: 0.75,
            ddcVolume: 40,
            isMuted: false,
            isMainDisplay: true,
            builtInDisplayEnabled: false,
            rotation: 0,
            preferredInputSource: .displayPort1,
            autoRestoreOnConnect: true,
            autoDisableBuiltInOnConnect: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(profile)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MonitorProfile.self, from: data)

        XCTAssertEqual(profile.id, decoded.id)
        XCTAssertEqual(profile.displayName, decoded.displayName)
        XCTAssertEqual(profile.targetWidth, decoded.targetWidth)
        XCTAssertEqual(profile.targetHeight, decoded.targetHeight)
        XCTAssertEqual(profile.hdrEnabled, decoded.hdrEnabled)
        XCTAssertEqual(profile.combinedBrightness, decoded.combinedBrightness, accuracy: 0.001)
        XCTAssertEqual(profile.ddcVolume, decoded.ddcVolume)
        XCTAssertEqual(profile.builtInDisplayEnabled, decoded.builtInDisplayEnabled)
        XCTAssertEqual(profile.preferredInputSource, decoded.preferredInputSource)
    }

    func testDisplayInfoCodableRoundTrip() throws {
        let identifier = DisplayIdentifier(vendorNumber: 100, modelNumber: 200, serialNumber: 300)
        let mode = DisplayModeInfo(
            width: 3840,
            height: 1080,
            pixelWidth: 7680,
            pixelHeight: 2160,
            refreshRate: 60.0,
            isHiDPI: true,
            modeIndex: 0
        )
        let info = DisplayInfo(
            id: 1,
            identifier: identifier,
            name: "Test Monitor",
            isBuiltIn: false,
            isMain: true,
            isOnline: true,
            isEnabled: true,
            isMirrored: false,
            rotation: 0,
            supportsHDR: true,
            isHDREnabled: true,
            currentMode: mode,
            availableModes: [mode],
            supportsDDC: true,
            supportsRotation: true
        )

        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(DisplayInfo.self, from: data)
        XCTAssertEqual(info, decoded)
    }

    func testBrightnessMethodBadges() {
        XCTAssertEqual(BrightnessMethod.ddc.badgeText, "DDC")
        XCTAssertEqual(BrightnessMethod.ddcWithDimming.badgeText, "DDC + Dim")
        XCTAssertEqual(BrightnessMethod.softwareHDR.badgeText, "Software HDR")
        XCTAssertEqual(BrightnessMethod.softwareFallback.badgeText, "Software")
        XCTAssertEqual(BrightnessMethod.nativeBuiltIn.badgeText, "Built-in")
    }

    func testAppSettingsCodableRoundTrip() throws {
        let settings = AppSettings.default
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(settings, decoded)
    }

    func testDDCCapabilityReportCodableRoundTrip() throws {
        let report = DDCCapabilityReport(
            displayID: 2,
            displayName: "LC49G95T",
            hasIOAVService: true,
            supportsLuminance: true,
            currentLuminance: 65,
            supportsVolume: true,
            currentVolume: 20,
            supportsInputSource: true,
            currentInputSource: .displayPort1,
            probeError: nil
        )
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(DDCCapabilityReport.self, from: data)
        XCTAssertEqual(report, decoded)
    }

    func testKeyComboDefault() {
        let emergency = KeyCombo.emergencyRestoreDefault
        XCTAssertEqual(emergency.displayString, "⌃⌥⌘R")
        XCTAssertEqual(emergency.keyCode, 15)
    }
}
