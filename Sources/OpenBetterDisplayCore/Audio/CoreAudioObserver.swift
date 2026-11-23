import CoreAudio
import CoreGraphics
import Foundation

// MARK: - AudioOutputDeviceInfo

public struct AudioOutputDeviceInfo: Equatable, Sendable {
    public let deviceID: AudioDeviceID
    public let name: String
    public let uid: String
    public let transportType: UInt32

    public init(deviceID: AudioDeviceID, name: String, uid: String, transportType: UInt32) {
        self.deviceID = deviceID
        self.name = name
        self.uid = uid
        self.transportType = transportType
    }

    /// Four-character transport code, e.g. `"hdmi"`, `"dprt"`, `"bltn"`.
    public var transportCode: String {
        let bytes = [24, 16, 8, 0].map { UInt8((transportType >> UInt32($0)) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? String(transportType)
    }
}

// MARK: - CoreAudioObserver

/// Observes macOS's default output device and decides whether it belongs to a given external monitor.
///
/// Strict separation from macOS audio routing (SPEC §3.6): only DisplayPort / HDMI / Thunderbolt devices
/// that match the target display are reported as monitor audio. Built-in speakers, the headphone jack,
/// Bluetooth, USB, AirPlay, aggregate and virtual devices always return `false`.
public final class CoreAudioObserver: AudioBackendProtocol, @unchecked Sendable {
    public typealias DisplayNameProvider = @Sendable (CGDirectDisplayID) -> String?

    private let displayNameProvider: DisplayNameProvider
    private let callbackQueue: DispatchQueue
    private let listenerQueue = DispatchQueue(label: "com.piszeprogramy.openbetterdisplay.audio")

    private let lock = NSLock()
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var onChange: (@Sendable () -> Void)?

    /// - Parameters:
    ///   - displayNameProvider: product name lookup (defaults to CoreDisplay's EDID product name).
    ///   - callbackQueue: queue on which `onChange` is invoked (defaults to main).
    public init(displayNameProvider: DisplayNameProvider? = nil, callbackQueue: DispatchQueue = .main) {
        self.displayNameProvider = displayNameProvider ?? { CoreDisplayBridge.shared.productName(displayID: $0) }
        self.callbackQueue = callbackQueue
    }

    deinit {
        stopObservingAudioOutputChanges()
    }

    // MARK: Device queries

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    public static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = defaultOutputAddress
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func transportType(_ deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return kAudioDeviceTransportTypeUnknown }
        return value
    }

    public static func deviceInfo(_ deviceID: AudioDeviceID) -> AudioOutputDeviceInfo {
        AudioOutputDeviceInfo(
            deviceID: deviceID,
            name: stringProperty(deviceID, kAudioObjectPropertyName) ?? "",
            uid: stringProperty(deviceID, kAudioDevicePropertyDeviceUID) ?? "",
            transportType: transportType(deviceID)
        )
    }

    public func defaultOutputDevice() -> AudioOutputDeviceInfo? {
        Self.defaultOutputDeviceID().map(Self.deviceInfo)
    }

    // MARK: Pure matching (unit-testable)

    /// Only display-attached transports qualify as monitor audio.
    public static func isDisplayTransport(_ transportType: UInt32) -> Bool {
        transportType == kAudioDeviceTransportTypeDisplayPort ||
            transportType == kAudioDeviceTransportTypeHDMI ||
            transportType == kAudioDeviceTransportTypeThunderbolt
    }

    /// EDID-derived identity fragments as they appear in display audio device UIDs
    /// (e.g. `4C2D5270-...` = vendor `0x4C2D` big-endian + product `0x7052` little-endian).
    public static func edidUIDFragments(vendor: UInt32, model: UInt32) -> [String] {
        let vBE = String(format: "%02X%02X", (vendor >> 8) & 0xFF, vendor & 0xFF)
        let vLE = String(format: "%02X%02X", vendor & 0xFF, (vendor >> 8) & 0xFF)
        let mBE = String(format: "%02X%02X", (model >> 8) & 0xFF, model & 0xFF)
        let mLE = String(format: "%02X%02X", model & 0xFF, (model >> 8) & 0xFF)
        return [vBE + mLE, vBE + mBE, vLE + mLE, vLE + mBE].uniqued()
    }

    /// Decides whether `device` is the audio endpoint of the display identified by `vendor`/`model`/`displayName`.
    ///
    /// 1. Transport must be DisplayPort / HDMI / Thunderbolt (otherwise always `false`).
    /// 2. Device UID containing the display's EDID vendor/product fragment → `true`.
    /// 3. Device name equal to / containing the display product name → `true`.
    /// 4. Fallback: exactly one external display is connected → `true`.
    public static func deviceMatchesDisplay(
        device: AudioOutputDeviceInfo,
        isBuiltInDisplay: Bool,
        vendor: UInt32,
        model: UInt32,
        displayName: String?,
        externalDisplayCount: Int
    ) -> Bool {
        guard !isBuiltInDisplay, isDisplayTransport(device.transportType) else { return false }

        let compactUID = device.uid.uppercased().replacingOccurrences(of: "-", with: "")
        if vendor != 0 || model != 0, edidUIDFragments(vendor: vendor, model: model).contains(where: { compactUID.contains($0) }) {
            return true
        }

        func normalize(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        if let displayName {
            let a = normalize(displayName)
            let b = normalize(device.name)
            if !a.isEmpty, !b.isEmpty, a == b || (a.count >= 3 && b.contains(a)) || (b.count >= 3 && a.contains(b)) {
                return true
            }
        }
        return externalDisplayCount == 1
    }

    // MARK: AudioBackendProtocol

    public func isMonitorDefaultOutputDevice(displayID: CGDirectDisplayID) -> Bool {
        guard CGDisplayIsBuiltin(displayID) != 1, let device = defaultOutputDevice() else { return false }
        let externalCount = DisplayManager.onlineDisplayIDs().filter { CGDisplayIsBuiltin($0) != 1 }.count
        return Self.deviceMatchesDisplay(
            device: device,
            isBuiltInDisplay: false,
            vendor: CGDisplayVendorNumber(displayID),
            model: CGDisplayModelNumber(displayID),
            displayName: displayNameProvider(displayID),
            externalDisplayCount: externalCount
        )
    }

    public func defaultOutputDeviceName() -> String? {
        guard let name = defaultOutputDevice()?.name, !name.isEmpty else { return nil }
        return name
    }

    public func startObservingAudioOutputChanges(onChange: @escaping @Sendable () -> Void) {
        lock.lock()
        self.onChange = onChange
        guard listenerBlock == nil else {
            lock.unlock()
            return
        }
        let callbackQueue = self.callbackQueue
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.lock.lock()
            let handler = self.onChange
            self.lock.unlock()
            if let handler { callbackQueue.async { handler() } }
        }
        var address = Self.defaultOutputAddress
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, block)
        if status == noErr { listenerBlock = block }
        lock.unlock()
    }

    public func stopObservingAudioOutputChanges() {
        lock.lock()
        let block = listenerBlock
        listenerBlock = nil
        onChange = nil
        lock.unlock()

        guard let block else { return }
        var address = Self.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, block)
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
