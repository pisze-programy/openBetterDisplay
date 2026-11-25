import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import OpenBetterDisplayCore

// MARK: - Test doubles

/// In-memory display backend. Mirrors the live Single-Display Guard via `DisplayManager.canDisableBuiltIn`.
/// Never touches real displays.
private final class MockDisplayBackend: DisplayBackendProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _builtInEnabled: Bool
    private var _externalCount: Int
    private var _virtualExternalCount: Int = 0
    private var _externalSleeping: Bool = false
    private var _failEnable = false
    private var _enableCalls = 0
    private var _disableCalls = 0
    private var _emergencyCalls = 0
    private var _getOnlineDisplaysCalls = 0

    init(builtInEnabled: Bool, externalCount: Int) {
        _builtInEnabled = builtInEnabled
        _externalCount = externalCount
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var builtInEnabled: Bool {
        get { locked { _builtInEnabled } }
        set { locked { _builtInEnabled = newValue } }
    }

    var externalCount: Int {
        get { locked { _externalCount } }
        set { locked { _externalCount = newValue } }
    }

    var virtualExternalCount: Int {
        get { locked { _virtualExternalCount } }
        set { locked { _virtualExternalCount = newValue } }
    }

    var externalSleeping: Bool {
        get { locked { _externalSleeping } }
        set { locked { _externalSleeping = newValue } }
    }

    var failEnable: Bool {
        get { locked { _failEnable } }
        set { locked { _failEnable = newValue } }
    }

    var enableCalls: Int { locked { _enableCalls } }
    var disableCalls: Int { locked { _disableCalls } }
    var emergencyCalls: Int { locked { _emergencyCalls } }
    var getOnlineDisplaysCalls: Int { locked { _getOnlineDisplaysCalls } }

    func getOnlineDisplays() -> [DisplayInfo] {
        let (enabled, externals, virtuals, sleeping) = locked { () -> (Bool, Int, Int, Bool) in
            _getOnlineDisplaysCalls += 1
            return (_builtInEnabled, _externalCount, _virtualExternalCount, _externalSleeping)
        }
        var list = [makeDisplay(id: 1, builtIn: true, enabled: enabled, main: externals == 0)]
        for index in 0..<externals {
            list.append(makeDisplay(id: CGDirectDisplayID(100 + index), builtIn: false, enabled: !sleeping, online: true, main: index == 0))
        }
        for index in 0..<virtuals {
            list.append(makeDisplay(id: CGDirectDisplayID(200 + index), builtIn: false, virtual: true, enabled: true, online: true, main: externals == 0 && index == 0))
        }
        return list
    }

    func setBuiltInDisplayEnabled(_ enabled: Bool) throws {
        if !enabled {
            locked { _disableCalls += 1 }
            let others = getOnlineDisplays().filter { !$0.isBuiltIn }
            guard DisplayManager.canDisableBuiltIn(displays: others) else {
                throw DisplayError.singleDisplayGuardViolation
            }
            builtInEnabled = false
            return
        }
        let shouldFail = locked { () -> Bool in
            _enableCalls += 1
            return _failEnable
        }
        if shouldFail { throw DisplayError.configurationFailed(-1) }
        builtInEnabled = true
    }

    func isBuiltInDisplayEnabled() -> Bool { builtInEnabled }
    func setDisplayMode(displayID: CGDirectDisplayID, mode: DisplayModeInfo) throws {}
    func setMainDisplay(displayID: CGDirectDisplayID) throws {}
    func setDisplayMirror(displayID: CGDirectDisplayID, mirrorOf: CGDirectDisplayID?) throws {}
    func setDisplayRotation(displayID: CGDirectDisplayID, rotation: Int) throws {}
    func setHDREnabled(displayID: CGDirectDisplayID, enabled: Bool) throws {}
    func isHDREnabled(displayID: CGDirectDisplayID) -> Bool { false }

    func emergencyRestoreAllDisplays() throws {
        locked {
            _emergencyCalls += 1
            _builtInEnabled = true
        }
    }
}

