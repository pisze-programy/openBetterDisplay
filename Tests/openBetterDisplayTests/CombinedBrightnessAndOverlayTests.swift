import XCTest
import Cocoa
import CoreGraphics
@testable import OpenBetterDisplayCore

// MARK: - Test doubles (file-private)

@MainActor
fileprivate final class RecordingOverlay: OverlayBackendProtocol {
    private(set) var dimming: [CGDirectDisplayID: Double] = [:]
    private(set) var dimmingCalls = 0

    func setDimmingLevel(displayID: CGDirectDisplayID, level: Double) {
        dimming[displayID] = level
        dimmingCalls += 1
    }
    func setNightShiftWarmth(displayID: CGDirectDisplayID, warmth: Double) {}
    func removeAllOverlays() { dimming.removeAll() }
}

fileprivate final class ScriptedDDC: DDCBackendProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _writes: [UInt16] = []
    private var _succeeds = true

    var succeeds: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _succeeds }
        set { lock.lock(); defer { lock.unlock() }; _succeeds = newValue }
    }
    var writes: [UInt16] { lock.lock(); defer { lock.unlock() }; return _writes }

    func probeCapabilities(displayID: CGDirectDisplayID) -> DDCCapabilityReport {
        DDCCapabilityReport(displayID: displayID, displayName: "mock", hasIOAVService: true)
    }
    func readBrightness(displayID: CGDirectDisplayID) -> UInt16? { nil }
    func writeBrightness(displayID: CGDirectDisplayID, value: UInt16) -> Bool {
        lock.lock(); defer { lock.unlock() }
        _writes.append(value)
        return _succeeds
    }
    func readVolume(displayID: CGDirectDisplayID) -> UInt16? { nil }
    func writeVolume(displayID: CGDirectDisplayID, value: UInt16) -> Bool { true }
    func readMute(displayID: CGDirectDisplayID) -> Bool? { nil }
    func writeMute(displayID: CGDirectDisplayID, muted: Bool) -> Bool { true }
    func readInputSource(displayID: CGDirectDisplayID) -> DDCInputSource? { nil }
    func writeInputSource(displayID: CGDirectDisplayID, source: DDCInputSource) -> Bool { true }
}

// MARK: - Curve (pure)

final class CombinedBrightnessCurveTests: XCTestCase {
    private typealias Curve = CombinedBrightnessController

    private func extSDR(_ level: Double, knee: Double = 0.20) -> BrightnessCurveResult {
        Curve.calculateCurve(level: level, isBuiltIn: false, isHDREnabled: false, supportsDDC: true, kneePoint: knee)
    }

    func testExternalSDRDDCBoundaryMatrix() {
        let zero = extSDR(0.0)
        XCTAssertEqual(zero.ddcValue, 0)
        XCTAssertEqual(zero.overlayDimming, 0.75, accuracy: 1e-9)
        XCTAssertEqual(zero.method, .ddcWithDimming)

        let tenth = extSDR(0.10)
        XCTAssertEqual(tenth.ddcValue, 0)
        XCTAssertEqual(tenth.overlayDimming, 0.375, accuracy: 1e-9)
        XCTAssertEqual(tenth.method, .ddcWithDimming)

        let justBelow = extSDR(0.199)
        XCTAssertEqual(justBelow.ddcValue, 0)
        XCTAssertEqual(justBelow.overlayDimming, 0.00375, accuracy: 1e-9)
        XCTAssertEqual(justBelow.method, .ddcWithDimming)

        let knee = extSDR(0.20)
        XCTAssertEqual(knee.ddcValue, 0)
        XCTAssertEqual(knee.overlayDimming, 0)
        XCTAssertEqual(knee.method, .ddc)

        let sixty = extSDR(0.60)
        XCTAssertEqual(sixty.ddcValue, 50)
        XCTAssertEqual(sixty.overlayDimming, 0)
        XCTAssertEqual(sixty.method, .ddc)

        let full = extSDR(1.0)
        XCTAssertEqual(full.ddcValue, 100)
        XCTAssertEqual(full.overlayDimming, 0)
        XCTAssertEqual(full.method, .ddc)
    }

