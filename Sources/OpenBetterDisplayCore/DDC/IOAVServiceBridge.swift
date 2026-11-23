import CoreGraphics
import Foundation
import IOKit

// MARK: - DDC/CI packet framing (pure, deterministic, unit-testable)

/// DDC/CI constants and pure packet helpers matching the framing used by the MIT-licensed
/// `Arm64DDC` (MonitorControl) and `m1ddc` projects for Apple Silicon `IOAVService` I²C transfers.
public enum DDCPacket {
    /// 7-bit I²C address of the DDC/CI display endpoint.
    public static let chipAddress: UInt32 = 0x37
    /// Host (source) address / data address used for `IOAVServiceWriteI2C` / `IOAVServiceReadI2C`.
    public static let dataAddress: UInt32 = 0x51
    /// Destination address byte (display, write) folded into checksums.
    public static let destinationAddress: UInt8 = 0x6E
    /// Virtual host address folded into reply checksums.
    public static let replyChecksumSeed: UInt8 = 0x50
    /// Length of a VCP feature reply read from the display.
    public static let replyLength = 11

    public static let opcodeGetVCP: UInt8 = 0x01
    public static let opcodeVCPReply: UInt8 = 0x02
    public static let opcodeSetVCP: UInt8 = 0x03

    /// XOR checksum of `seed` and every byte in `bytes`.
    public static func checksum(seed: UInt8, bytes: [UInt8]) -> UInt8 {
        bytes.reduce(seed) { $0 ^ $1 }
    }

    /// Builds a "Set VCP Feature" packet:
    /// `[0x84, 0x03, vcp, valueHigh, valueLow, checksum]`, checksum = `0x6E ^ 0x51 ^ bytes...`.
    public static func makeDDCWritePacket(vcp: UInt8, value: UInt16) -> [UInt8] {
        var packet: [UInt8] = [0x80 | 0x04, opcodeSetVCP, vcp, UInt8(value >> 8), UInt8(value & 0xFF)]
        packet.append(checksum(seed: destinationAddress ^ UInt8(dataAddress), bytes: packet))
        return packet
    }

    /// Builds a "Get VCP Feature" request packet:
    /// `[0x82, 0x01, vcp, checksum]`, checksum = `0x6E ^ bytes...`.
    public static func makeDDCReadPacket(vcp: UInt8) -> [UInt8] {
        var packet: [UInt8] = [0x80 | 0x02, opcodeGetVCP, vcp]
        packet.append(checksum(seed: destinationAddress, bytes: packet))
        return packet
    }

    /// Parses a "Get VCP Feature Reply":
    /// `[0x6E, 0x88, 0x02, result, vcp, type, maxHi, maxLo, curHi, curLo, checksum]`,
    /// checksum = `0x50 ^ bytes[0..<10]`.
    ///
    /// Returns `nil` when the packet is too short, the checksum mismatches, the opcode is not a VCP reply,
    /// the display reports an error/unsupported result code, or the VCP code differs from `expectedVCP`.
    public static func parseDDCReplyPacket(_ bytes: [UInt8], expectedVCP: UInt8? = nil) -> DDCReply? {
        guard bytes.count >= replyLength else { return nil }
        let reply = Array(bytes.prefix(replyLength))
        guard checksum(seed: replyChecksumSeed, bytes: Array(reply[0..<(replyLength - 1)])) == reply[replyLength - 1] else {
            return nil
        }
        guard reply[2] == opcodeVCPReply, reply[3] == 0x00 else { return nil }
        if let expectedVCP, reply[4] != expectedVCP { return nil }
        return DDCReply(
            vcp: reply[4],
            typeCode: reply[5],
            maxValue: UInt16(reply[6]) << 8 | UInt16(reply[7]),
            currentValue: UInt16(reply[8]) << 8 | UInt16(reply[9])
        )
    }

    /// Normalizes a raw VCP value to `0 ... 100` using `maxValue` (treating `maxValue == 0` as 100).
    public static func normalize(raw: UInt16, maxValue: UInt16) -> UInt16 {
        let maxV = maxValue == 0 ? 100 : UInt32(maxValue)
        let clamped = min(UInt32(raw), maxV)
        return UInt16((Double(clamped) * 100 / Double(maxV)).rounded())
    }

    /// Converts a `0 ... 100` value to the raw VCP range using `maxValue` (treating `maxValue == 0` as 100).
    public static func denormalize(percent: UInt16, maxValue: UInt16) -> UInt16 {
        let maxV = maxValue == 0 ? 100 : Double(maxValue)
        let p = Double(min(percent, 100))
        return UInt16((p * maxV / 100).rounded())
    }
}

/// Decoded VCP feature reply.
public struct DDCReply: Equatable, Sendable {
    public let vcp: UInt8
    public let typeCode: UInt8
    public let maxValue: UInt16
    public let currentValue: UInt16

    public init(vcp: UInt8, typeCode: UInt8, maxValue: UInt16, currentValue: UInt16) {
        self.vcp = vcp
        self.typeCode = typeCode
        self.maxValue = maxValue
        self.currentValue = currentValue
    }
}

