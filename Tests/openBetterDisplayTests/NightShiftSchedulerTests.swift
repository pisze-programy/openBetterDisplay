import XCTest
import CoreGraphics
@testable import OpenBetterDisplayCore

// MARK: - Test doubles (file-private)

fileprivate final class FakeNightShiftBackend: NightShiftBackendProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _supported: Set<CGDirectDisplayID> = []
    private var _enabledCalls: [Bool] = []
    private var _warmthCalls: [Double] = []
    private var _enableResult = true
    private var _warmthResult = true

    var supported: Set<CGDirectDisplayID> {
        get { lock.lock(); defer { lock.unlock() }; return _supported }
        set { lock.lock(); defer { lock.unlock() }; _supported = newValue }
    }
    var enableResult: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _enableResult }
        set { lock.lock(); defer { lock.unlock() }; _enableResult = newValue }
    }
    var warmthResult: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _warmthResult }
        set { lock.lock(); defer { lock.unlock() }; _warmthResult = newValue }
    }
    var enabledCalls: [Bool] { lock.lock(); defer { lock.unlock() }; return _enabledCalls }
    var warmthCalls: [Double] { lock.lock(); defer { lock.unlock() }; return _warmthCalls }

    func isSupported(displayID: CGDirectDisplayID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _supported.contains(displayID)
    }
    func isNativeNightShiftActive() -> Bool { false }
    func setNativeNightShiftEnabled(_ enabled: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        _enabledCalls.append(enabled)
        return _enableResult
    }
    func setNativeNightShiftWarmth(_ warmth: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        _warmthCalls.append(warmth)
        return _warmthResult
    }
    func evaluateSchedule(config: NightShiftConfig, now: Date) -> (shouldBeActive: Bool, effectiveWarmth: Double) {
        NightShiftScheduler.evaluate(config: config, now: now)
    }
}

@MainActor
fileprivate final class WarmthOverlay: OverlayBackendProtocol {
    private(set) var warmth: [CGDirectDisplayID: Double] = [:]
    private(set) var removeAllCalls = 0

    func setDimmingLevel(displayID: CGDirectDisplayID, level: Double) {}
    func setNightShiftWarmth(displayID: CGDirectDisplayID, warmth: Double) { self.warmth[displayID] = warmth }
    func removeAllOverlays() { removeAllCalls += 1; warmth.removeAll() }
}

// MARK: - Schedule math (pure)

final class NightShiftScheduleMathTests: XCTestCase {
    private static let warsaw = TimeZone(identifier: "Europe/Warsaw")!

