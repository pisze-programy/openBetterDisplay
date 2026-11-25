import Cocoa
import CoreGraphics
import Foundation

// MARK: - DisplayIdentifier

public struct DisplayIdentifier: Codable, Equatable, Hashable, Sendable {
    public let vendorNumber: UInt32
    public let modelNumber: UInt32
    public let serialNumber: UInt32
    public let uuidString: String?

    public var storageKey: String {
        if serialNumber != 0 {
            return "V\(vendorNumber)_M\(modelNumber)_S\(serialNumber)"
        } else if let uuidString = uuidString, !uuidString.isEmpty {
            return "V\(vendorNumber)_M\(modelNumber)_UUID_\(uuidString)"
        } else {
            return "V\(vendorNumber)_M\(modelNumber)"
        }
    }

    /// `true` when vendor/model match known macOS headless/virtual/invalid display sentinels
    /// (`'unkn'`/`'virt'`, `0xFFFFFFFF`, or `0`/`0`) that do not represent a physical monitor.
    public var isVirtualSentinel: Bool {
        Self.isVirtualSentinel(vendor: vendorNumber, model: modelNumber)
    }

    public static func isVirtualSentinel(vendor: UInt32, model: UInt32) -> Bool {
        let unknownVendor: UInt32 = 0x756E6B6E // 'unkn' (kDisplayVendorIDUnknown)
        let virtualModel: UInt32 = 0x76697274  // 'virt' (WindowServer headless/virtual display)
        if vendor == unknownVendor && model == virtualModel { return true }
        if vendor == UInt32.max || model == UInt32.max { return true }
        if vendor == 0 && model == 0 { return true }
        return false
    }

    public init(
        vendorNumber: UInt32,
        modelNumber: UInt32,
        serialNumber: UInt32 = 0,
        uuidString: String? = nil
    ) {
        self.vendorNumber = vendorNumber
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
        self.uuidString = uuidString
    }

    public init(displayID: CGDirectDisplayID) {
        self.vendorNumber = CGDisplayVendorNumber(displayID)
        self.modelNumber = CGDisplayModelNumber(displayID)
        self.serialNumber = CGDisplaySerialNumber(displayID)
        if let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID) {
            let cfStr = CFUUIDCreateString(nil, cfUUID.takeRetainedValue())
            self.uuidString = cfStr as String?
        } else {
            self.uuidString = nil
        }
    }
}

// MARK: - DisplayModeInfo

public struct DisplayModeInfo: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let width: Int
    public let height: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let refreshRate: Double
    public let isHiDPI: Bool
    public let modeIndex: Int
    public let displayLabel: String

    public init(
        id: String? = nil,
        width: Int,
        height: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        refreshRate: Double,
        isHiDPI: Bool,
        modeIndex: Int,
        displayLabel: String? = nil
    ) {
        let label = displayLabel ?? "\(width) × \(height)\(isHiDPI ? " HiDPI" : "") @ \(Int(round(refreshRate)))Hz"
        self.id = id ?? "\(width)x\(height)_\(pixelWidth)x\(pixelHeight)_\(Int(round(refreshRate)))_\(isHiDPI ? "hidpi" : "std")_\(modeIndex)"
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.isHiDPI = isHiDPI
        self.modeIndex = modeIndex
        self.displayLabel = label
    }
}

// MARK: - DisplayInfo

public struct DisplayInfo: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: CGDirectDisplayID
    public let identifier: DisplayIdentifier
    public let name: String
    public let isBuiltIn: Bool
    public let isVirtual: Bool
    public let isMain: Bool
    public let isOnline: Bool
    public let isEnabled: Bool
    public let isMirrored: Bool
    public let mirrorMasterID: CGDirectDisplayID?
    public let rotation: Int
    public let supportsHDR: Bool
    public let isHDREnabled: Bool
    public let currentMode: DisplayModeInfo?
    public let availableModes: [DisplayModeInfo]
    public let supportsDDC: Bool
    public let supportsRotation: Bool

    public init(
        id: CGDirectDisplayID,
        identifier: DisplayIdentifier,
        name: String,
        isBuiltIn: Bool,
        isVirtual: Bool = false,
        isMain: Bool,
        isOnline: Bool,
        isEnabled: Bool,
        isMirrored: Bool = false,
        mirrorMasterID: CGDirectDisplayID? = nil,
        rotation: Int = 0,
        supportsHDR: Bool = false,
        isHDREnabled: Bool = false,
        currentMode: DisplayModeInfo? = nil,
        availableModes: [DisplayModeInfo] = [],
        supportsDDC: Bool = false,
        supportsRotation: Bool = true
    ) {
        self.id = id
        self.identifier = identifier
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.isVirtual = isVirtual
        self.isMain = isMain
        self.isOnline = isOnline
        self.isEnabled = isEnabled
        self.isMirrored = isMirrored
        self.mirrorMasterID = mirrorMasterID
        self.rotation = rotation
        self.supportsHDR = supportsHDR
        self.isHDREnabled = isHDREnabled
        self.currentMode = currentMode
        self.availableModes = availableModes
        self.supportsDDC = supportsDDC
        self.supportsRotation = supportsRotation
    }
}