private func makeDisplay(id: CGDirectDisplayID, builtIn: Bool, virtual: Bool = false, enabled: Bool, online: Bool = true, main: Bool = false) -> DisplayInfo {
    DisplayInfo(
        id: id,
        identifier: virtual
            ? DisplayIdentifier(vendorNumber: 0x756E6B6E, modelNumber: 0x76697274, serialNumber: 0)
            : DisplayIdentifier(vendorNumber: builtIn ? 1552 : 19501, modelNumber: builtIn ? 41038 : 28754, serialNumber: id),
        name: builtIn ? "Built-in Display" : (virtual ? "Display \(id)" : "External \(id)"),
        isBuiltIn: builtIn,
        isVirtual: virtual,
        isMain: main,
        isOnline: online,
        isEnabled: enabled
    )
}

/// Thread-safe manual clock for deterministic grace-period tests.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _current: Date

    init(_ start: Date = Date(timeIntervalSinceReferenceDate: 1_000_000)) {
        _current = start
    }

    var current: Date {
        lock.lock()
        defer { lock.unlock() }
        return _current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        _current = _current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

/// Thread-safe recorder for `onRestore` callbacks (invoked on the watchdog queue).
private final class TriggerRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _triggers: [FailsafeTrigger] = []

    var triggers: [FailsafeTrigger] {
        lock.lock()
        defer { lock.unlock() }
        return _triggers
    }

    func record(_ trigger: FailsafeTrigger) {
        lock.lock()
        _triggers.append(trigger)
        lock.unlock()
    }
}

// MARK: - FailsafeWatchdogTests

final class FailsafeWatchdogTests: XCTestCase {
    private var watchdogs: [FailsafeWatchdog] = []

    override func tearDown() {
        watchdogs.forEach { $0.stop() }
        watchdogs.removeAll()
        super.tearDown()
    }

    private func makeWatchdog(
        backend: MockDisplayBackend,
        recorder: TriggerRecorder,
        notificationCenter: NotificationCenter = NotificationCenter(),
        disconnectGracePeriod: TimeInterval = 0,
        pollInterval: TimeInterval = 0,
        wakeRecheckDelays: [TimeInterval] = [],
        clock: TestClock? = nil,
        queue: DispatchQueue? = nil
    ) -> FailsafeWatchdog {
        let watchdog = FailsafeWatchdog(
            backend: backend,
            notificationCenter: notificationCenter,
            observeDisplayReconfiguration: false,
            disconnectGracePeriod: disconnectGracePeriod,
            pollInterval: pollInterval,
            wakeRecheckDelays: wakeRecheckDelays,
            reconfigurationRecheckDelay: 0,
            now: { clock?.current ?? Date() },
            queue: queue,
            onRestore: { recorder.record($0) }
        )
        watchdogs.append(watchdog)
        return watchdog
    }

    // MARK: Single-Display Guard

    func testSingleDisplayGuardRejectsDisablingWithoutExternalDisplay() {
        let backend = MockDisplayBackend(builtInEnabled: true, externalCount: 0)
        XCTAssertThrowsError(try backend.setBuiltInDisplayEnabled(false)) { error in
            XCTAssertEqual(error as? DisplayError, .singleDisplayGuardViolation)
        }
        XCTAssertTrue(backend.builtInEnabled, "Built-in must stay ON when no external display is active")
    }

    func testSingleDisplayGuardAllowsDisablingWithActiveExternalDisplay() throws {
        let backend = MockDisplayBackend(builtInEnabled: true, externalCount: 1)
        try backend.setBuiltInDisplayEnabled(false)
        XCTAssertFalse(backend.builtInEnabled)
    }

    func testCanDisableBuiltInPureGuard() {
        let builtIn = makeDisplay(id: 1, builtIn: true, enabled: true)
        let activeExternal = makeDisplay(id: 2, builtIn: false, enabled: true)
        let disabledExternal = makeDisplay(id: 3, builtIn: false, enabled: false)
        let offlineExternal = makeDisplay(id: 4, builtIn: false, enabled: true, online: false)

        XCTAssertFalse(DisplayManager.canDisableBuiltIn(displays: []))
        XCTAssertFalse(DisplayManager.canDisableBuiltIn(displays: [builtIn]))
        XCTAssertFalse(DisplayManager.canDisableBuiltIn(displays: [builtIn, disabledExternal]))
        XCTAssertFalse(DisplayManager.canDisableBuiltIn(displays: [builtIn, offlineExternal]))
        XCTAssertTrue(DisplayManager.canDisableBuiltIn(displays: [builtIn, activeExternal]))
        XCTAssertTrue(DisplayManager.canDisableBuiltIn(displays: [builtIn, disabledExternal, activeExternal]))
    }

