import XCTest
import CoreGraphics
@testable import OpenBetterDisplayCore

// MARK: - Test doubles (file-private)

fileprivate final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [String] = []

    func add(_ entry: String) {
        lock.lock(); defer { lock.unlock() }
        _entries.append(entry)
    }

    var entries: [String] {
        lock.lock(); defer { lock.unlock() }
        return _entries
    }

    func count(prefix: String) -> Int {
        entries.filter { $0.hasPrefix(prefix) }.count
    }
}

fileprivate final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [ProfileHotplugEvent] = []

    func add(_ event: ProfileHotplugEvent) {
        lock.lock(); defer { lock.unlock() }
        _events.append(event)
    }

    var events: [ProfileHotplugEvent] {
        lock.lock(); defer { lock.unlock() }
        return _events
    }
}

fileprivate final class MockDisplayBackend: DisplayBackendProtocol, @unchecked Sendable {
    let log: CallLog
    private let lock = NSLock()
    private var _displays: [DisplayInfo] = []
    private var _builtInEnabled = true
    private var _hdr: [CGDirectDisplayID: Bool] = [:]
    private var _enumerations = 0
    private var _builtInDisableFailuresRemaining = 0

    init(log: CallLog) { self.log = log }

    var displays: [DisplayInfo] {
        get { lock.lock(); defer { lock.unlock() }; return _displays }
        set { lock.lock(); defer { lock.unlock() }; _displays = newValue }
    }

    var builtInEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _builtInEnabled }
        set { lock.lock(); defer { lock.unlock() }; _builtInEnabled = newValue }
    }

    var builtInDisableFailuresRemaining: Int {
        get { lock.lock(); defer { lock.unlock() }; return _builtInDisableFailuresRemaining }
        set { lock.lock(); defer { lock.unlock() }; _builtInDisableFailuresRemaining = newValue }
    }

    var enumerationCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _enumerations
    }

    func getOnlineDisplays() -> [DisplayInfo] {
        lock.lock(); defer { lock.unlock() }
        _enumerations += 1
        return _displays
    }

    func setBuiltInDisplayEnabled(_ enabled: Bool) throws {
        if !enabled {
            let shouldFail: Bool = {
                lock.lock(); defer { lock.unlock() }
                if _builtInDisableFailuresRemaining > 0 {
                    _builtInDisableFailuresRemaining -= 1
                    return true
                }
                return false
            }()
            if shouldFail {
                log.add("builtIn:false:failed")
                throw DisplayError.configurationFailed(-1)
            }
        }
        log.add("builtIn:\(enabled)")
        builtInEnabled = enabled
    }

    func isBuiltInDisplayEnabled() -> Bool { builtInEnabled }

    func setDisplayMode(displayID: CGDirectDisplayID, mode: DisplayModeInfo) throws {
        log.add("mode:\(mode.width)x\(mode.height)@\(Int(mode.refreshRate))\(mode.isHiDPI ? "hidpi" : "")")
    }

    func setMainDisplay(displayID: CGDirectDisplayID) throws { log.add("main:\(displayID)") }
    func setDisplayMirror(displayID: CGDirectDisplayID, mirrorOf: CGDirectDisplayID?) throws { log.add("mirror") }
    func setDisplayRotation(displayID: CGDirectDisplayID, rotation: Int) throws { log.add("rotation:\(rotation)") }

    func setHDREnabled(displayID: CGDirectDisplayID, enabled: Bool) throws {
        log.add("hdr:\(enabled)")
        lock.lock(); _hdr[displayID] = enabled; lock.unlock()
    }

    func isHDREnabled(displayID: CGDirectDisplayID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let value = _hdr[displayID] { return value }
        return _displays.first(where: { $0.id == displayID })?.isHDREnabled ?? false
    }

    func emergencyRestoreAllDisplays() throws { log.add("emergency") }
}

