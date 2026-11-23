import AppKit
import CoreGraphics
import Foundation

// MARK: - FailsafeTrigger

public enum FailsafeTrigger: String, Sendable, CaseIterable {
    case displayReconfiguration
    case wake
    case quit
    case emergency
    case manualCheck
}

// MARK: - FailsafeWatchdog

/// Zero Black-Screen Guarantee (SPEC §3.2).
///
/// Re-enables the Built-in Display whenever it is soft-disconnected and **no** online & active external
/// display remains — on every display reconfiguration (cable unplug, monitor power-off), on system/screen
/// wake (plus delayed re-checks while DisplayPort/USB-C link training settles), on app quit, and on the
/// emergency hotkey.
///
/// Depends only on `DisplayBackendProtocol`, so it is fully testable with a mock backend
/// (`observeDisplayReconfiguration: false`, a private `NotificationCenter`, then call `checkNow`,
/// `handleDisplayReconfiguration`, `handleWake` + `waitUntilIdle`).
public final class FailsafeWatchdog: @unchecked Sendable {
    public typealias RestoreHandler = @Sendable (FailsafeTrigger) -> Void

    private let backend: DisplayBackendProtocol
    private let notificationCenter: NotificationCenter
    private let observeDisplayReconfiguration: Bool
    private let wakeRecheckDelays: [TimeInterval]
    private let reconfigurationRecheckDelay: TimeInterval
    private let queue: DispatchQueue
    private let onRestore: RestoreHandler?

    private let lock = NSLock()
    private var running = false
    private var callbackRegistered = false
    private var wakeObservers: [NSObjectProtocol] = []
    private var reconfigurationCheckPending = false
    private var recheckGeneration = 0
    /// Bumped on every `start()`/`stop()` so delayed checks scheduled in a previous lifecycle are dropped.
    private var lifecycleGeneration = 0

    /// - Parameters:
    ///   - backend: display backend (live `DisplayManager` or a mock).
    ///   - notificationCenter: where wake notifications are observed (defaults to `NSWorkspace`'s center).
    ///   - observeDisplayReconfiguration: register a `CGDisplayRegisterReconfigurationCallback` on `start()`.
    ///   - wakeRecheckDelays: additional checks after wake while external displays re-handshake.
    ///   - reconfigurationRecheckDelay: one follow-up check after a burst of reconfiguration events (`0` disables).
    ///   - queue: serial queue for evaluations (defaults to a private user-interactive queue).
    ///   - onRestore: called after the watchdog restored the Built-in Display (e.g. to show an OSD notice
    ///     and reset overlays). Called on the watchdog queue (or the caller's thread for quit/emergency).
    public init(
        backend: DisplayBackendProtocol,
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        observeDisplayReconfiguration: Bool = true,
        wakeRecheckDelays: [TimeInterval] = [1.5, 4.0],
        reconfigurationRecheckDelay: TimeInterval = 1.0,
        queue: DispatchQueue? = nil,
        onRestore: RestoreHandler? = nil
    ) {
        self.backend = backend
        self.notificationCenter = notificationCenter
        self.observeDisplayReconfiguration = observeDisplayReconfiguration
        self.wakeRecheckDelays = wakeRecheckDelays.filter { $0 > 0 }
        self.reconfigurationRecheckDelay = max(0, reconfigurationRecheckDelay)
        self.queue = queue ?? DispatchQueue(label: "com.piszeprogramy.openbetterdisplay.failsafe", qos: .userInteractive)
        self.onRestore = onRestore
    }

    deinit {
        stop()
    }