// MARK: - IOAVService external display candidate

/// Attributes of an external Apple Silicon framebuffer (`AppleCLCD2` / `IOMobileFramebufferShim`) paired
/// with its `DCPAVServiceProxy`, as found in the IORegistry.
public struct AVServiceCandidate: Equatable, Sendable {
    public let vendorID: UInt32?
    public let productID: UInt32?
    public let serialNumber: UInt32?
    public let productName: String?
    public let edidUUID: String?
    public let registryEntryID: UInt64

    public init(vendorID: UInt32?, productID: UInt32?, serialNumber: UInt32?, productName: String?, edidUUID: String?, registryEntryID: UInt64) {
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.productName = productName
        self.edidUUID = edidUUID
        self.registryEntryID = registryEntryID
    }

    /// Matching score against a CoreGraphics display identity (higher is better, 0 = no evidence).
    /// Pure so it can be unit tested.
    public static func matchScore(
        candidate: AVServiceCandidate,
        vendor: UInt32,
        model: UInt32,
        serial: UInt32,
        name: String?
    ) -> Int {
        var score = 0
        if let v = candidate.vendorID {
            if v == vendor { score += 1 } else { return 0 }
        }
        if let p = candidate.productID {
            if p == model { score += 1 } else { return 0 }
        }
        if let s = candidate.serialNumber, serial != 0, s != 0 {
            if s == serial { score += 2 } else { return 0 }
        }
        if let uuid = candidate.edidUUID?.uppercased(), uuid.count >= 8 {
            // EDID UUID starts with EDID bytes 8..11: vendor (big endian) + product (little endian).
            let prefix = String(format: "%04X%02X%02X", vendor & 0xFFFF, model & 0xFF, (model >> 8) & 0xFF)
            if uuid.replacingOccurrences(of: "-", with: "").hasPrefix(prefix) { score += 1 }
        }
        if let n = candidate.productName, let name, !n.isEmpty, n.caseInsensitiveCompare(name) == .orderedSame {
            score += 1
        }
        return score
    }
}

// MARK: - IOAVServiceBridge

/// Dynamically resolved `IOAVService` I²C bridge used for DDC/CI on Apple Silicon.
///
/// Maps `CGDirectDisplayID` → `IOAVService` by walking the IORegistry for external framebuffers
/// (`AppleCLCD2` / `IOMobileFramebufferShim` with `DisplayAttributes.ProductAttributes`) followed by their
/// `DCPAVServiceProxy` (`Location == "External"`), with a single-external-display fallback.
public final class IOAVServiceBridge: @unchecked Sendable {
    public static let shared = IOAVServiceBridge()

    static let ioKitPath = "/System/Library/Frameworks/IOKit.framework/IOKit"

    /// `IOAVServiceRef IOAVServiceCreateWithService(CFAllocatorRef, io_service_t)` (+1 retained)
    typealias CreateWithServiceFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    /// `IOReturn IOAVServiceReadI2C(IOAVServiceRef, uint32 chip, uint32 offset, void *buf, uint32 len)`
    typealias ReadI2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    /// `IOReturn IOAVServiceWriteI2C(IOAVServiceRef, uint32 chip, uint32 dataAddress, void *buf, uint32 len)`
    typealias WriteI2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private let createWithService: CreateWithServiceFn?
    private let readI2CFn: ReadI2CFn?
    private let writeI2CFn: WriteI2CFn?

    private let lock = NSLock()
    /// displayID → service (or `nil` meaning "looked up, none found").
    private var cache: [CGDirectDisplayID: CFTypeRef?] = [:]

    private init() {
        let ioKit = DynamicLibrary.open(IOAVServiceBridge.ioKitPath)
        func sym(_ name: String) -> UnsafeMutableRawPointer? {
            ioKit?.symbol(name) ?? DynamicLibrary.globalSymbol(name)
        }
        createWithService = sym("IOAVServiceCreateWithService").map { unsafeBitCast($0, to: CreateWithServiceFn.self) }
        readI2CFn = sym("IOAVServiceReadI2C").map { unsafeBitCast($0, to: ReadI2CFn.self) }
        writeI2CFn = sym("IOAVServiceWriteI2C").map { unsafeBitCast($0, to: WriteI2CFn.self) }
    }

    public var isAvailable: Bool {
        createWithService != nil && readI2CFn != nil && writeI2CFn != nil
    }

    // MARK: Cache

    /// Drops all cached services (call on display reconfiguration / hotplug).
    public func invalidateCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    public func invalidateCache(displayID: CGDirectDisplayID) {
        lock.lock()
        cache.removeValue(forKey: displayID)
        lock.unlock()
    }

    /// Whether an `IOAVService` exists for the display (cheap after the first lookup).
    public func hasService(for displayID: CGDirectDisplayID) -> Bool {
        service(for: displayID) != nil
    }

    // MARK: Service lookup