fileprivate final class MockDDCBackend: DDCBackendProtocol, @unchecked Sendable {
    let log: CallLog
    var brightness: UInt16? = 70
    var volume: UInt16? = 20
    var mute: Bool? = true

    init(log: CallLog) { self.log = log }

    func probeCapabilities(displayID: CGDirectDisplayID) -> DDCCapabilityReport {
        DDCCapabilityReport(displayID: displayID, displayName: "mock", hasIOAVService: true)
    }
    func readBrightness(displayID: CGDirectDisplayID) -> UInt16? { log.add("ddc.readBrightness"); return brightness }
    func writeBrightness(displayID: CGDirectDisplayID, value: UInt16) -> Bool { log.add("ddc.brightness:\(value)"); return true }
    func readVolume(displayID: CGDirectDisplayID) -> UInt16? { log.add("ddc.readVolume"); return volume }
    func writeVolume(displayID: CGDirectDisplayID, value: UInt16) -> Bool { log.add("volume:\(value)"); return true }
    func readMute(displayID: CGDirectDisplayID) -> Bool? { log.add("ddc.readMute"); return mute }
    func writeMute(displayID: CGDirectDisplayID, muted: Bool) -> Bool { log.add("mute:\(muted)"); return true }
    func readInputSource(displayID: CGDirectDisplayID) -> DDCInputSource? { nil }
    func writeInputSource(displayID: CGDirectDisplayID, source: DDCInputSource) -> Bool { true }
}

// MARK: - Fixtures

fileprivate enum Fixture {
    static let ident = DisplayIdentifier(vendorNumber: 19501, modelNumber: 28754, serialNumber: 700123)

    static let m240 = DisplayModeInfo(width: 5120, height: 1440, pixelWidth: 5120, pixelHeight: 1440, refreshRate: 240, isHiDPI: false, modeIndex: 1)
    static let m120 = DisplayModeInfo(width: 5120, height: 1440, pixelWidth: 5120, pixelHeight: 1440, refreshRate: 120, isHiDPI: false, modeIndex: 2)
    static let m60 = DisplayModeInfo(width: 5120, height: 1440, pixelWidth: 5120, pixelHeight: 1440, refreshRate: 60, isHiDPI: false, modeIndex: 3)
    static let hidpi60 = DisplayModeInfo(width: 3840, height: 1080, pixelWidth: 7680, pixelHeight: 2160, refreshRate: 60, isHiDPI: true, modeIndex: 4)
    static let allModes = [m240, m120, m60, hidpi60]

    static func external(
        id: CGDirectDisplayID = 77,
        identifier: DisplayIdentifier = Fixture.ident,
        isMain: Bool = false,
        isMirrored: Bool = false,
        hdrEnabled: Bool = false,
        rotation: Int = 0,
        current: DisplayModeInfo = Fixture.m60
    ) -> DisplayInfo {
        DisplayInfo(
            id: id, identifier: identifier, name: "LC49G95T", isBuiltIn: false, isMain: isMain,
            isOnline: true, isEnabled: true, isMirrored: isMirrored, rotation: rotation,
            supportsHDR: true, isHDREnabled: hdrEnabled, currentMode: current,
            availableModes: allModes, supportsDDC: true, supportsRotation: true
        )
    }

    static func builtIn(id: CGDirectDisplayID = 1) -> DisplayInfo {
        DisplayInfo(
            id: id, identifier: DisplayIdentifier(vendorNumber: 1552, modelNumber: 41038, serialNumber: 0),
            name: "Built-in", isBuiltIn: true, isMain: false, isOnline: true, isEnabled: true,
            currentMode: m60, availableModes: [m60]
        )
    }

    /// A profile that wants everything restored differently from `external()`'s live state.
    static func fullProfile(autoRestore: Bool = true, autoDisableBuiltIn: Bool = true, builtInEnabled: Bool = false) -> MonitorProfile {
        MonitorProfile(
            identifier: ident, displayName: "LC49G95T",
            targetWidth: 5120, targetHeight: 1440, targetPixelWidth: 5120, targetPixelHeight: 1440,
            targetRefreshRate: 240, targetIsHiDPI: false,
            hdrEnabled: true, combinedBrightness: 0.4, ddcVolume: 30, isMuted: true,
            isMainDisplay: true, builtInDisplayEnabled: builtInEnabled, rotation: 90,
            autoRestoreOnConnect: autoRestore, autoDisableBuiltInOnConnect: autoDisableBuiltIn
        )
    }
}

// MARK: - Tests