    // MARK: Disconnect failsafe

    func testDisconnectRestoresBuiltInAndReportsReconfigurationTrigger() {
        let backend = MockDisplayBackend(builtInEnabled: false, externalCount: 1)
        let recorder = TriggerRecorder()
        let watchdog = makeWatchdog(backend: backend, recorder: recorder)
        watchdog.start()
        watchdog.waitUntilIdle()
        XCTAssertFalse(backend.builtInEnabled, "External still active: no restore on start")
        XCTAssertEqual(backend.enableCalls, 0)

        backend.externalCount = 0 // cable unplugged
        watchdog.handleDisplayReconfiguration()
        watchdog.waitUntilIdle()

        XCTAssertTrue(backend.builtInEnabled)
        XCTAssertEqual(backend.enableCalls, 1)
        XCTAssertEqual(recorder.triggers, [.displayReconfiguration])
    }

    func testReconfigurationWithExternalStillActiveDoesNothing() {
        let backend = MockDisplayBackend(builtInEnabled: false, externalCount: 2)
        let recorder = TriggerRecorder()
        let watchdog = makeWatchdog(backend: backend, recorder: recorder)

        backend.externalCount = 1 // one of two monitors unplugged
        watchdog.handleDisplayReconfiguration()
        watchdog.waitUntilIdle()

        XCTAssertFalse(backend.builtInEnabled)
        XCTAssertEqual(backend.enableCalls, 0)
        XCTAssertTrue(recorder.triggers.isEmpty)
    }

    func testStartRestoresImmediatelyWhenAlreadyHeadless() {
        let backend = MockDisplayBackend(builtInEnabled: false, externalCount: 0)
        let recorder = TriggerRecorder()
        let watchdog = makeWatchdog(backend: backend, recorder: recorder)
        watchdog.start()
        watchdog.waitUntilIdle()
        XCTAssertTrue(backend.builtInEnabled)
        XCTAssertEqual(recorder.triggers, [.manualCheck])
    }

    func testRestoreFallsBackToEmergencyRestoreWhenEnableFails() {
        let backend = MockDisplayBackend(builtInEnabled: false, externalCount: 0)
        backend.failEnable = true
        let recorder = TriggerRecorder()
        let watchdog = makeWatchdog(backend: backend, recorder: recorder)

        XCTAssertTrue(watchdog.checkNow(trigger: .displayReconfiguration))
        XCTAssertEqual(backend.enableCalls, 1)
        XCTAssertEqual(backend.emergencyCalls, 1)
        XCTAssertTrue(backend.builtInEnabled)
        XCTAssertEqual(recorder.triggers, [.displayReconfiguration])
    }

    // MARK: Wake failsafe

    func testWakeRestoresImmediatelyAndDelayedRechecksFire() {
        let backend = MockDisplayBackend(builtInEnabled: true, externalCount: 0)
        let recorder = TriggerRecorder()
        let watchdog = makeWatchdog(backend: backend, recorder: recorder, wakeRecheckDelays: [0.15, 0.4])
        watchdog.start()
        watchdog.waitUntilIdle()
        XCTAssertTrue(recorder.triggers.isEmpty)

        backend.builtInEnabled = false
        watchdog.handleWake()
        watchdog.waitUntilIdle()
        XCTAssertTrue(backend.builtInEnabled, "Wake with no external display restores immediately")
        XCTAssertEqual(recorder.triggers, [.wake])

        // Simulate a failed external handshake turning the panel dark again before the delayed rechecks.
        backend.builtInEnabled = false
        XCTAssertTrue(waitUntil(timeout: 3) { backend.builtInEnabled }, "Delayed wake recheck must restore again")
        watchdog.waitUntilIdle()
        XCTAssertEqual(recorder.triggers.filter { $0 == .wake }.count, 2)
    }