// MARK: - DDCInputSource

public struct DDCInputSource: Codable, Hashable, Identifiable, Sendable {
    public let rawValue: UInt16
    public let displayName: String

    public var id: UInt16 { rawValue }

    public init(rawValue: UInt16, displayName: String? = nil) {
        self.rawValue = rawValue
        if let displayName = displayName {
            self.displayName = displayName
        } else {
            switch rawValue {
            case 0x0F: self.displayName = "DisplayPort 1"
            case 0x10: self.displayName = "DisplayPort 2"
            case 0x11: self.displayName = "HDMI 1"
            case 0x12: self.displayName = "HDMI 2"
            case 0x1B: self.displayName = "USB-C"
            default: self.displayName = "Input (0x\(String(format: "%02X", rawValue)))"
            }
        }
    }

    public static let displayPort1 = DDCInputSource(rawValue: 0x0F, displayName: "DisplayPort 1")
    public static let displayPort2 = DDCInputSource(rawValue: 0x10, displayName: "DisplayPort 2")
    public static let hdmi1 = DDCInputSource(rawValue: 0x11, displayName: "HDMI 1")
    public static let hdmi2 = DDCInputSource(rawValue: 0x12, displayName: "HDMI 2")
    public static let usbC = DDCInputSource(rawValue: 0x1B, displayName: "USB-C")

    public static func custom(_ value: UInt16, name: String? = nil) -> DDCInputSource {
        DDCInputSource(rawValue: value, displayName: name)
    }

    public static let allPresets: [DDCInputSource] = [
        .displayPort1,
        .displayPort2,
        .hdmi1,
        .hdmi2,
        .usbC
    ]
}

// MARK: - MonitorProfile

public struct MonitorProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: String { identifier.storageKey }

    public var identifier: DisplayIdentifier
    public var displayName: String
    public var targetWidth: Int
    public var targetHeight: Int
    public var targetPixelWidth: Int
    public var targetPixelHeight: Int
    public var targetRefreshRate: Double
    public var targetIsHiDPI: Bool
    public var hdrEnabled: Bool
    public var combinedBrightness: Double // 0.0 ... 1.0
    public var ddcVolume: Int // 0 ... 100
    public var isMuted: Bool
    public var isMainDisplay: Bool
    public var builtInDisplayEnabled: Bool
    public var rotation: Int // 0, 90, 180, 270
    public var preferredInputSource: DDCInputSource?
    public var autoRestoreOnConnect: Bool
    public var autoDisableBuiltInOnConnect: Bool
    public var updatedAt: Date

    public init(
        identifier: DisplayIdentifier,
        displayName: String,
        targetWidth: Int,
        targetHeight: Int,
        targetPixelWidth: Int,
        targetPixelHeight: Int,
        targetRefreshRate: Double,
        targetIsHiDPI: Bool,
        hdrEnabled: Bool = false,
        combinedBrightness: Double = 0.8,
        ddcVolume: Int = 50,
        isMuted: Bool = false,
        isMainDisplay: Bool = false,
        builtInDisplayEnabled: Bool = true,
        rotation: Int = 0,
        preferredInputSource: DDCInputSource? = nil,
        autoRestoreOnConnect: Bool = true,
        autoDisableBuiltInOnConnect: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
        self.targetPixelWidth = targetPixelWidth
        self.targetPixelHeight = targetPixelHeight
        self.targetRefreshRate = targetRefreshRate
        self.targetIsHiDPI = targetIsHiDPI
        self.hdrEnabled = hdrEnabled
        self.combinedBrightness = combinedBrightness
        self.ddcVolume = ddcVolume
        self.isMuted = isMuted
        self.isMainDisplay = isMainDisplay
        self.builtInDisplayEnabled = builtInDisplayEnabled
        self.rotation = rotation
        self.preferredInputSource = preferredInputSource
        self.autoRestoreOnConnect = autoRestoreOnConnect
        self.autoDisableBuiltInOnConnect = autoDisableBuiltInOnConnect
        self.updatedAt = updatedAt
    }
}

// MARK: - BrightnessMethod

public enum BrightnessMethod: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case ddc
    case ddcWithDimming
    case softwareHDR
    case softwareFallback
    case nativeBuiltIn

    public var badgeText: String {
        switch self {
        case .ddc:
            return "DDC"
        case .ddcWithDimming:
            return "DDC + Dim"
        case .softwareHDR:
            return "Software HDR"
        case .softwareFallback:
            return "Software"
        case .nativeBuiltIn:
            return "Built-in"
        }
    }
}

// MARK: - NightShiftConfig