    func testDDCValueIsMonotonicAndBounded() {
        var previous: UInt16 = 0
        for step in 0...100 {
            let result = extSDR(Double(step) / 100.0)
            let value = result.ddcValue ?? 999
            XCTAssertLessThanOrEqual(value, 100)
            XCTAssertGreaterThanOrEqual(value, previous)
            XCTAssertLessThanOrEqual(result.overlayDimming, 0.75 + 1e-9)
            previous = value
        }
    }

    func testOverlayDimmingDecreasesAcrossKnee() {
        var previous = Double.infinity
        for step in 0...20 {
            let dim = extSDR(Double(step) / 100.0).overlayDimming
            XCTAssertLessThanOrEqual(dim, previous + 1e-12)
            previous = dim
        }
    }

    func testClampingOfOutOfRangeLevels() {
        XCTAssertEqual(extSDR(-5).ddcValue, 0)
        XCTAssertEqual(extSDR(-5).overlayDimming, 0.75, accuracy: 1e-9)
        XCTAssertEqual(extSDR(-5).method, .ddcWithDimming)
        XCTAssertEqual(extSDR(7).ddcValue, 100)
        XCTAssertEqual(extSDR(7).method, .ddc)

        let hdrLow = Curve.calculateCurve(level: -1, isBuiltIn: false, isHDREnabled: true, supportsDDC: true)
        XCTAssertEqual(hdrLow.overlayDimming, 0.80, accuracy: 1e-9)
        let hdrHigh = Curve.calculateCurve(level: 9, isBuiltIn: false, isHDREnabled: true, supportsDDC: true)
        XCTAssertEqual(hdrHigh.overlayDimming, 0, accuracy: 1e-9)
    }

    func testNonFiniteLevelsNeverProduceOutOfRangeOutput() {
        for bad in [Double.nan, .infinity, -.infinity] {
            for (builtIn, hdr, ddc) in [(false, false, true), (false, true, true), (false, false, false), (true, false, false)] {
                let r = Curve.calculateCurve(level: bad, isBuiltIn: builtIn, isHDREnabled: hdr, supportsDDC: ddc)
                XCTAssertTrue(r.overlayDimming.isFinite, "level \(bad)")
                XCTAssertGreaterThanOrEqual(r.overlayDimming, 0)
                XCTAssertLessThanOrEqual(r.overlayDimming, 0.80 + 1e-9)
                if let v = r.ddcValue { XCTAssertLessThanOrEqual(v, 100) }
            }
        }
        // NaN is treated as the lowest level.
        XCTAssertEqual(extSDR(.nan).method, .ddcWithDimming)
    }

    func testBuiltInAlwaysNativeWithoutOverlay() {
        for level in [0.0, 0.1, 0.5, 1.0, -3, 4] {
            for hdr in [false, true] {
                let r = Curve.calculateCurve(level: level, isBuiltIn: true, isHDREnabled: hdr, supportsDDC: true)
                XCTAssertNil(r.ddcValue)
                XCTAssertEqual(r.overlayDimming, 0)
                XCTAssertEqual(r.method, .nativeBuiltIn)
            }
        }
    }

    func testExternalHDRUsesSoftwareDimmingEvenWhenDDCIsSupported() {
        let half = Curve.calculateCurve(level: 0.5, isBuiltIn: false, isHDREnabled: true, supportsDDC: true)
        XCTAssertNil(half.ddcValue)
        XCTAssertEqual(half.overlayDimming, 0.40, accuracy: 1e-9)
        XCTAssertEqual(half.method, .softwareHDR)

        let quarter = Curve.calculateCurve(level: 0.25, isBuiltIn: false, isHDREnabled: true, supportsDDC: false)
        XCTAssertEqual(quarter.overlayDimming, 0.60, accuracy: 1e-9)
        XCTAssertEqual(quarter.method, .softwareHDR)

        let full = Curve.calculateCurve(level: 1.0, isBuiltIn: false, isHDREnabled: true, supportsDDC: true)
        XCTAssertEqual(full.overlayDimming, 0, accuracy: 1e-9)
    }