    /// Winter date, so no DST transition interferes with the matrix.
    private func warsawDate(_ hour: Int, _ minute: Int, second: Int = 0, day: Int = 15) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.warsaw
        return cal.date(from: DateComponents(year: 2026, month: 1, day: day, hour: hour, minute: minute, second: second))!
    }

    private func config(
        enabled: Bool = true,
        schedule: Bool = true,
        start: (Int, Int) = (18, 0),
        end: (Int, Int) = (5, 0),
        warmth: Double = 0.5,
        transition: Int = 20,
        tz: String? = "Europe/Warsaw"
    ) -> NightShiftConfig {
        NightShiftConfig(
            enabled: enabled, scheduleEnabled: schedule,
            startHour: start.0, startMinute: start.1, endHour: end.0, endMinute: end.1,
            warmth: warmth, transitionMinutes: transition, timeZoneIdentifier: tz
        )
    }

    private func eval(_ cfg: NightShiftConfig, _ h: Int, _ m: Int, second: Int = 0) -> (shouldBeActive: Bool, effectiveWarmth: Double) {
        NightShiftScheduler.evaluate(config: cfg, now: warsawDate(h, m, second: second))
    }

    // MARK: 18:00–05:00 matrix

    func testOvernightBoundaryMatrix() {
        let cfg = config()
        let cases: [(Int, Int, Bool, Double)] = [
            (17, 59, false, 0.0),
            (18, 0, true, 0.0),      // start: active, ramp at 0
            (18, 10, true, 0.25),    // 50% of the 20 min ramp
            (18, 20, true, 0.5),     // ramp complete
            (23, 59, true, 0.5),
            (0, 0, true, 0.5),
            (4, 40, true, 0.5),      // ramp-out begins
            (4, 50, true, 0.25),     // 50%
            (4, 59, true, 0.025),
            (5, 0, false, 0.0),      // end is exclusive
            (12, 0, false, 0.0)
        ]
        for (h, m, active, warmth) in cases {
            let r = eval(cfg, h, m)
            XCTAssertEqual(r.shouldBeActive, active, String(format: "%02d:%02d active", h, m))
            XCTAssertEqual(r.effectiveWarmth, warmth, accuracy: 1e-6, String(format: "%02d:%02d warmth", h, m))
        }
    }

    func testSecondsContributeToTheRamp() {
        let r = eval(config(), 18, 9, second: 30)
        XCTAssertEqual(r.effectiveWarmth, 0.5 * (9.5 / 20.0), accuracy: 1e-6)
    }

    func testCustomMinutesInOvernightWindow() {
        let cfg = config(start: (22, 30), end: (6, 15), transition: 0)
        XCTAssertFalse(eval(cfg, 22, 29).shouldBeActive)
        XCTAssertTrue(eval(cfg, 22, 30).shouldBeActive)
        XCTAssertTrue(eval(cfg, 6, 14).shouldBeActive)
        XCTAssertFalse(eval(cfg, 6, 15).shouldBeActive)
    }

    // MARK: Same-day

    func testSameDayWindow() {
        let cfg = config(start: (9, 0), end: (17, 0), transition: 0)
        XCTAssertFalse(eval(cfg, 8, 59).shouldBeActive)
        XCTAssertTrue(eval(cfg, 9, 0).shouldBeActive)
        XCTAssertTrue(eval(cfg, 12, 0).shouldBeActive)
        XCTAssertTrue(eval(cfg, 16, 59).shouldBeActive)
        XCTAssertFalse(eval(cfg, 17, 0).shouldBeActive)
        XCTAssertFalse(eval(cfg, 23, 0).shouldBeActive)
        XCTAssertFalse(eval(cfg, 0, 0).shouldBeActive)
    }

    func testSameDayWindowRamps() {
        let cfg = config(start: (9, 0), end: (17, 0), transition: 30)
        XCTAssertEqual(eval(cfg, 9, 15).effectiveWarmth, 0.25, accuracy: 1e-6)
        XCTAssertEqual(eval(cfg, 12, 0).effectiveWarmth, 0.5, accuracy: 1e-6)
        XCTAssertEqual(eval(cfg, 16, 45).effectiveWarmth, 0.25, accuracy: 1e-6)
    }

    func testStartEqualsEndMeansAllDay() {
        let cfg = config(start: (10, 0), end: (10, 0), transition: 0)
        for (h, m) in [(0, 0), (9, 59), (10, 0), (15, 30), (23, 59)] {
            XCTAssertTrue(eval(cfg, h, m).shouldBeActive, String(format: "%02d:%02d", h, m))
            XCTAssertEqual(eval(cfg, h, m).effectiveWarmth, 0.5, accuracy: 1e-9)
        }
    }

    // MARK: Transition handling

    func testZeroTransitionIsInstant() {
        let cfg = config(transition: 0)
        XCTAssertEqual(eval(cfg, 18, 0).effectiveWarmth, 0.5, accuracy: 1e-9)
        XCTAssertEqual(eval(cfg, 4, 59).effectiveWarmth, 0.5, accuracy: 1e-9)
        XCTAssertFalse(eval(cfg, 5, 0).shouldBeActive)
        XCTAssertFalse(eval(cfg, 17, 59).shouldBeActive)
    }

    func testNegativeTransitionBehavesLikeInstant() {
        let cfg = config(transition: -15)
        XCTAssertEqual(eval(cfg, 18, 0).effectiveWarmth, 0.5, accuracy: 1e-9)
    }

    func testTransitionIsCappedAtHalfTheWindow() {
        // 60 minute window, requested 120 minute ramp -> capped to 30.
        let cfg = config(start: (9, 0), end: (10, 0), transition: 120)
        XCTAssertEqual(eval(cfg, 9, 15).effectiveWarmth, 0.25, accuracy: 1e-6)
        XCTAssertEqual(eval(cfg, 9, 30).effectiveWarmth, 0.5, accuracy: 1e-6, "peak at the midpoint")
        XCTAssertEqual(eval(cfg, 9, 45).effectiveWarmth, 0.25, accuracy: 1e-6)
    }

    // MARK: Master switches

    func testDisabledMasterSwitchWinsOverEverything() {
        let cfg = config(enabled: false)
        XCTAssertFalse(eval(cfg, 23, 0).shouldBeActive)
        XCTAssertEqual(eval(cfg, 23, 0).effectiveWarmth, 0)
        let noSchedule = config(enabled: false, schedule: false)
        XCTAssertFalse(eval(noSchedule, 23, 0).shouldBeActive)
    }

    func testScheduleDisabledMeansAlwaysOnWithFullWarmth() {
        let cfg = config(schedule: false)
        for (h, m) in [(0, 0), (12, 0), (17, 59), (18, 0), (23, 59)] {
            let r = eval(cfg, h, m)
            XCTAssertTrue(r.shouldBeActive)
            XCTAssertEqual(r.effectiveWarmth, 0.5, accuracy: 1e-9, "no ramp without a schedule")
        }
    }

    func testWarmthIsClampedAndNonFiniteIsGuarded() {
        XCTAssertEqual(eval(config(warmth: 7, transition: 0), 23, 0).effectiveWarmth, 1.0)
        XCTAssertEqual(eval(config(warmth: -2, transition: 0), 23, 0).effectiveWarmth, 0.0)
        for bad in [Double.nan, .infinity, -.infinity] {
            let r = eval(config(warmth: bad), 23, 0)
            XCTAssertTrue(r.shouldBeActive)
            XCTAssertEqual(r.effectiveWarmth, 0, "non-finite warmth \(bad) is treated as 0")
            let always = eval(config(schedule: false, warmth: bad), 23, 0)
            XCTAssertEqual(always.effectiveWarmth, 0)
        }
    }

    // MARK: Time zones

    func testTimeZoneResolution() {
        XCTAssertEqual(NightShiftScheduler.resolveTimeZone(config(tz: "Europe/Warsaw")).identifier, "Europe/Warsaw")
        XCTAssertEqual(NightShiftScheduler.resolveTimeZone(config(tz: "UTC")).secondsFromGMT(), 0)
        XCTAssertEqual(NightShiftScheduler.resolveTimeZone(config(tz: "Asia/Tokyo")).identifier, "Asia/Tokyo")
        XCTAssertEqual(NightShiftScheduler.resolveTimeZone(config(tz: "Not/AZone")).identifier, TimeZone.current.identifier)
        XCTAssertEqual(NightShiftScheduler.resolveTimeZone(config(tz: nil)).identifier, TimeZone.current.identifier)
        XCTAssertEqual(NightShiftScheduler.resolveTimeZone(config(tz: "")).identifier, TimeZone.current.identifier)
        XCTAssertEqual(NightShiftScheduler.fallbackTimeZoneIdentifier, "Europe/Warsaw")
    }

    func testSameInstantEvaluatesDifferentlyPerTimeZone() {
        // 2026-01-15 20:00:00 UTC == 21:00 Warsaw == 05:00 (next day) Tokyo.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let instant = cal.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 20))!

        let warsaw = NightShiftScheduler.evaluate(config: config(transition: 0, tz: "Europe/Warsaw"), now: instant)
        let utc = NightShiftScheduler.evaluate(config: config(transition: 0, tz: "UTC"), now: instant)
        let tokyo = NightShiftScheduler.evaluate(config: config(transition: 0, tz: "Asia/Tokyo"), now: instant)
        XCTAssertTrue(warsaw.shouldBeActive)
        XCTAssertTrue(utc.shouldBeActive)
        XCTAssertFalse(tokyo.shouldBeActive, "05:00 local is the exclusive end")
    }

    func testInvalidTimeZoneEvaluatesLikeSystemTimeZone() {
        let now = Date()
        let invalid = NightShiftScheduler.evaluate(config: config(tz: "Nope/Nope"), now: now)
        let current = NightShiftScheduler.evaluate(config: config(tz: TimeZone.current.identifier), now: now)
        XCTAssertEqual(invalid.shouldBeActive, current.shouldBeActive)
        XCTAssertEqual(invalid.effectiveWarmth, current.effectiveWarmth, accuracy: 1e-9)
    }

    // MARK: Description

    @MainActor
    func testScheduleDescription() {
        let scheduler = NightShiftScheduler(
            backend: FakeNightShiftBackend(), overlay: WarmthOverlay(),
            config: config(), displayProvider: { [] }
        )
        XCTAssertEqual(scheduler.scheduleDescription, "18:00–05:00")
        scheduler.update(config: config(start: (9, 5), end: (17, 30)))
        XCTAssertEqual(scheduler.scheduleDescription, "09:05–17:30")
        scheduler.stop()
    }
}