    /// Returns the cached or freshly matched `IOAVService` for an external display.
    public func service(for displayID: CGDirectDisplayID) -> CFTypeRef? {
        guard isAvailable, CGDisplayIsBuiltin(displayID) != 1 else { return nil }
        lock.lock()
        if let cached = cache[displayID] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = resolveService(for: displayID)

        lock.lock()
        cache[displayID] = .some(resolved)
        lock.unlock()
        return resolved
    }

    private func resolveService(for displayID: CGDirectDisplayID) -> CFTypeRef? {
        let entries = scanRegistry()
        guard !entries.isEmpty else { return nil }

        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)
        let name = CoreDisplayBridge.shared.productName(displayID: displayID)

        var best: (score: Int, service: CFTypeRef)?
        for entry in entries {
            let score = AVServiceCandidate.matchScore(candidate: entry.candidate, vendor: vendor, model: model, serial: serial, name: name)
            if score > 0, score > (best?.score ?? 0) {
                best = (score, entry.service)
            }
        }
        if let best { return best.service }

        // Fallback: exactly one external display online and exactly one external AV service proxy.
        let externalOnline = Self.onlineDisplayIDs().filter { CGDisplayIsBuiltin($0) != 1 }
        if externalOnline.count == 1, externalOnline.first == displayID, entries.count == 1 {
            return entries[0].service
        }
        return nil
    }

    private struct RegistryEntry {
        let candidate: AVServiceCandidate
        let service: CFTypeRef
    }

    /// Walks the IOService plane in order, pairing each external framebuffer with the next
    /// external `DCPAVServiceProxy` and creating an `IOAVService` for it.
    private func scanRegistry() -> [RegistryEntry] {
        guard let create = createWithService else { return [] }
        var iterator: io_iterator_t = 0
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var results: [RegistryEntry] = []
        var pendingFramebuffer: AVServiceCandidate?
        var nameBuffer = [CChar](repeating: 0, count: 128)

        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }

            guard IORegistryEntryGetName(entry, &nameBuffer) == KERN_SUCCESS else { continue }
            let name = String(cString: nameBuffer)

            if name == "AppleCLCD2" || name == "IOMobileFramebufferShim" {
                pendingFramebuffer = Self.framebufferCandidate(entry)
            } else if name == "DCPAVServiceProxy" {
                let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String
                guard location == "External" else { continue }
                guard let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
                var entryID: UInt64 = 0
                IORegistryEntryGetRegistryEntryID(entry, &entryID)
                let candidate = pendingFramebuffer ?? AVServiceCandidate(
                    vendorID: nil, productID: nil, serialNumber: nil, productName: nil, edidUUID: nil, registryEntryID: entryID
                )
                results.append(RegistryEntry(candidate: candidate, service: service))
                pendingFramebuffer = nil
            }
        }
        return results
    }

    private static func framebufferCandidate(_ entry: io_registry_entry_t) -> AVServiceCandidate? {
        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        if let external = property("external") as? Bool, external == false { return nil }
        let attributes = property("DisplayAttributes") as? [String: Any]
        let product = attributes?["ProductAttributes"] as? [String: Any]
        func uint32(_ value: Any?) -> UInt32? {
            (value as? NSNumber).map { UInt32(truncatingIfNeeded: $0.int64Value) }
        }
        var entryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &entryID)
        let candidate = AVServiceCandidate(
            vendorID: uint32(product?["LegacyManufacturerID"]),
            productID: uint32(product?["ProductID"]),
            serialNumber: uint32(product?["SerialNumber"]),
            productName: product?["ProductName"] as? String,
            edidUUID: property("EDID UUID") as? String,
            registryEntryID: entryID
        )
        if candidate.vendorID == nil, candidate.productID == nil, candidate.edidUUID == nil { return nil }
        return candidate
    }

    static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    // MARK: Raw I²C

    /// Writes `bytes` to the display's DDC/CI endpoint. Returns `true` on `kIOReturnSuccess`.
    public func writeI2C(service: CFTypeRef, bytes: [UInt8]) -> Bool {
        guard let fn = writeI2CFn, !bytes.isEmpty else { return false }
        var buffer = bytes
        let result = buffer.withUnsafeMutableBytes { raw -> IOReturn in
            guard let base = raw.baseAddress else { return kIOReturnBadArgument }
            return fn(service, DDCPacket.chipAddress, DDCPacket.dataAddress, base, UInt32(raw.count))
        }
        return result == kIOReturnSuccess
    }

    /// Reads `length` bytes from the display's DDC/CI endpoint.
    public func readI2C(service: CFTypeRef, length: Int) -> [UInt8]? {
        guard let fn = readI2CFn, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        let result = buffer.withUnsafeMutableBytes { raw -> IOReturn in
            guard let base = raw.baseAddress else { return kIOReturnBadArgument }
            return fn(service, DDCPacket.chipAddress, DDCPacket.dataAddress, base, UInt32(raw.count))
        }
        return result == kIOReturnSuccess ? buffer : nil
    }
}