    // MARK: Lifecycle

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// Starts observing reconfiguration + wake events and performs an immediate safety check.
    public func start() {
        lock.lock()
        guard !running else {
            lock.unlock()
            return
        }
        running = true
        lifecycleGeneration += 1
        let center = notificationCenter
        var observers: [NSObjectProtocol] = []
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.handleWake()
            })
        }
        wakeObservers = observers
        let shouldRegister = observeDisplayReconfiguration && !callbackRegistered
        if shouldRegister { callbackRegistered = true }
        lock.unlock()

        if shouldRegister {
            CGDisplayRegisterReconfigurationCallback(FailsafeWatchdog.reconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
        }
        queue.async { [weak self] in self?.checkNow(trigger: .manualCheck) }
    }

    public func stop() {
        lock.lock()
        running = false
        let observers = wakeObservers
        wakeObservers = []
        let shouldUnregister = callbackRegistered
        callbackRegistered = false
        recheckGeneration += 1
        lifecycleGeneration += 1
        lock.unlock()

        observers.forEach { notificationCenter.removeObserver($0) }
        if shouldUnregister {
            CGDisplayRemoveReconfigurationCallback(FailsafeWatchdog.reconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    /// Blocks until all queued evaluations have run (for tests).
    public func waitUntilIdle() {
        queue.sync {}
    }

    // MARK: Policy (pure)

    /// `true` when the Built-in Display is soft-disconnected and zero online & enabled external displays remain.
    public static func shouldRestoreBuiltIn(builtInEnabled: Bool, displays: [DisplayInfo]) -> Bool {
        guard !builtInEnabled else { return false }
        return !displays.contains { !$0.isBuiltIn && $0.isOnline && $0.isEnabled }
    }

    // MARK: Evaluation

    /// Synchronously evaluates the failsafe policy and restores the Built-in Display if required.
    /// - Returns: `true` if a restore was performed successfully.
    @discardableResult
    public func checkNow(trigger: FailsafeTrigger) -> Bool {
        guard !backend.isBuiltInDisplayEnabled() else { return false }
        guard Self.shouldRestoreBuiltIn(builtInEnabled: false, displays: backend.getOnlineDisplays()) else { return false }
        return restoreBuiltIn(trigger: trigger)
    }

    /// Display reconfiguration event: evaluates immediately (coalesced) plus one delayed follow-up check.
    public func handleDisplayReconfiguration() {
        lock.lock()
        let alreadyPending = reconfigurationCheckPending
        reconfigurationCheckPending = true
        recheckGeneration += 1
        let generation = recheckGeneration
        lock.unlock()

        if !alreadyPending {
            queue.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.reconfigurationCheckPending = false
                self.lock.unlock()
                self.checkNow(trigger: .displayReconfiguration)
            }
        }
        if reconfigurationRecheckDelay > 0 {
            queue.asyncAfter(deadline: .now() + reconfigurationRecheckDelay) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let current = self.recheckGeneration == generation
                self.lock.unlock()
                if current { self.checkNow(trigger: .displayReconfiguration) }
            }
        }
    }

    /// System / screen wake: immediate check plus delayed re-checks (cancelled by `stop()`).
    public func handleWake() {
        lock.lock()
        let lifecycle = lifecycleGeneration
        lock.unlock()

        queue.async { [weak self] in self?.checkNow(trigger: .wake) }
        for delay in wakeRecheckDelays {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isCurrentLifecycle(lifecycle) else { return }
                self.checkNow(trigger: .wake)
            }
        }
    }

    private func isCurrentLifecycle(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running && lifecycleGeneration == generation
    }

    // MARK: Explicit restores

    /// Synchronously re-enables the Built-in Display before the app terminates (call from
    /// `applicationWillTerminate`). Unconditional with respect to external displays.
    /// - Returns: `true` if the Built-in Display is enabled afterwards (or there is none).
    @discardableResult
    public func restoreBuiltInForQuit() -> Bool {
        guard !backend.isBuiltInDisplayEnabled() else { return true }
        return restoreBuiltIn(trigger: .quit)
    }

    /// Emergency restore (hotkey): enables all online displays, un-mirrors, and guarantees the Built-in
    /// Display is on. Synchronous. Returns `true` if the Built-in Display ends up enabled.
    @discardableResult
    public func emergencyRestoreAll() -> Bool {
        try? backend.emergencyRestoreAllDisplays()
        if !backend.isBuiltInDisplayEnabled() {
            try? backend.setBuiltInDisplayEnabled(true)
        }
        let succeeded = backend.isBuiltInDisplayEnabled()
        onRestore?(.emergency)
        return succeeded
    }

    private func restoreBuiltIn(trigger: FailsafeTrigger) -> Bool {
        do {
            try backend.setBuiltInDisplayEnabled(true)
        } catch {
            // Fallback: full emergency restore.
            try? backend.emergencyRestoreAllDisplays()
        }
        let restored = backend.isBuiltInDisplayEnabled()
        if restored { onRestore?(trigger) }
        return restored
    }

    // MARK: CoreGraphics callback

    private static let reconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
        guard let userInfo, !flags.contains(.beginConfigurationFlag) else { return }
        let watchdog = Unmanaged<FailsafeWatchdog>.fromOpaque(userInfo).takeUnretainedValue()
        guard watchdog.isRunning else { return }
        watchdog.handleDisplayReconfiguration()
    }
}