@MainActor
final class ProfileStoreTests: XCTestCase {
    private var tempDir: URL!
    private var log: CallLog!
    private var backend: MockDisplayBackend!
    private var ddc: MockDDCBackend!
    private var events: EventBox!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("obd-profile-tests-\(UUID().uuidString)", isDirectory: true)
        log = CallLog()
        backend = MockDisplayBackend(log: log)
        ddc = MockDDCBackend(log: log)
        events = EventBox()
    }

    override func tearDown() async throws {
        if let dir = tempDir { try? FileManager.default.removeItem(at: dir) }
    }

    private var fileURL: URL { tempDir.appendingPathComponent("profiles.json") }

    private func makeStore(debounce: TimeInterval = 0.05, useDDC: Bool = true) -> ProfileStore {
        let log = self.log!
        let events = self.events!
        let store = ProfileStore(
            fileURL: fileURL,
            debounceInterval: debounce,
            builtInDisableRetryDelay: 0,
            displayBackend: backend,
            ddcBackend: useDDC ? ddc : nil,
            brightnessApplier: { id, level in log.add("brightness:\(id):\(level)") }
        )
        store.onHotplugEvent = { events.add($0) }
        return store
    }

    // MARK: Known monitor

    func testKnownMonitorRestoresEverythingInDeterministicOrder() async {
        let store = makeStore()
        store.saveProfile(Fixture.fullProfile())
        backend.displays = [Fixture.builtIn(), Fixture.external()]

        await store.processConnectedDisplaysNow()

        XCTAssertEqual(log.entries, [
            "mode:5120x1440@240",
            "hdr:true",
            "brightness:77:0.4",
            "volume:30",
            "mute:true",
            "main:77",
            "rotation:90",
            "builtIn:false"
        ])
        XCTAssertEqual(events.events, [.restored(storageKey: Fixture.ident.storageKey, displayName: "LC49G95T")])
    }

    func testKnownMonitorAlreadyMatchingDoesNotReapplyModeHDRMainOrRotation() async {
        let store = makeStore()
        var profile = Fixture.fullProfile(autoDisableBuiltIn: false, builtInEnabled: true)
        profile.targetRefreshRate = 60
        profile.hdrEnabled = false
        profile.isMainDisplay = true
        profile.rotation = 0
        store.saveProfile(profile)
        backend.displays = [Fixture.external(isMain: true, hdrEnabled: false, rotation: 0, current: Fixture.m60)]

        await store.processConnectedDisplaysNow()

        XCTAssertEqual(log.count(prefix: "mode:"), 0)
        XCTAssertEqual(log.count(prefix: "hdr:"), 0)
        XCTAssertEqual(log.count(prefix: "main:"), 0)
        XCTAssertEqual(log.count(prefix: "rotation:"), 0)
        XCTAssertEqual(log.count(prefix: "builtIn:"), 0)
        XCTAssertEqual(log.count(prefix: "brightness:"), 1, "brightness is always re-applied")
    }

    func testBuiltInDisabledOnlyWhenAutoDisableAndBuiltInOff() async {
        // autoDisable false, builtIn flagged off -> must NOT disable.
        var store = makeStore()
        store.saveProfile(Fixture.fullProfile(autoDisableBuiltIn: false, builtInEnabled: false))
        backend.displays = [Fixture.builtIn(), Fixture.external()]
        await store.processConnectedDisplaysNow()
        XCTAssertFalse(log.entries.contains("builtIn:false"), "auto-disable flag is off")

        // autoDisable true but profile says built-in should stay enabled -> must NOT disable.
        store.cancelPendingHotplug()
        let freshDir = tempDir.appendingPathComponent("second")
        store = ProfileStore(fileURL: freshDir.appendingPathComponent("profiles.json"), debounceInterval: 0.01, displayBackend: backend, ddcBackend: ddc)
        store.saveProfile(Fixture.fullProfile(autoDisableBuiltIn: true, builtInEnabled: true))
        await store.processConnectedDisplaysNow()
        XCTAssertFalse(log.entries.contains("builtIn:false"), "profile wants built-in enabled")
    }

    func testBuiltInReEnabledWhenProfileWantsItAndItIsOff() async {
        let store = makeStore()
        store.saveProfile(Fixture.fullProfile(autoDisableBuiltIn: false, builtInEnabled: true))
        backend.builtInEnabled = false
        backend.displays = [Fixture.external()]
        await store.processConnectedDisplaysNow()
        XCTAssertTrue(log.entries.contains("builtIn:true"))
    }

    func testRestoreSkipsDDCAudioWhenNoDDCBackend() async {
        let store = makeStore(useDDC: false)
        store.saveProfile(Fixture.fullProfile())
        backend.displays = [Fixture.external()]
        await store.processConnectedDisplaysNow()
        XCTAssertEqual(log.count(prefix: "volume:"), 0)
        XCTAssertEqual(log.count(prefix: "mute:"), 0)
    }

    // MARK: Unseen monitor

    func testUnseenMonitorCapturesDefaultsAndNeverTouchesBuiltIn() async {
        let store = makeStore()
        backend.displays = [Fixture.builtIn(), Fixture.external(isMain: true)]

        await store.processConnectedDisplaysNow()

        let profile = store.profile(for: Fixture.ident)
        XCTAssertNotNil(profile)
        XCTAssertEqual(profile?.builtInDisplayEnabled, true)
        XCTAssertEqual(profile?.autoDisableBuiltInOnConnect, false)
        XCTAssertEqual(profile?.autoRestoreOnConnect, true)
        XCTAssertEqual(profile?.combinedBrightness ?? -1, 0.70, accuracy: 0.0001)
        XCTAssertEqual(profile?.ddcVolume, 20)
        XCTAssertEqual(profile?.isMuted, true)
        XCTAssertEqual(profile?.targetWidth, 5120)
        XCTAssertEqual(profile?.targetRefreshRate, 60)
        XCTAssertEqual(profile?.isMainDisplay, true)

        // No mutations at all on an unseen monitor.
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("builtIn:") })
        XCTAssertEqual(log.count(prefix: "mode:"), 0)
        XCTAssertEqual(log.count(prefix: "hdr:"), 0)
        XCTAssertEqual(log.count(prefix: "brightness:"), 0)
        XCTAssertEqual(events.events, [.captured(storageKey: Fixture.ident.storageKey, displayName: "LC49G95T")])
    }

    func testUnseenMonitorInHDRDoesNotReadDDCBrightness() async {
        let store = makeStore()
        backend.displays = [Fixture.external(hdrEnabled: true)]
        await store.processConnectedDisplaysNow()
        XCTAssertEqual(log.count(prefix: "ddc.readBrightness"), 0)
        XCTAssertEqual(store.profile(for: Fixture.ident)?.hdrEnabled, true)
        XCTAssertEqual(store.profile(for: Fixture.ident)?.combinedBrightness ?? -1, 0.8, accuracy: 0.0001, "model default")
    }

    func testBuiltInAndMirroredDisplaysNeverGetProfiles() async {
        let store = makeStore()
        let mirrored = DisplayIdentifier(vendorNumber: 5, modelNumber: 5, serialNumber: 5)
        backend.displays = [Fixture.builtIn(), Fixture.external(id: 88, identifier: mirrored, isMirrored: true)]
        await store.processConnectedDisplaysNow()
        XCTAssertTrue(store.allProfiles().isEmpty)
        XCTAssertTrue(events.events.isEmpty)
    }

    // MARK: autoRestore == false

    func testAutoRestoreDisabledSkipsRestore() async {
        let store = makeStore()
        store.saveProfile(Fixture.fullProfile(autoRestore: false))
        backend.displays = [Fixture.external()]

        await store.processConnectedDisplaysNow()

        XCTAssertTrue(log.entries.isEmpty, "nothing must be applied: \(log.entries)")
        XCTAssertEqual(events.events, [.skippedAutoRestoreDisabled(storageKey: Fixture.ident.storageKey)])
    }

    // MARK: Debounce / loop safety

    func testRapidReconfigurationEventsAreCoalescedIntoOnePass() async {
        let store = makeStore(debounce: 0.15)
        backend.displays = [Fixture.external()]

        for _ in 0..<6 { store.handleDisplayReconfiguration() }
        XCTAssertEqual(backend.enumerationCount, 0, "nothing may run before the debounce elapses")
        XCTAssertTrue(store.isHotplugBusy)

        await store.waitUntilIdle()

        XCTAssertEqual(backend.enumerationCount, 1)
        XCTAssertEqual(events.events.count, 1)
        XCTAssertFalse(store.isHotplugBusy)
    }

    func testDefaultDebounceIntervalIsOnePointFiveSeconds() {
        XCTAssertEqual(ProfileStore.defaultDebounceInterval, 1.5)
        let store = ProfileStore(fileURL: fileURL)
        XCTAssertEqual(store.debounceInterval, 1.5)
    }

    func testCancelPendingHotplugPreventsProcessing() async {
        let store = makeStore(debounce: 0.1)
        backend.displays = [Fixture.external()]
        store.handleDisplayReconfiguration()
        store.cancelPendingHotplug()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(backend.enumerationCount, 0)
    }

    func testDoesNotLoopOnItsOwnModeChanges() async {
        let store = makeStore()
        store.saveProfile(Fixture.fullProfile())
        backend.displays = [Fixture.external()]

        await store.processConnectedDisplaysNow()
        XCTAssertEqual(log.count(prefix: "mode:"), 1)

        // Our own mode/HDR change makes macOS fire more reconfiguration callbacks.
        store.handleDisplayReconfiguration()
        await store.waitUntilIdle()
        store.handleDisplayReconfiguration()
        await store.waitUntilIdle()

        XCTAssertEqual(log.count(prefix: "mode:"), 1, "already-connected monitor must not be restored again")
        XCTAssertEqual(log.count(prefix: "hdr:"), 1)
        XCTAssertEqual(events.events.count, 1)
    }

    func testReconnectAfterUnplugRestoresAgain() async {
        let store = makeStore()
        store.saveProfile(Fixture.fullProfile())
        backend.displays = [Fixture.external()]
        await store.processConnectedDisplaysNow()
        XCTAssertEqual(log.count(prefix: "mode:"), 1)

        backend.displays = []
        await store.processConnectedDisplaysNow()
        backend.displays = [Fixture.external()]
        await store.processConnectedDisplaysNow()

        XCTAssertEqual(log.count(prefix: "mode:"), 2)
        XCTAssertEqual(events.events.count, 2)
    }

    func testUnseenMonitorIsCapturedOnlyOnce() async {
        let store = makeStore()
        backend.displays = [Fixture.external()]
        await store.processConnectedDisplaysNow()
        await store.processConnectedDisplaysNow()
        XCTAssertEqual(events.events.count, 1)
        XCTAssertEqual(log.count(prefix: "ddc.readVolume"), 1)
    }

    // MARK: Persistence

    func testPersistenceRoundTripThroughJSONFile() {
        let store = makeStore()
        var profile = Fixture.fullProfile()
        profile.preferredInputSource = .hdmi2
        store.saveProfile(profile)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let reloaded = ProfileStore(fileURL: fileURL)
        let loaded = reloaded.profile(for: Fixture.ident)
        XCTAssertEqual(loaded?.displayName, "LC49G95T")
        XCTAssertEqual(loaded?.targetRefreshRate, 240)
        XCTAssertEqual(loaded?.ddcVolume, 30)
        XCTAssertEqual(loaded?.rotation, 90)
        XCTAssertEqual(loaded?.preferredInputSource?.rawValue, 0x12)
        XCTAssertEqual(loaded?.autoDisableBuiltInOnConnect, true)
        XCTAssertEqual(loaded?.builtInDisplayEnabled, false)
        XCTAssertEqual(loaded, store.profile(for: Fixture.ident), "exact Equatable round trip incl. updatedAt")
    }

    func testProfilesAreKeyedByStorageKeyInJSON() throws {
        let store = makeStore()
        store.saveProfile(Fixture.fullProfile())
        let data = try Data(contentsOf: fileURL)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let keys: [String] = Array((object ?? [:]).keys)
        XCTAssertEqual(keys, [Fixture.ident.storageKey])
    }

    func testDeleteProfilePersists() {
        let store = makeStore()
        store.saveProfile(Fixture.fullProfile())
        XCTAssertEqual(store.allProfiles().count, 1)
        store.deleteProfile(forKey: Fixture.ident.storageKey)
        XCTAssertNil(store.profile(for: Fixture.ident))
        XCTAssertTrue(ProfileStore(fileURL: fileURL).allProfiles().isEmpty)

        // deleting an unknown key is a harmless no-op
        store.deleteProfile(forKey: "nope")
        store.saveProfile(Fixture.fullProfile())
        store.deleteAllProfiles()
        XCTAssertTrue(ProfileStore(fileURL: fileURL).allProfiles().isEmpty)
    }

    func testDeletedProfileIsTreatedAsUnseenOnNextConnect() async {
        let store = makeStore()
        store.saveProfile(Fixture.fullProfile())
        backend.displays = [Fixture.external()]
        await store.processConnectedDisplaysNow()
        store.deleteProfile(forKey: Fixture.ident.storageKey)
        // Forgetting a profile clears the "connected" marker, so the still-attached monitor is re-captured fresh.
        await store.processConnectedDisplaysNow()
        let profile = store.profile(for: Fixture.ident)
        XCTAssertEqual(profile?.autoDisableBuiltInOnConnect, false)
        XCTAssertEqual(profile?.builtInDisplayEnabled, true)
    }

    func testCorruptFileFallsBackToEmpty() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try Data("{ definitely not json".utf8).write(to: fileURL)
        XCTAssertTrue(ProfileStore(fileURL: fileURL).allProfiles().isEmpty)
    }

    func testDefaultFileURLLivesInApplicationSupport() {
        let url = ProfileStore.defaultFileURL
        XCTAssertEqual(url.lastPathComponent, "profiles.json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "openBetterDisplay")
        XCTAssertTrue(url.path.contains("Application Support"))
    }

    func testAllProfilesSortedByName() {
        let store = makeStore()
        var a = Fixture.fullProfile(); a.displayName = "zeta"
        var b = Fixture.fullProfile(); b.identifier = DisplayIdentifier(vendorNumber: 1, modelNumber: 1, serialNumber: 1); b.displayName = "Alpha"
        store.saveProfile(a)
        store.saveProfile(b)
        XCTAssertEqual(store.allProfiles().map(\.displayName), ["Alpha", "zeta"])
    }

    func testOnProfilesChangedFiresOnSaveAndDelete() {
        let store = makeStore()
        var count = 0
        store.onProfilesChanged = { count += 1 }
        store.saveProfile(Fixture.fullProfile())
        store.deleteProfile(forKey: Fixture.ident.storageKey)
        XCTAssertEqual(count, 2)
    }

    // MARK: recordCurrentState

    func testRecordCurrentStateCreatesProfileWithSafeDefaults() {
        let store = makeStore()
        let profile = store.recordCurrentState(from: Fixture.external(isMain: true, hdrEnabled: true, rotation: 180), brightness: 0.35, volume: 44, isMuted: false)
        XCTAssertEqual(profile.combinedBrightness, 0.35, accuracy: 0.0001)
        XCTAssertEqual(profile.ddcVolume, 44)
        XCTAssertFalse(profile.isMuted)
        XCTAssertTrue(profile.hdrEnabled)
        XCTAssertTrue(profile.isMainDisplay)
        XCTAssertEqual(profile.rotation, 180)
        XCTAssertTrue(profile.builtInDisplayEnabled)
        XCTAssertFalse(profile.autoDisableBuiltInOnConnect)
        XCTAssertEqual(store.profile(for: Fixture.ident), profile)
    }

    func testRecordCurrentStatePreservesUserFlagsAndClampsValues() {
        let store = makeStore()
        var existing = Fixture.fullProfile()
        existing.preferredInputSource = .usbC
        store.saveProfile(existing)

        let updated = store.recordCurrentState(from: Fixture.external(), brightness: 7, volume: -5, builtInEnabled: true)
        XCTAssertEqual(updated.combinedBrightness, 1.0)
        XCTAssertEqual(updated.ddcVolume, 0)
        XCTAssertTrue(updated.builtInDisplayEnabled)
        XCTAssertTrue(updated.autoDisableBuiltInOnConnect, "user flag preserved")
        XCTAssertTrue(updated.autoRestoreOnConnect)
        XCTAssertEqual(updated.preferredInputSource, .usbC)
        XCTAssertTrue(updated.isMuted, "nil mute keeps the stored value")
        XCTAssertEqual(updated.targetRefreshRate, 60, "mode follows live state")
    }

    // MARK: Pure helpers

    func testClosestModePrefersExactMatchThenNearestRefresh() {
        var profile = Fixture.fullProfile()
        XCTAssertEqual(ProfileStore.closestMode(for: profile, in: Fixture.allModes)?.modeIndex, 1)

        profile.targetRefreshRate = 144
        XCTAssertEqual(ProfileStore.closestMode(for: profile, in: Fixture.allModes)?.modeIndex, 2, "120 Hz is nearer to 144 than 240 Hz")

        profile.targetRefreshRate = 60
        XCTAssertEqual(ProfileStore.closestMode(for: profile, in: Fixture.allModes)?.modeIndex, 3)
    }

    func testClosestModeKeepsHiDPIPreference() {
        let nativeScaled = DisplayModeInfo(width: 3840, height: 1080, pixelWidth: 3840, pixelHeight: 1080, refreshRate: 60, isHiDPI: false, modeIndex: 10)
        let hidpi = Fixture.hidpi60
        var profile = Fixture.fullProfile()
        profile.targetWidth = 3840; profile.targetHeight = 1080
        profile.targetPixelWidth = 7680; profile.targetPixelHeight = 2160
        profile.targetRefreshRate = 60; profile.targetIsHiDPI = true
        XCTAssertEqual(ProfileStore.closestMode(for: profile, in: [nativeScaled, hidpi])?.modeIndex, 4)

        profile.targetPixelWidth = 3840; profile.targetPixelHeight = 1080; profile.targetIsHiDPI = false
        XCTAssertEqual(ProfileStore.closestMode(for: profile, in: [hidpi, nativeScaled])?.modeIndex, 10)
    }

    func testClosestModeReturnsNilForEmptyListOrEmptyTarget() {
        var profile = Fixture.fullProfile()
        XCTAssertNil(ProfileStore.closestMode(for: profile, in: []))
        profile.targetWidth = 0
        XCTAssertNil(ProfileStore.closestMode(for: profile, in: Fixture.allModes))
    }

    func testIsSameModeIgnoresModeIndexAndSubHertzNoise() {
        let a = Fixture.m60
        let b = DisplayModeInfo(width: 5120, height: 1440, pixelWidth: 5120, pixelHeight: 1440, refreshRate: 59.94, isHiDPI: false, modeIndex: 99)
        XCTAssertTrue(ProfileStore.isSameMode(a, b))
        XCTAssertFalse(ProfileStore.isSameMode(a, Fixture.m120))
        XCTAssertFalse(ProfileStore.isSameMode(a, nil))
    }

    func testMakeNewProfileNeverDisablesBuiltIn() {
        let profile = ProfileStore.makeNewProfile(from: Fixture.external(isMain: true))
        XCTAssertTrue(profile.builtInDisplayEnabled)
        XCTAssertFalse(profile.autoDisableBuiltInOnConnect)
        XCTAssertTrue(profile.autoRestoreOnConnect)
        XCTAssertEqual(profile.identifier, Fixture.ident)
    }

    // MARK: DisplayIdentifier keys

    func testDisplayIdentifierStorageKeyFallbacks() {
        XCTAssertEqual(DisplayIdentifier(vendorNumber: 1, modelNumber: 2, serialNumber: 3, uuidString: "U").storageKey, "V1_M2_S3",
                       "serial wins over UUID")
        XCTAssertEqual(DisplayIdentifier(vendorNumber: 1, modelNumber: 2, serialNumber: 0, uuidString: "ABC").storageKey, "V1_M2_UUID_ABC")
        XCTAssertEqual(DisplayIdentifier(vendorNumber: 1, modelNumber: 2, serialNumber: 0, uuidString: "").storageKey, "V1_M2",
                       "empty UUID is ignored")
        XCTAssertEqual(DisplayIdentifier(vendorNumber: 1, modelNumber: 2).storageKey, "V1_M2")
    }

    func testTwoIdenticalModelsWithDifferentSerialsHaveSeparateProfiles() async {
        let store = makeStore()
        let other = DisplayIdentifier(vendorNumber: Fixture.ident.vendorNumber, modelNumber: Fixture.ident.modelNumber, serialNumber: 700124)
        backend.displays = [Fixture.external(), Fixture.external(id: 78, identifier: other)]
        await store.processConnectedDisplaysNow()
        XCTAssertEqual(store.allProfiles().count, 2)
        XCTAssertNotNil(store.profile(for: Fixture.ident))
        XCTAssertNotNil(store.profile(for: other))
    }

    // MARK: Virtual display filtering & reconnect memory

    func testVirtualPlaceholderDisplaysAreIgnoredAndPrunedOnLoad() async throws {
        let store = makeStore()
        let virtualUnknVirt = DisplayInfo(
            id: 11,
            identifier: DisplayIdentifier(vendorNumber: 0x756E6B6E, modelNumber: 0x76697274, serialNumber: 0, uuidString: "81919CFC"),
            name: "Display 11",
            isBuiltIn: false,
            isVirtual: true,
            isMain: true,
            isOnline: true,
            isEnabled: true
        )
        let virtualAllOnes = DisplayInfo(
            id: 5,
            identifier: DisplayIdentifier(vendorNumber: UInt32.max, modelNumber: UInt32.max, serialNumber: UInt32.max),
            name: "Display 5",
            isBuiltIn: false,
            isVirtual: false, // even if caller forgot isVirtual, sentinel identifier catches it
            isMain: true,
            isOnline: true,
            isEnabled: true
        )

        backend.displays = [Fixture.builtIn(), virtualUnknVirt, virtualAllOnes]
        await store.processConnectedDisplaysNow()
        XCTAssertTrue(store.allProfiles().isEmpty, "Virtual placeholder displays must never be captured as profiles")
        XCTAssertTrue(events.events.isEmpty)

        // Manually write a legacy JSON containing a stale virtual profile + a real profile and verify load prunes the virtual one.
        let realProfile = Fixture.fullProfile()
        let staleVirtual = MonitorProfile(
            identifier: virtualUnknVirt.identifier,
            displayName: "Display 11",
            targetWidth: 1920, targetHeight: 1080, targetPixelWidth: 1920, targetPixelHeight: 1080,
            targetRefreshRate: 60, targetIsHiDPI: false
        )
        let payload: [String: MonitorProfile] = [
            realProfile.identifier.storageKey: realProfile,
            staleVirtual.identifier.storageKey: staleVirtual
        ]
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(payload).write(to: fileURL)

        let reloaded = ProfileStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.allProfiles().map(\.identifier), [realProfile.identifier])
    }

    func testAutoDisableBuiltInRetriesTransientFailureOnReconnect() async {
        let store = makeStore()
        store.saveProfile(Fixture.fullProfile(autoDisableBuiltIn: true, builtInEnabled: false))
        backend.displays = [Fixture.builtIn(), Fixture.external()]
        backend.builtInDisableFailuresRemaining = 2

        await store.processConnectedDisplaysNow()

        XCTAssertFalse(backend.builtInEnabled, "Built-in should be disabled after transient link-training retries")
        XCTAssertEqual(log.entries.filter { $0 == "builtIn:false:failed" }.count, 2)
        XCTAssertEqual(log.entries.filter { $0 == "builtIn:false" }.count, 1)
    }

    func testReconnectRemembersLastBuiltInToggleSetting() async {
        let store = makeStore()
        // 1. User connected external monitor and toggled Built-in OFF -> saved in profile.
        var profile = Fixture.fullProfile(autoDisableBuiltIn: true, builtInEnabled: false)
        store.saveProfile(profile)

        // 2. Cable unplugged (failsafe restores Built-in ON without modifying the monitor's profile).
        backend.displays = [Fixture.builtIn()]
        backend.builtInEnabled = true
        await store.processConnectedDisplaysNow()

        // 3. Cable reconnected -> Built-in automatically turns OFF again.
        backend.displays = [Fixture.builtIn(), Fixture.external()]
        await store.processConnectedDisplaysNow()
        XCTAssertFalse(backend.builtInEnabled, "Reconnect must auto-disable Built-in when last remembered as OFF")

        // 4. While connected, user toggles Built-in ON -> profile records builtIn=true, autoDisable=false.
        backend.builtInEnabled = true
        profile.builtInDisplayEnabled = true
        profile.autoDisableBuiltInOnConnect = false
        store.saveProfile(profile)

        // 5. Cable unplugged and reconnected -> Built-in stays ON.
        backend.displays = [Fixture.builtIn()]
        await store.processConnectedDisplaysNow()
        backend.displays = [Fixture.builtIn(), Fixture.external()]
        await store.processConnectedDisplaysNow()
        XCTAssertTrue(backend.builtInEnabled, "Next reconnect must keep Built-in ON after user toggled it ON")
    }
}