// MARK: - Hybrid application (mock backends)

@MainActor
final class NightShiftHybridApplicationTests: XCTestCase {
    private let builtInID: CGDirectDisplayID = 1
    private let externalID: CGDirectDisplayID = 3

    private var backend: FakeNightShiftBackend!
    private var overlay: WarmthOverlay!
    private var displays: [DisplayInfo] = []
    private var scheduler: NightShiftScheduler!

    /// 23:00 in Warsaw, deep inside the 18:00–05:00 window.
    private var insideWindow: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        return cal.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 23))!
    }

    private var outsideWindow: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        return cal.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 12))!
    }

    private func display(_ id: CGDirectDisplayID, builtIn: Bool = false, hdr: Bool = false, online: Bool = true, enabled: Bool = true) -> DisplayInfo {
        DisplayInfo(
            id: id, identifier: DisplayIdentifier(vendorNumber: 1, modelNumber: UInt32(id)),
            name: builtIn ? "Built-in" : "LC49G95T", isBuiltIn: builtIn, isMain: builtIn,
            isOnline: online, isEnabled: enabled, supportsHDR: !builtIn, isHDREnabled: hdr
        )
    }

    private func makeConfig(enabled: Bool = true, fallbackInHDR: Bool = true, schedule: Bool = true) -> NightShiftConfig {
        NightShiftConfig(
            enabled: enabled, scheduleEnabled: schedule, warmth: 0.5, transitionMinutes: 0,
            applySoftwareFallbackInHDR: fallbackInHDR, timeZoneIdentifier: "Europe/Warsaw"
        )
    }

    override func setUp() async throws {
        backend = FakeNightShiftBackend()
        overlay = WarmthOverlay()
        displays = [display(builtInID, builtIn: true), display(externalID)]
        scheduler = NightShiftScheduler(
            backend: backend, overlay: overlay, config: makeConfig(),
            displayProvider: { [unowned self] in self.displays }
        )
        scheduler.now = { [unowned self] in self.insideWindow }
    }

    override func tearDown() async throws {
        scheduler.stop()
        scheduler = nil
    }

    func testHDRExternalGetsWarmOverlayEvenIfBackendClaimsNativeSupport() {
        displays = [display(externalID, hdr: true)]
        backend.supported = [externalID]

        let status = scheduler.applyNow()

        XCTAssertEqual(overlay.warmth[externalID] ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(status.overlayDisplayIDs, [externalID])
        XCTAssertTrue(status.isActive)
        XCTAssertFalse(status.usedNative, "native Night Shift cannot tint an HDR display")
        XCTAssertTrue(backend.enabledCalls.isEmpty)
    }

    func testHDRFallbackCanBeDisabled() {
        scheduler.update(config: makeConfig(fallbackInHDR: false))
        displays = [display(externalID, hdr: true)]
        let status = scheduler.applyNow()
        XCTAssertEqual(overlay.warmth[externalID] ?? 0, 0, accuracy: 1e-9)
        XCTAssertTrue(status.overlayDisplayIDs.isEmpty)
    }

    func testSDRExternalWithoutNativeSupportUsesOverlay() {
        let status = scheduler.applyNow()
        XCTAssertEqual(overlay.warmth[externalID] ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(overlay.warmth[builtInID] ?? -1, 0.5, accuracy: 1e-9, "built-in without native support also falls back")
        XCTAssertEqual(Set(status.overlayDisplayIDs), [builtInID, externalID])
        XCTAssertFalse(status.usedNative)
    }

    func testNativeIsPreferredOnSupportedSDRDisplay() {
        backend.supported = [builtInID]
        let status = scheduler.applyNow()

        XCTAssertEqual(backend.enabledCalls, [true])
        XCTAssertEqual(backend.warmthCalls.count, 1)
        XCTAssertEqual(backend.warmthCalls.first ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertTrue(status.usedNative)
        XCTAssertNil(overlay.warmth[builtInID].flatMap { $0 > 0 ? $0 : nil }, "no overlay tint on a natively handled display")
        XCTAssertEqual(overlay.warmth[externalID] ?? -1, 0.5, accuracy: 1e-9, "external still gets the software tint")
        XCTAssertEqual(status.overlayDisplayIDs, [externalID])
    }

    func testNightShiftOffNeverTouchesUsersNativeNightShift() {
        backend.supported = [builtInID]
        scheduler.update(config: makeConfig(enabled: false))
        let status = scheduler.applyNow()
        scheduler.applyNow()

        XCTAssertTrue(backend.enabledCalls.isEmpty, "we never enabled it, so we must never disable it")
        XCTAssertTrue(backend.warmthCalls.isEmpty)
        XCTAssertFalse(status.isActive)
        XCTAssertFalse(status.usedNative, "usedNative stays false while Night Shift is OFF")
        XCTAssertEqual(status.effectiveWarmth, 0)
        XCTAssertTrue(status.overlayDisplayIDs.isEmpty)
    }

    func testOutsideScheduleWindowDoesNothingNative() {
        scheduler.now = { [unowned self] in self.outsideWindow }
        backend.supported = [builtInID]
        let status = scheduler.applyNow()
        XCTAssertTrue(backend.enabledCalls.isEmpty)
        XCTAssertFalse(status.isActive)
        XCTAssertFalse(status.usedNative)
        XCTAssertEqual(overlay.warmth[externalID] ?? 0, 0, accuracy: 1e-9)
    }

    func testDisablingAfterEnablingTurnsNativeOffExactlyOnce() {
        backend.supported = [builtInID]
        scheduler.applyNow()
        XCTAssertEqual(backend.enabledCalls, [true])

        scheduler.update(config: makeConfig(enabled: false))
        XCTAssertEqual(backend.enabledCalls, [true, false])
        scheduler.applyNow()
        XCTAssertEqual(backend.enabledCalls, [true, false], "no repeated disable calls")
        XCTAssertEqual(overlay.warmth[externalID] ?? 0, 0, accuracy: 1e-9, "overlay cleared as well")
    }

    func testLeavingTheWindowTurnsOffWhatWeTurnedOn() {
        backend.supported = [builtInID]
        scheduler.applyNow()
        scheduler.now = { [unowned self] in self.outsideWindow }
        let status = scheduler.applyNow()
        XCTAssertEqual(backend.enabledCalls, [true, false])
        XCTAssertFalse(status.isActive)
        XCTAssertFalse(status.usedNative)
    }

    func testNativeFailureFallsBackToOverlay() {
        backend.supported = [builtInID]
        backend.enableResult = false
        backend.warmthResult = false
        let status = scheduler.applyNow()
        XCTAssertFalse(status.usedNative)
        XCTAssertEqual(overlay.warmth[builtInID] ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertTrue(status.overlayDisplayIDs.contains(builtInID))
    }

    func testOfflineAndDisabledDisplaysAreIgnored() {
        displays = [display(externalID, online: false), display(9, enabled: false)]
        let status = scheduler.applyNow()
        XCTAssertTrue(overlay.warmth.isEmpty)
        XCTAssertTrue(status.overlayDisplayIDs.isEmpty)
    }

    func testDisconnectedDisplayTintIsCleared() {
        scheduler.applyNow()
        XCTAssertEqual(overlay.warmth[externalID] ?? -1, 0.5, accuracy: 1e-9)

        scheduler.update(config: makeConfig(enabled: false))
        XCTAssertEqual(overlay.warmth[externalID] ?? -1, 0, accuracy: 1e-9)
    }

    func testRampedWarmthIsForwardedToOverlay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        let tenPastSix = cal.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 18, minute: 10))!
        var cfg = makeConfig()
        cfg.transitionMinutes = 20
        scheduler.update(config: cfg)
        scheduler.now = { tenPastSix }
        let status = scheduler.applyNow()
        XCTAssertEqual(status.effectiveWarmth, 0.25, accuracy: 1e-6)
        XCTAssertEqual(overlay.warmth[externalID] ?? -1, 0.25, accuracy: 1e-6)
    }

    func testRestoreNeutralClearsTintsDisablesOurNativeAndStops() {
        backend.supported = [builtInID]
        scheduler.start()
        XCTAssertTrue(scheduler.isRunning)
        XCTAssertEqual(overlay.warmth[externalID] ?? -1, 0.5, accuracy: 1e-9)

        scheduler.restoreNeutral()

        XCTAssertFalse(scheduler.isRunning)
        XCTAssertEqual(overlay.warmth[externalID] ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(backend.enabledCalls, [true, false])
        XCTAssertFalse(scheduler.status.isActive)
        XCTAssertEqual(scheduler.status.effectiveWarmth, 0)
    }

    func testStartAppliesImmediatelyAndStopHaltsTheTimer() {
        XCTAssertFalse(scheduler.isRunning)
        scheduler.start()
        XCTAssertTrue(scheduler.isRunning)
        XCTAssertEqual(overlay.warmth[externalID] ?? -1, 0.5, accuracy: 1e-9)
        scheduler.start() // idempotent
        XCTAssertTrue(scheduler.isRunning)
        scheduler.stop()
        XCTAssertFalse(scheduler.isRunning)
        XCTAssertEqual(NightShiftScheduler.evaluationInterval, 30)
    }

    func testOnStatusChangeFiresOnlyWhenStatusActuallyChanges() {
        var seen: [NightShiftStatus] = []
        scheduler.onStatusChange = { seen.append($0) }
        scheduler.applyNow()
        scheduler.applyNow()
        scheduler.applyNow()
        XCTAssertEqual(seen.count, 1)
        XCTAssertTrue(seen.first?.isActive ?? false)

        scheduler.update(config: makeConfig(enabled: false))
        XCTAssertEqual(seen.count, 2)
        XCTAssertFalse(seen.last?.isActive ?? true)
    }

    func testInstanceEvaluateUsesInjectedClockAndConfig() {
        XCTAssertTrue(scheduler.evaluate().shouldBeActive)
        scheduler.now = { [unowned self] in self.outsideWindow }
        XCTAssertFalse(scheduler.evaluate().shouldBeActive)
        XCTAssertTrue(scheduler.evaluate(now: insideWindow).shouldBeActive)
    }

    func testBackendProtocolEvaluateMatchesScheduler() {
        let cfg = makeConfig()
        let viaBackend = backend.evaluateSchedule(config: cfg, now: insideWindow)
        let direct = NightShiftScheduler.evaluate(config: cfg, now: insideWindow)
        XCTAssertEqual(viaBackend.shouldBeActive, direct.shouldBeActive)
        XCTAssertEqual(viaBackend.effectiveWarmth, direct.effectiveWarmth, accuracy: 1e-12)
    }
}