    /// Polls `condition` until it is true or `timeout` elapses.
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    func testWakeNotificationIsObserved() {
        let center = NotificationCenter()
        let backend = MockDisplayBackend(builtInEnabled: true, externalCount: 0)
        let recorder = TriggerRecorder()
        let watchdog = FailsafeWatchdog(
            backend: backend,
            notificationCenter: center,
            observeDisplayReconfiguration: false,
            disconnectGracePeriod: 0,
            pollInterval: 0,
            wakeRecheckDelays: [],
            reconfigurationRecheckDelay: 0,
            onRestore: { recorder.record($0) }
        )
        watchdogs.append(watchdog)
        watchdog.start()
        watchdog.waitUntilIdle()

        backend.builtInEnabled = false
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        watchdog.waitUntilIdle()

        XCTAssertTrue(backend.builtInEnabled)
        XCTAssertEqual(recorder.triggers, [.wake])
    }

    func testStopCancelsPendingDelayedWakeChecks() {
        let backend = MockDisplayBackend(builtInEnabled: true, externalCount: 0)
        let recorder = TriggerRecorder()
        let watchdog = makeWatchdog(backend: backend, recorder: recorder, wakeRecheckDelays: [0.1, 0.2])
        watchdog.start()
        watchdog.handleWake() // immediate check is a no-op (built-in enabled)
        watchdog.waitUntilIdle()
        watchdog.stop()

        backend.builtInEnabled = false
        Thread.sleep(forTimeInterval: 0.35)
        watchdog.waitUntilIdle()

        XCTAssertFalse(backend.builtInEnabled, "Delayed wake checks from a stopped lifecycle must not run")
        XCTAssertEqual(backend.enableCalls, 0)
        XCTAssertTrue(recorder.triggers.isEmpty)
        XCTAssertFalse(watchdog.isRunning)
    }

    // MARK: Quit failsafe

    func testRestoreForQuitIsSynchronousEvenWithExternalDisplayConnected() {
        let backend = MockDisplayBackend(builtInEnabled: false, externalCount: 1)
        let recorder = TriggerRecorder()
        let watchdog = makeWatchdog(backend: backend, recorder: recorder)

        XCTAssertTrue(watchdog.restoreBuiltInForQuit())
        XCTAssertTrue(backend.builtInEnabled)
        XCTAssertEqual(backend.enableCalls, 1)
        XCTAssertEqual(recorder.triggers, [.quit])
    }

    func testRestoreForQuitIsNoOpWhenBuiltInAlreadyOn() {
        let backend = MockDisplayBackend(builtInEnabled: true, externalCount: 1)
        let recorder = TriggerRecorder()
        let watchdog = makeWatchdog(backend: backend, recorder: recorder)

        XCTAssertTrue(watchdog.restoreBuiltInForQuit())
        XCTAssertEqual(backend.enableCalls, 0)
        XCTAssertTrue(recorder.triggers.isEmpty)
    }

    // MARK: Emergency restore

    func testEmergencyRestoreCallsBackendAndReportsEmergency() {
        let backend = MockDisplayBackend(builtInEnabled: false, externalCount: 1)
        let recorder = TriggerRecorder()
        let watchdog = makeWatchdog(backend: backend, recorder: recorder)

        XCTAssertTrue(watchdog.emergencyRestoreAll())
        XCTAssertEqual(backend.emergencyCalls, 1)
        XCTAssertTrue(backend.builtInEnabled)
        XCTAssertEqual(recorder.triggers, [.emergency])
    }

    // MARK: Races & coalescing