    func testExternalWithoutDDCUsesSoftwareFallback() {
        let r = Curve.calculateCurve(level: 0.3, isBuiltIn: false, isHDREnabled: false, supportsDDC: false)
        XCTAssertNil(r.ddcValue)
        XCTAssertEqual(r.overlayDimming, 0.56, accuracy: 1e-9)
        XCTAssertEqual(r.method, .softwareFallback)

        let full = Curve.calculateCurve(level: 1.0, isBuiltIn: false, isHDREnabled: false, supportsDDC: false)
        XCTAssertEqual(full.overlayDimming, 0, accuracy: 1e-9)
        let zero = Curve.calculateCurve(level: 0.0, isBuiltIn: false, isHDREnabled: false, supportsDDC: false)
        XCTAssertEqual(zero.overlayDimming, 0.80, accuracy: 1e-9)
    }

    func testCustomKneePoint() {
        let belowKnee = extSDR(0.25, knee: 0.5)
        XCTAssertEqual(belowKnee.ddcValue, 0)
        XCTAssertEqual(belowKnee.overlayDimming, 0.375, accuracy: 1e-9)
        XCTAssertEqual(belowKnee.method, .ddcWithDimming)

        let aboveKnee = extSDR(0.75, knee: 0.5)
        XCTAssertEqual(aboveKnee.ddcValue, 50)
        XCTAssertEqual(aboveKnee.method, .ddc)
    }

    func testDefaultKneeAndConstants() {
        XCTAssertEqual(CombinedBrightnessController.defaultKneePoint, 0.20)
        XCTAssertEqual(CombinedBrightnessController.kneeMaxDimming, 0.75)
        XCTAssertEqual(CombinedBrightnessController.softwareMaxDimming, 0.80)
        let implicit = Curve.calculateCurve(level: 0.6, isBuiltIn: false, isHDREnabled: false, supportsDDC: true)
        XCTAssertEqual(implicit.ddcValue, 50)
    }
}

// MARK: - Live controller (mock backends)

@MainActor
final class CombinedBrightnessControllerRuntimeTests: XCTestCase {
    private let displayID: CGDirectDisplayID = 4242
    private var overlay: RecordingOverlay!
    private var ddc: ScriptedDDC!
    private var controller: CombinedBrightnessController!

    override func setUp() async throws {
        overlay = RecordingOverlay()
        ddc = ScriptedDDC()
        controller = CombinedBrightnessController(displayBackend: nil, ddcBackend: ddc, overlay: overlay)
    }

    override func tearDown() async throws {
        overlay.removeAllOverlays()
    }

    func testDDCSuccessWritesHardwareAndClearsOverlay() {
        let method = controller.applyBrightness(0.6, for: displayID, supportsDDC: true, isHDREnabled: false)
        XCTAssertEqual(method, .ddc)
        XCTAssertEqual(ddc.writes, [50])
        XCTAssertEqual(overlay.dimming[displayID], 0)
        XCTAssertEqual(controller.method(for: displayID), .ddc)
        XCTAssertEqual(controller.level(for: displayID) ?? -1, 0.6, accuracy: 1e-9)
        XCTAssertFalse(controller.hasDDCFailed(for: displayID))
    }

    func testBelowKneeWritesZeroAndDimsOverlay() {
        let method = controller.applyBrightness(0.1, for: displayID, supportsDDC: true, isHDREnabled: false)
        XCTAssertEqual(method, .ddcWithDimming)
        XCTAssertEqual(ddc.writes, [0])
        XCTAssertEqual(overlay.dimming[displayID] ?? -1, 0.375, accuracy: 1e-9)
    }

