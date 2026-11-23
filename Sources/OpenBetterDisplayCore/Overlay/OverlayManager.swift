import Cocoa
import CoreGraphics
import QuartzCore

/// Per-display software dimming + warm Night Shift tint using click-through, capture-invisible windows.
@MainActor
public final class OverlayManager: OverlayBackendProtocol {
    public static let maxDimming: Double = 0.85
    /// Window level shared by overlays; the OSD HUD sits one level above.
    public static let overlayWindowLevel = NSWindow.Level.screenSaver

    private struct State {
        var dimming: Double = 0
        var warmth: Double = 0
        var isNeutral: Bool { dimming <= 0.0001 && warmth <= 0.0001 }
    }

    private var states: [CGDirectDisplayID: State] = [:]
    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    private var dimLayers: [CGDirectDisplayID: CALayer] = [:]
    private var tintLayers: [CGDirectDisplayID: CALayer] = [:]
    private var screenObserver: NSObjectProtocol?

    /// Maximum alpha of the warm tint layer at warmth = 1.0.
    public static let maxTintAlpha: Double = 0.45

    public init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshAllWindows()
            }
        }
    }

    deinit {
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - OverlayBackendProtocol

    public func setDimmingLevel(displayID: CGDirectDisplayID, level: Double) {
        var state = states[displayID] ?? State()
        state.dimming = OverlayManager.clampDimming(level)
        states[displayID] = state
        apply(displayID: displayID)
    }

    public func setNightShiftWarmth(displayID: CGDirectDisplayID, warmth: Double) {
        var state = states[displayID] ?? State()
        state.warmth = OverlayManager.clampWarmth(warmth)
        states[displayID] = state
        apply(displayID: displayID)
    }

    public func removeAllOverlays() {
        for window in windows.values {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        dimLayers.removeAll()
        tintLayers.removeAll()
        states.removeAll()
    }

    // MARK: - Extras

    /// Removes the overlay for a single display (e.g. when it disconnects).
    public func removeOverlay(for displayID: CGDirectDisplayID) {
        states.removeValue(forKey: displayID)
        tearDownWindow(displayID)
    }

    /// Neutralises dimming and warmth everywhere (emergency restore).
    public func resetAllToNeutral() {
        removeAllOverlays()
    }

    public static func clampDimming(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), maxDimming)
    }

    public static func clampWarmth(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    // MARK: - Inspection (unit tests / diagnostics)

    public func overlayState(for displayID: CGDirectDisplayID) -> (dimming: Double, warmth: Double, hasWindow: Bool) {
        let s = states[displayID] ?? State()
        return (s.dimming, s.warmth, windows[displayID] != nil)
    }

    public func overlayWindow(for displayID: CGDirectDisplayID) -> NSWindow? {
        windows[displayID]
    }

    public var activeOverlayDisplayIDs: [CGDirectDisplayID] {
        Array(states.keys)
    }

    // MARK: - Window management

    public static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    private func apply(displayID: CGDirectDisplayID) {
        guard let state = states[displayID] else { return }
        if state.isNeutral {
            tearDownWindow(displayID)
            return
        }
        guard let screen = OverlayManager.screen(for: displayID) else {
            tearDownWindow(displayID)
            return
        }
        let window = windows[displayID] ?? makeWindow(displayID: displayID, screen: screen)
        if window.frame != screen.frame {
            window.setFrame(screen.frame, display: false)
        }
        dimLayers[displayID]?.backgroundColor = NSColor.black.withAlphaComponent(state.dimming).cgColor
        tintLayers[displayID]?.backgroundColor = NSColor(
            calibratedRed: 1.0, green: 0.55, blue: 0.12, alpha: state.warmth * OverlayManager.maxTintAlpha
        ).cgColor
        // Never activate / steal focus.
        window.orderFrontRegardless()
    }

    private func refreshAllWindows() {
        for displayID in Array(states.keys) {
            apply(displayID: displayID)
        }
        // Drop windows for displays that vanished.
        for displayID in Array(windows.keys) where OverlayManager.screen(for: displayID) == nil {
            tearDownWindow(displayID)
        }
    }

    private func makeWindow(displayID: CGDirectDisplayID, screen: NSScreen) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isReleasedWhenClosed = false
        window.level = OverlayManager.overlayWindowLevel
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.sharingType = .none
        window.canHide = false
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true
        content.autoresizingMask = [.width, .height]
        let root = content.layer ?? CALayer()
        root.backgroundColor = NSColor.clear.cgColor

        let tint = CALayer()
        tint.frame = content.bounds
        tint.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        tint.backgroundColor = NSColor.clear.cgColor
        let dim = CALayer()
        dim.frame = content.bounds
        dim.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        dim.backgroundColor = NSColor.clear.cgColor
        root.addSublayer(tint)
        root.addSublayer(dim)

        window.contentView = content
        windows[displayID] = window
        tintLayers[displayID] = tint
        dimLayers[displayID] = dim
        return window
    }

    private func tearDownWindow(_ displayID: CGDirectDisplayID) {
        if let window = windows.removeValue(forKey: displayID) {
            window.orderOut(nil)
            window.close()
        }
        dimLayers.removeValue(forKey: displayID)
        tintLayers.removeValue(forKey: displayID)
    }
}