public struct NightShiftConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var scheduleEnabled: Bool
    public var startHour: Int
    public var startMinute: Int
    public var endHour: Int
    public var endMinute: Int
    public var warmth: Double
    public var transitionMinutes: Int
    public var applySoftwareFallbackInHDR: Bool
    public var timeZoneIdentifier: String?

    public init(
        enabled: Bool = false,
        scheduleEnabled: Bool = true,
        startHour: Int = 18,
        startMinute: Int = 0,
        endHour: Int = 5,
        endMinute: Int = 0,
        warmth: Double = 0.5,
        transitionMinutes: Int = 20,
        applySoftwareFallbackInHDR: Bool = true,
        timeZoneIdentifier: String? = nil
    ) {
        self.enabled = enabled
        self.scheduleEnabled = scheduleEnabled
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
        self.warmth = warmth
        self.transitionMinutes = transitionMinutes
        self.applySoftwareFallbackInHDR = applySoftwareFallbackInHDR
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

// MARK: - ShortcutAction & KeyCombo

public enum ShortcutAction: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case toggleBuiltIn
    case toggleHDR
    case toggleNightShift
    case emergencyRestore

    public var displayName: String {
        switch self {
        case .toggleBuiltIn:
            return "Toggle Built-in Display"
        case .toggleHDR:
            return "Toggle HDR Mode"
        case .toggleNightShift:
            return "Toggle Night Shift"
        case .emergencyRestore:
            return "Emergency Restore All Displays"
        }
    }
}

public struct KeyCombo: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var displayString: String

    public init(keyCode: UInt32, modifiers: UInt32, displayString: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.displayString = displayString
    }

    /// Default: ⌃⌥⌘R (Control + Option + Command + R)
    /// Key code 15 is 'r' / 'R' in macOS Virtual Key Codes (kVK_ANSI_R)
    /// Modifiers: Control (0x40000 / NSEvent 0x40000), Option (0x80000), Command (0x100000)
    public static let emergencyRestoreDefault = KeyCombo(
        keyCode: 15,
        modifiers: 0x1C0000,
        displayString: "⌃⌥⌘R"
    )
}

// MARK: - MultiMonitorBrightnessTarget

public enum MultiMonitorBrightnessTarget: String, Codable, Equatable, Sendable, CaseIterable {
    case cursorDisplay
    case syncAll

    public var displayName: String {
        switch self {
        case .cursorDisplay:
            return "Display Under Cursor"
        case .syncAll:
            return "Synchronize All Displays"
        }
    }
}

// MARK: - OSDItem

public struct OSDItem: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case brightness
        case volume
        case mute
        case notice
    }

    public let kind: Kind
    public let value: Double? // 0.0 ... 1.0 for brightness and volume
    public let isMuted: Bool
    public let title: String
    public let subtitle: String?
    public let displayID: CGDirectDisplayID?

    public init(
        kind: Kind,
        value: Double? = nil,
        isMuted: Bool = false,
        title: String,
        subtitle: String? = nil,
        displayID: CGDirectDisplayID? = nil
    ) {
        self.kind = kind
        self.value = value
        self.isMuted = isMuted
        self.title = title
        self.subtitle = subtitle
        self.displayID = displayID
    }
}

// MARK: - DDCCapabilityReport

public struct DDCCapabilityReport: Codable, Equatable, Sendable {
    public let displayID: CGDirectDisplayID
    public let displayName: String
    public let hasIOAVService: Bool
    public let supportsLuminance: Bool
    public let currentLuminance: UInt16?
    public let supportsVolume: Bool
    public let currentVolume: UInt16?
    public let supportsInputSource: Bool
    public let currentInputSource: DDCInputSource?
    public let probeError: String?

    public init(
        displayID: CGDirectDisplayID,
        displayName: String,
        hasIOAVService: Bool,
        supportsLuminance: Bool = false,
        currentLuminance: UInt16? = nil,
        supportsVolume: Bool = false,
        currentVolume: UInt16? = nil,
        supportsInputSource: Bool = false,
        currentInputSource: DDCInputSource? = nil,
        probeError: String? = nil
    ) {
        self.displayID = displayID
        self.displayName = displayName
        self.hasIOAVService = hasIOAVService
        self.supportsLuminance = supportsLuminance
        self.currentLuminance = currentLuminance
        self.supportsVolume = supportsVolume
        self.currentVolume = currentVolume
        self.supportsInputSource = supportsInputSource
        self.currentInputSource = currentInputSource
        self.probeError = probeError
    }
}

// MARK: - AppSettings

public struct AppSettings: Codable, Equatable, Sendable {
    public var launchAtLogin: Bool
    public var brightnessTarget: MultiMonitorBrightnessTarget
    public var showOSD: Bool
    public var osdDurationSeconds: Double
    public var nightShift: NightShiftConfig
    public var shortcuts: [ShortcutAction: KeyCombo]

    public init(
        launchAtLogin: Bool = false,
        brightnessTarget: MultiMonitorBrightnessTarget = .cursorDisplay,
        showOSD: Bool = true,
        osdDurationSeconds: Double = 1.8,
        nightShift: NightShiftConfig = NightShiftConfig(),
        shortcuts: [ShortcutAction: KeyCombo] = [
            .emergencyRestore: .emergencyRestoreDefault
        ]
    ) {
        self.launchAtLogin = launchAtLogin
        self.brightnessTarget = brightnessTarget
        self.showOSD = showOSD
        self.osdDurationSeconds = osdDurationSeconds
        self.nightShift = nightShift
        self.shortcuts = shortcuts
    }

    public static let `default` = AppSettings()
}