    func testRuntimeDDCFailureFallsBackToSoftwareAndFiresCallback() {
        ddc.succeeds = false
        var changes: [(CGDirectDisplayID, BrightnessMethod)] = []
        controller.onMethodChange = { changes.append(($0, $1)) }

        let method = controller.applyBrightness(0.6, for: displayID, supportsDDC: true, isHDREnabled: false)

        XCTAssertEqual(method, .softwareFallback)
        XCTAssertEqual(ddc.writes, [50], "one attempt was made")
        XCTAssertEqual(overlay.dimming[displayID] ?? -1, 0.32, accuracy: 1e-9, "(1 - 0.6) * 0.8")
        XCTAssertTrue(controller.hasDDCFailed(for: displayID))
        XCTAssertEqual(controller.method(for: displayID), .softwareFallback)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.0, displayID)
        XCTAssertEqual(changes.first?.1, .softwareFallback)
    }

    func testAfterFailureDDCIsNotRetriedUntilReset() {
        ddc.succeeds = false
        controller.applyBrightness(0.6, for: displayID, supportsDDC: true, isHDREnabled: false)
        ddc.succeeds = true
        let again = controller.applyBrightness(0.7, for: displayID, supportsDDC: true, isHDREnabled: false)
        XCTAssertEqual(again, .softwareFallback)
        XCTAssertEqual(ddc.writes.count, 1, "no further DDC traffic while marked failed")

        controller.resetDDCFailure(for: displayID)
        let retried = controller.applyBrightness(0.7, for: displayID, supportsDDC: true, isHDREnabled: false)
        XCTAssertEqual(retried, .ddc)
        XCTAssertEqual(ddc.writes.count, 2)
        XCTAssertEqual(overlay.dimming[displayID], 0)
    }

    func testHDRTransitionClearsFailureFlagAndUsesSoftwareHDR() {
        ddc.succeeds = false
        controller.applyBrightness(0.5, for: displayID, supportsDDC: true, isHDREnabled: false)
        XCTAssertTrue(controller.hasDDCFailed(for: displayID))

        let hdr = controller.applyBrightness(0.5, for: displayID, supportsDDC: true, isHDREnabled: true)
        XCTAssertEqual(hdr, .softwareHDR)
        XCTAssertFalse(controller.hasDDCFailed(for: displayID), "HDR transitions retry DDC")
        XCTAssertEqual(overlay.dimming[displayID] ?? -1, 0.40, accuracy: 1e-9)
        XCTAssertEqual(ddc.writes.count, 1, "HDR never writes DDC")

        ddc.succeeds = true
        let sdr = controller.applyBrightness(0.5, for: displayID, supportsDDC: true, isHDREnabled: false)
        XCTAssertEqual(sdr, .ddc)
        XCTAssertEqual(overlay.dimming[displayID], 0)
    }

    func testNoDDCSupportOrNoBackendUsesSoftwareFallbackWithoutWrites() {
        XCTAssertEqual(controller.applyBrightness(0.5, for: displayID, supportsDDC: false, isHDREnabled: false), .softwareFallback)
        XCTAssertTrue(ddc.writes.isEmpty)

        let noBackend = CombinedBrightnessController(ddcBackend: nil, overlay: overlay)
        XCTAssertEqual(noBackend.applyBrightness(0.5, for: 9, supportsDDC: true, isHDREnabled: false), .softwareFallback)
        XCTAssertEqual(overlay.dimming[9] ?? -1, 0.40, accuracy: 1e-9)
    }

    func testBuiltInUsesSetterAndNeverTouchesDDCOrOverlayDimming() {
        var applied: [Double] = []
        let method = controller.applyBrightness(1.7, for: 1, supportsDDC: true, isHDREnabled: false, builtInSetter: { applied.append($0) })
        XCTAssertEqual(method, .nativeBuiltIn)
        XCTAssertEqual(applied, [1.0], "level is clamped before reaching the setter")
        XCTAssertTrue(ddc.writes.isEmpty)
        XCTAssertEqual(overlay.dimming[1], 0)
    }

    func testStepBrightnessStartsFromHalfAndClamps() {
        let display = DisplayInfo(
            id: displayID, identifier: DisplayIdentifier(vendorNumber: 1, modelNumber: 1), name: "ext",
            isBuiltIn: false, isMain: false, isOnline: true, isEnabled: true, supportsDDC: true
        )
        let up = controller.stepBrightness(by: 0.0625, for: display)
        XCTAssertEqual(up.level, 0.5625, accuracy: 1e-9)
        XCTAssertEqual(up.method, .ddc)

        let clampedTop = controller.stepBrightness(by: 5, for: display)
        XCTAssertEqual(clampedTop.level, 1.0)
        let clampedBottom = controller.stepBrightness(by: -5, for: display)
        XCTAssertEqual(clampedBottom.level, 0.0)
        XCTAssertEqual(clampedBottom.method, .ddcWithDimming)
    }

    func testForgetClearsStateAndOverlay() {
        controller.applyBrightness(0.1, for: displayID, supportsDDC: true, isHDREnabled: false)
        XCTAssertGreaterThan(overlay.dimming[displayID] ?? 0, 0)
        controller.forget(displayID: displayID)
        XCTAssertNil(controller.level(for: displayID))
        XCTAssertNil(controller.method(for: displayID))
        XCTAssertEqual(overlay.dimming[displayID], 0)
    }

    func testAsyncDDCFailureFallsBackAndNotifiesOnMainActor() async {
        controller.asyncDDCWrites = true
        ddc.succeeds = false
        let notified = expectation(description: "onMethodChange fired after async DDC failure")
        var received: (CGDirectDisplayID, BrightnessMethod)?
        controller.onMethodChange = { id, method in
            received = (id, method)
            XCTAssertTrue(Thread.isMainThread)
            notified.fulfill()
        }

        let immediate = controller.applyBrightness(0.6, for: displayID, supportsDDC: true, isHDREnabled: false)
        XCTAssertEqual(immediate, .ddc, "optimistic until the write completes")

        await fulfillment(of: [notified], timeout: 3)
        XCTAssertEqual(received?.0, displayID)
        XCTAssertEqual(received?.1, .softwareFallback)
        XCTAssertEqual(overlay.dimming[displayID] ?? -1, 0.32, accuracy: 1e-9)
        XCTAssertTrue(controller.hasDDCFailed(for: displayID))
    }

    func testAsyncDDCSuccessKeepsDDCMethod() async {
        controller.asyncDDCWrites = true
        controller.applyBrightness(0.6, for: displayID, supportsDDC: true, isHDREnabled: false)
        let deadline = Date().addingTimeInterval(3)
        while ddc.writes.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(ddc.writes, [50])
        XCTAssertEqual(controller.method(for: displayID), .ddc)
        XCTAssertFalse(controller.hasDDCFailed(for: displayID))
    }
}