    func testRapidDisconnectReconnectIsCoalescedAndDoesNotRestore() {
        let backend = MockDisplayBackend(builtInEnabled: false, externalCount: 1)
        let recorder = TriggerRecorder()
        let queue = DispatchQueue(label: "failsafe.test.race")
        let watchdog = makeWatchdog(backend: backend, recorder: recorder, queue: queue)

        queue.suspend()
        backend.externalCount = 0
        for _ in 0..<5 { watchdog.handleDisplayReconfiguration() } // burst of CG callbacks
        backend.externalCount = 1 // monitor re-trained before the check ran
        queue.resume()
        watchdog.waitUntilIdle()

        XCTAssertFalse(backend.builtInEnabled, "External is back: Built-in must stay as the user left it")
        XCTAssertEqual(backend.enableCalls, 0)
        XCTAssertEqual(backend.getOnlineDisplaysCalls, 1, "Burst of reconfiguration events must be coalesced into one check")
        XCTAssertTrue(recorder.triggers.isEmpty)
    }

    func testRapidDisconnectBurstRestoresExactlyOnce() {
        let backend = MockDisplayBackend(builtInEnabled: false, externalCount: 1)
        let recorder = TriggerRecorder()
        let queue = DispatchQueue(label: "failsafe.test.burst")
        let watchdog = makeWatchdog(backend: backend, recorder: recorder, queue: queue)

        queue.suspend()
        backend.externalCount = 0
        for _ in 0..<10 { watchdog.handleDisplayReconfiguration() }
        queue.resume()
        watchdog.waitUntilIdle()

        XCTAssertTrue(backend.builtInEnabled)
        XCTAssertEqual(backend.enableCalls, 1)
        XCTAssertEqual(recorder.triggers, [.displayReconfiguration])
    }

    // MARK: Pure policy

    func testShouldRestoreBuiltInEdgeCases() {
        let builtIn = makeDisplay(id: 1, builtIn: true, enabled: false)
        let activeExternal = makeDisplay(id: 2, builtIn: false, enabled: true)
        let disabledExternal = makeDisplay(id: 3, builtIn: false, enabled: false)
        let offlineExternal = makeDisplay(id: 4, builtIn: false, enabled: true, online: false)

        XCTAssertFalse(FailsafeWatchdog.shouldRestoreBuiltIn(builtInEnabled: true, displays: []))
        XCTAssertFalse(FailsafeWatchdog.shouldRestoreBuiltIn(builtInEnabled: true, displays: [builtIn]))
        XCTAssertTrue(FailsafeWatchdog.shouldRestoreBuiltIn(builtInEnabled: false, displays: []))
        XCTAssertTrue(FailsafeWatchdog.shouldRestoreBuiltIn(builtInEnabled: false, displays: [builtIn]))
        XCTAssertTrue(FailsafeWatchdog.shouldRestoreBuiltIn(builtInEnabled: false, displays: [builtIn, disabledExternal]))
        XCTAssertTrue(FailsafeWatchdog.shouldRestoreBuiltIn(builtInEnabled: false, displays: [builtIn, offlineExternal]))
        XCTAssertFalse(FailsafeWatchdog.shouldRestoreBuiltIn(builtInEnabled: false, displays: [builtIn, activeExternal]))
        XCTAssertFalse(FailsafeWatchdog.shouldRestoreBuiltIn(builtInEnabled: false, displays: [builtIn, disabledExternal, activeExternal]))
    }

    func testCheckNowIsNoOpWhenBuiltInEnabled() {
        let backend = MockDisplayBackend(builtInEnabled: true, externalCount: 0)
        let recorder = TriggerRecorder()
        let watchdog = makeWatchdog(backend: backend, recorder: recorder)
        XCTAssertFalse(watchdog.checkNow(trigger: .manualCheck))
        XCTAssertEqual(backend.getOnlineDisplaysCalls, 0, "Cheap isBuiltInDisplayEnabled() short-circuits the check")
        XCTAssertEqual(backend.enableCalls, 0)
    }

    // MARK: Virtual placeholder displays & 15s grace period

    func testDefaultsUseFifteenSecondGracePeriodAndOneSecondHeartbeat() {
        XCTAssertEqual(FailsafeWatchdog.defaultDisconnectGracePeriod, 15.0)
        XCTAssertEqual(FailsafeWatchdog.defaultPollInterval, 1.0)
    }

    func testVirtualHeadlessDisplayDoesNotPreventRestoreOrSatisfySingleDisplayGuard() {
        let builtIn = makeDisplay(id: 1, builtIn: true, enabled: false)
        let virtualHeadless = makeDisplay(id: 11, builtIn: false, virtual: true, enabled: true)
        let physicalExternal = makeDisplay(id: 3, builtIn: false, virtual: false, enabled: true)

        XCTAssertTrue(
            FailsafeWatchdog.shouldRestoreBuiltIn(builtInEnabled: false, displays: [builtIn, virtualHeadless]),
            "WindowServer headless virtual placeholder must NOT fool the failsafe"
        )
        XCTAssertFalse(
            DisplayManager.canDisableBuiltIn(displays: [builtIn, virtualHeadless]),
            "Virtual placeholder must NOT satisfy the Single-Display Guard"
        )
        XCTAssertFalse(
            FailsafeWatchdog.shouldRestoreBuiltIn(builtInEnabled: false, displays: [builtIn, virtualHeadless, physicalExternal]),
            "A real physical external display still prevents restore"
        )

        // End-to-end unplug where macOS spawns a headless virtual placeholder display:
        let backend = MockDisplayBackend(builtInEnabled: false, externalCount: 1)
        let recorder = TriggerRecorder()
        let watchdog = makeWatchdog(backend: backend, recorder: recorder, disconnectGracePeriod: 0)
        backend.externalCount = 0
        backend.virtualExternalCount = 1 // macOS spawns Display 11 ('unkn'/'virt')
        watchdog.handleDisplayReconfiguration()
        watchdog.waitUntilIdle()

        XCTAssertTrue(backend.builtInEnabled, "Built-in MUST restore when only a virtual placeholder remains")
        XCTAssertEqual(recorder.triggers, [.displayReconfiguration])
    }

    func testBriefCableFlickerUnderFifteenSecondsDoesNotRestoreBuiltIn() {
        let backend = MockDisplayBackend(builtInEnabled: false, externalCount: 1)
        let recorder = TriggerRecorder()
        let clock = TestClock()
        let watchdog = makeWatchdog(backend: backend, recorder: recorder, disconnectGracePeriod: 15.0, pollInterval: 0, clock: clock)

        // Cable flickers out and WindowServer spawns a headless virtual placeholder.
        backend.externalCount = 0
        backend.virtualExternalCount = 1
        watchdog.handleDisplayReconfiguration()
        watchdog.waitUntilIdle()
        XCTAssertFalse(backend.builtInEnabled, "Must NOT restore immediately on disconnect")
        XCTAssertTrue(watchdog.isGraceCountdownActive)

        // Still disconnected at 14 seconds -> still waiting.
        clock.advance(by: 14.0)
        watchdog.handleDisplayReconfiguration()
        watchdog.waitUntilIdle()
        XCTAssertFalse(backend.builtInEnabled, "Must NOT restore before 15 seconds elapse")
        XCTAssertEqual(backend.enableCalls, 0)

        // Cable reconnects before 15s -> countdown cancels cleanly.
        backend.externalCount = 1
        backend.virtualExternalCount = 0
        clock.advance(by: 0.5)
        watchdog.handleDisplayReconfiguration()
        watchdog.waitUntilIdle()
        XCTAssertFalse(backend.builtInEnabled)
        XCTAssertFalse(watchdog.isGraceCountdownActive)
        XCTAssertEqual(backend.enableCalls, 0)
        XCTAssertTrue(recorder.triggers.isEmpty)
    }

    func testSustainedCableDisconnectRestoresAfterGracePeriod() {
        let backend = MockDisplayBackend(builtInEnabled: false, externalCount: 1)
        let recorder = TriggerRecorder()
        let clock = TestClock()
        let watchdog = makeWatchdog(backend: backend, recorder: recorder, disconnectGracePeriod: 15.0, pollInterval: 0, clock: clock)

        // Cable physically unplugged, macOS spawns virtual Display 11.
        backend.externalCount = 0
        backend.virtualExternalCount = 1
        watchdog.handleDisplayReconfiguration()
        watchdog.waitUntilIdle()
        XCTAssertFalse(backend.builtInEnabled)

        // Advance past 15s -> must restore Built-in Display.
        clock.advance(by: 15.0)
        watchdog.handleDisplayReconfiguration()
        watchdog.waitUntilIdle()

        XCTAssertTrue(backend.builtInEnabled)
        XCTAssertEqual(backend.enableCalls, 1)
        XCTAssertFalse(watchdog.isGraceCountdownActive)
        XCTAssertEqual(recorder.triggers, [.displayReconfiguration])
    }