// MARK: - OverlayManager (real windows, never touches hardware brightness)

@MainActor
final class OverlayManagerTests: XCTestCase {
    private var manager: OverlayManager!

    override func setUp() async throws {
        _ = NSApplication.shared
        manager = OverlayManager()
    }

    override func tearDown() async throws {
        manager.removeAllOverlays()
        manager = nil
    }

    private func requireMainScreen() throws -> CGDirectDisplayID {
        let id = CGMainDisplayID()
        try XCTSkipIf(OverlayManager.screen(for: id) == nil, "no NSScreen available for the main display (headless)")
        return id
    }

    func testClampingHelpers() {
        XCTAssertEqual(OverlayManager.clampDimming(-1), 0)
        XCTAssertEqual(OverlayManager.clampDimming(0.5), 0.5)
        XCTAssertEqual(OverlayManager.clampDimming(0.85), 0.85)
        XCTAssertEqual(OverlayManager.clampDimming(3), 0.85)
        XCTAssertEqual(OverlayManager.clampDimming(.nan), 0)
        XCTAssertEqual(OverlayManager.clampDimming(.infinity), 0)
        XCTAssertEqual(OverlayManager.clampWarmth(-0.2), 0)
        XCTAssertEqual(OverlayManager.clampWarmth(0.3), 0.3)
        XCTAssertEqual(OverlayManager.clampWarmth(9), 1)
        XCTAssertEqual(OverlayManager.clampWarmth(.nan), 0)
        XCTAssertEqual(OverlayManager.maxDimming, 0.85)
    }

    func testStateIsClampedAndStoredEvenWithoutAScreen() {
        let fake: CGDirectDisplayID = 0x7FFF_0001
        manager.setDimmingLevel(displayID: fake, level: 2.0)
        manager.setNightShiftWarmth(displayID: fake, warmth: 5.0)
        var state = manager.overlayState(for: fake)
        XCTAssertEqual(state.dimming, 0.85)
        XCTAssertEqual(state.warmth, 1.0)
        XCTAssertFalse(state.hasWindow, "no NSScreen for a fake display id")
        XCTAssertNil(manager.overlayWindow(for: fake))

        manager.setDimmingLevel(displayID: fake, level: -4)
        manager.setNightShiftWarmth(displayID: fake, warmth: -4)
        state = manager.overlayState(for: fake)
        XCTAssertEqual(state.dimming, 0)
        XCTAssertEqual(state.warmth, 0)
    }