    func testHeartbeatPollingRestoresEvenWithoutReconfigurationCallback() {
        let backend = MockDisplayBackend(builtInEnabled: false, externalCount: 1)
        let recorder = TriggerRecorder()
        let watchdog = makeWatchdog(
            backend: backend,
            recorder: recorder,
            disconnectGracePeriod: 0.12,
            pollInterval: 0.05
        )
        watchdog.start()
        watchdog.waitUntilIdle()
        XCTAssertFalse(backend.builtInEnabled)

        // External display vanishes with NO handleDisplayReconfiguration() call at all!
        backend.externalCount = 0
        backend.virtualExternalCount = 1

        XCTAssertTrue(
            waitUntil(timeout: 2.0) { backend.builtInEnabled },
            "Periodic heartbeat must catch silent cable unplugs and restore Built-in after the grace period"
        )
        watchdog.waitUntilIdle()
        XCTAssertEqual(recorder.triggers, [.displayReconfiguration])
    }

    func testIdleDisplaySleepWithCableConnectedDoesNotWakeBuiltIn() {
        let center = NotificationCenter()
        let backend = MockDisplayBackend(builtInEnabled: false, externalCount: 1)
        let recorder = TriggerRecorder()
        let clock = TestClock()
        let watchdog = makeWatchdog(
            backend: backend,
            recorder: recorder,
            notificationCenter: center,
            disconnectGracePeriod: 15.0,
            pollInterval: 0,
            clock: clock
        )
        watchdog.start()
        watchdog.waitUntilIdle()

        // macOS puts displays to idle sleep while the external cable stays plugged in (online, asleep -> enabled == false).
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        backend.externalSleeping = true
        watchdog.handleDisplayReconfiguration()
        watchdog.waitUntilIdle()
        clock.advance(by: 60.0)
        watchdog.handleDisplayReconfiguration()
        watchdog.waitUntilIdle()

        XCTAssertFalse(backend.builtInEnabled, "Idle display sleep with cable still online must NOT wake Built-in")
        XCTAssertFalse(watchdog.isGraceCountdownActive)

        // If cable is physically unplugged while screens were asleep (0 online physical externals), failsafe proceeds.
        backend.externalCount = 0
        backend.externalSleeping = false
        backend.virtualExternalCount = 1
        watchdog.handleDisplayReconfiguration()
        watchdog.waitUntilIdle()
        clock.advance(by: 15.0)
        watchdog.handleDisplayReconfiguration()
        watchdog.waitUntilIdle()

        XCTAssertTrue(backend.builtInEnabled, "Unplugging cable during display sleep MUST still restore Built-in")
    }

    func testEmergencyAndQuitBypassGracePeriod() {
        let backend = MockDisplayBackend(builtInEnabled: false, externalCount: 0)
        let recorder = TriggerRecorder()
        let clock = TestClock()
        let watchdog = makeWatchdog(backend: backend, recorder: recorder, disconnectGracePeriod: 15.0, pollInterval: 0, clock: clock)

        watchdog.handleDisplayReconfiguration()
        watchdog.waitUntilIdle()
        XCTAssertFalse(backend.builtInEnabled)
        XCTAssertTrue(watchdog.isGraceCountdownActive)

        XCTAssertTrue(watchdog.emergencyRestoreAll())
        XCTAssertTrue(backend.builtInEnabled)
        XCTAssertFalse(watchdog.isGraceCountdownActive)
        XCTAssertEqual(recorder.triggers, [.emergency])

        backend.builtInEnabled = false
        XCTAssertTrue(watchdog.restoreBuiltInForQuit())
        XCTAssertTrue(backend.builtInEnabled)
        XCTAssertEqual(recorder.triggers, [.emergency, .quit])
    }
}