    func testUnknownDisplayReportsNeutralState() {
        let state = manager.overlayState(for: 0x7FFF_0002)
        XCTAssertEqual(state.dimming, 0)
        XCTAssertEqual(state.warmth, 0)
        XCTAssertFalse(state.hasWindow)
    }

    func testWindowIsCaptureInvisibleClickThroughAndNonActivating() throws {
        let id = try requireMainScreen()
        manager.setDimmingLevel(displayID: id, level: 0.05)

        let window = try XCTUnwrap(manager.overlayWindow(for: id))
        XCTAssertEqual(window.sharingType, .none, "overlay must stay out of screenshots / screen sharing")
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)
        XCTAssertFalse(window.hasShadow)
        XCTAssertEqual(window.level, .screenSaver)
        XCTAssertEqual(window.styleMask, .borderless)
        XCTAssertEqual(window.collectionBehavior, [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary])
        XCTAssertFalse(window.canBecomeKey)
        XCTAssertFalse(window.canBecomeMain)
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertEqual(window.frame, OverlayManager.screen(for: id)?.frame)
        XCTAssertTrue(manager.overlayState(for: id).hasWindow)
    }

    func testDimmingAndWarmthCombineOnOneWindowAndWindowDropsWhenNeutral() throws {
        let id = try requireMainScreen()
        manager.setDimmingLevel(displayID: id, level: 0.05)
        let first = manager.overlayWindow(for: id)
        manager.setNightShiftWarmth(displayID: id, warmth: 0.1)
        XCTAssertTrue(first === manager.overlayWindow(for: id), "one window per display")
        var state = manager.overlayState(for: id)
        XCTAssertEqual(state.dimming, 0.05, accuracy: 1e-9)
        XCTAssertEqual(state.warmth, 0.1, accuracy: 1e-9)

        manager.setDimmingLevel(displayID: id, level: 0)
        XCTAssertTrue(manager.overlayState(for: id).hasWindow, "warmth alone keeps the window")
        XCTAssertEqual(manager.overlayState(for: id).warmth, 0.1, accuracy: 1e-9)

        manager.setNightShiftWarmth(displayID: id, warmth: 0)
        state = manager.overlayState(for: id)
        XCTAssertFalse(state.hasWindow, "window is dropped once both layers are neutral")
        XCTAssertNil(manager.overlayWindow(for: id))
    }

    func testRemoveAllOverlaysResetsEverything() throws {
        let id = try requireMainScreen()
        manager.setDimmingLevel(displayID: id, level: 0.05)
        manager.setNightShiftWarmth(displayID: 0x7FFF_0003, warmth: 0.4)
        XCTAssertEqual(Set(manager.activeOverlayDisplayIDs), [id, 0x7FFF_0003])

        manager.removeAllOverlays()

        XCTAssertNil(manager.overlayWindow(for: id))
        XCTAssertEqual(manager.overlayState(for: id).dimming, 0)
        XCTAssertEqual(manager.overlayState(for: 0x7FFF_0003).warmth, 0)
        XCTAssertTrue(manager.activeOverlayDisplayIDs.isEmpty)
    }

    func testRemoveOverlayForSingleDisplayAndResetAll() throws {
        let id = try requireMainScreen()
        manager.setDimmingLevel(displayID: id, level: 0.05)
        manager.setDimmingLevel(displayID: 0x7FFF_0004, level: 0.2)

        manager.removeOverlay(for: id)
        XCTAssertNil(manager.overlayWindow(for: id))
        XCTAssertEqual(manager.overlayState(for: 0x7FFF_0004).dimming, 0.2, accuracy: 1e-9)

        manager.resetAllToNeutral()
        XCTAssertEqual(manager.overlayState(for: 0x7FFF_0004).dimming, 0)
    }

    func testOverlayWindowLevelConstantSitsBelowOSD() {
        XCTAssertEqual(OverlayManager.overlayWindowLevel, .screenSaver)
    }
}
