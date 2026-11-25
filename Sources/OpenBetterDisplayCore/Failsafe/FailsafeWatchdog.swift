import AppKit
import CoreGraphics
import Foundation
import os

private let failsafeLogger = Logger(subsystem: "com.piszeprogramy.openbetterdisplay", category: "failsafe")

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
/// Re-enables the Built-in Display whenever it is soft-disconnected and **no** online & active physical
/// external display remains (ignoring WindowServer headless/virtual placeholder displays) for at least
/// `disconnectGracePeriod` (default **5 seconds**, tolerating brief cable glitches / link retraining).
///
/// Safety layers:
/// 1. `CGDisplayRegisterReconfigurationCallback` (cable unplug, monitor power-off).
/// 2. Periodic heartbeat timer (`pollInterval`, default 1s) so missed/delayed CG callbacks can never brick the Mac.
/// 3. System / screen sleep & wake observers (pauses countdown during idle display sleep while a physical
///    external display remains online; checks on wake).
/// 4. Immediate synchronous restore on app quit (`restoreBuiltInForQuit`) and emergency hotkey (`emergencyRestoreAll`).
///
/// Depends only on `DisplayBackendProtocol`, so it is fully testable with a mock backend and injected clock.
public final class FailsafeWatchdog: @unchecked Sendable {
    public typealias RestoreHandler = @Sendable (FailsafeTrigger) -> Void

    /// Minimum continuous time without any active physical external display before automatically
    /// re-enabling the Built-in Display (prevents flicker on brief cable drops / link retraining).
    public static let defaultDisconnectGracePeriod: TimeInterval = 5.0
    /// Heartbeat polling interval while running. Cheap no-op when Built-in is already enabled.
    public static let defaultPollInterval: TimeInterval = 1.0

    private let backend: DisplayBackendProtocol
    private let notificationCenter: NotificationCenter
    private let observeDisplayReconfiguration: Bool
    private let disconnectGracePeriod: TimeInterval
    private let pollInterval: TimeInterval
    private let wakeRecheckDelays: [TimeInterval]
    private let reconfigurationRecheckDelay: TimeInterval
    private let now: @Sendable () -> Date
    private let queue: DispatchQueue
    private let onRestore: RestoreHandler?

    private let lock = NSLock()
    private var running = false
    private var callbackRegistered = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var reconfigurationCheckPending = false
    private var recheckGeneration = 0
    /// Bumped on every `start()`/`stop()` so delayed checks scheduled in a previous lifecycle are dropped.
    private var lifecycleGeneration = 0
    private var screensAsleep = false
    /// Timestamp when the watchdog first observed Built-in OFF with zero active physical external displays.
    private var headlessSince: Date?
    private var pendingTrigger: FailsafeTrigger = .displayReconfiguration
    private var graceWorkItem: DispatchWorkItem?
    private var pollTimer: DispatchSourceTimer?

    /// - Parameters:
    ///   - backend: display backend (live `DisplayManager` or a mock).
    ///   - notificationCenter: where sleep/wake notifications are observed (defaults to `NSWorkspace`'s center).
    ///   - observeDisplayReconfiguration: register a `CGDisplayRegisterReconfigurationCallback` on `start()`.
    ///   - disconnectGracePeriod: minimum continuous seconds without an active physical external display before
    ///     restoring Built-in (`0` restores immediately; defaults to `5.0`).
    ///   - pollInterval: periodic heartbeat interval in seconds (`0` disables polling; defaults to `1.0`).
    ///   - wakeRecheckDelays: additional checks after wake while external displays re-handshake.
    ///   - reconfigurationRecheckDelay: one follow-up check after a burst of reconfiguration events (`0` disables).
    ///   - now: clock source (injectable for deterministic tests).
    ///   - queue: serial queue for evaluations (defaults to a private user-interactive queue).
    ///   - onRestore: called after the watchdog restored the Built-in Display (e.g. to show an OSD notice
    ///     and reset overlays). Called on the watchdog queue (or the caller's thread for quit/emergency).
    public init(
        backend: DisplayBackendProtocol,
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        observeDisplayReconfiguration: Bool = true,
        disconnectGracePeriod: TimeInterval = FailsafeWatchdog.defaultDisconnectGracePeriod,
        pollInterval: TimeInterval = FailsafeWatchdog.defaultPollInterval,
        wakeRecheckDelays: [TimeInterval] = [1.5, 4.0],
        reconfigurationRecheckDelay: TimeInterval = 1.0,
        now: @escaping @Sendable () -> Date = { Date() },
        queue: DispatchQueue? = nil,
        onRestore: RestoreHandler? = nil
    ) {
        self.backend = backend
        self.notificationCenter = notificationCenter
        self.observeDisplayReconfiguration = observeDisplayReconfiguration
        self.disconnectGracePeriod = max(0, disconnectGracePeriod)
        self.pollInterval = max(0, pollInterval)
        self.wakeRecheckDelays = wakeRecheckDelays.filter { $0 > 0 }
        self.reconfigurationRecheckDelay = max(0, reconfigurationRecheckDelay)
        self.now = now
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

    /// `true` while a disconnect grace countdown is actively waiting for an external monitor to return.
    public var isGraceCountdownActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return headlessSince != nil
    }

    /// Starts observing reconfiguration + sleep/wake events, starts the periodic heartbeat timer,
    /// and performs an immediate safety check.
    public func start() {
        lock.lock()
        guard !running else {
            lock.unlock()
            return
        }
        running = true
        screensAsleep = false
        headlessSince = nil
        lifecycleGeneration += 1
        let lifecycle = lifecycleGeneration
        let center = notificationCenter
        var observers: [NSObjectProtocol] = []
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.handleWake()
            })
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.handleSleep()
            })
        }
        workspaceObservers = observers
        let shouldRegister = observeDisplayReconfiguration && !callbackRegistered
        if shouldRegister { callbackRegistered = true }

        if pollInterval > 0 {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            let intervalMs = max(50, Int((pollInterval * 1000).rounded()))
            timer.schedule(deadline: .now() + .milliseconds(intervalMs), repeating: .milliseconds(intervalMs))
            timer.setEventHandler { [weak self] in
                guard let self, self.isCurrentLifecycle(lifecycle) else { return }
                self.evaluateWithGracePeriod(trigger: .displayReconfiguration, isHeartbeat: true)
            }
            pollTimer = timer
            timer.resume()
        }
        lock.unlock()

        if shouldRegister {
            CGDisplayRegisterReconfigurationCallback(FailsafeWatchdog.reconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
        }
        queue.async { [weak self] in self?.checkNow(trigger: .manualCheck) }
    }

    public func stop() {
        lock.lock()
        running = false
        let observers = workspaceObservers
        workspaceObservers = []
        let shouldUnregister = callbackRegistered
        callbackRegistered = false
        recheckGeneration += 1
        lifecycleGeneration += 1
        screensAsleep = false
        headlessSince = nil
        let workItem = graceWorkItem
        graceWorkItem = nil
        let timer = pollTimer
        pollTimer = nil
        lock.unlock()

        workItem?.cancel()
        timer?.cancel()
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

    /// `true` when the Built-in Display is soft-disconnected and zero online & enabled **physical**
    /// external displays remain (virtual/headless placeholder framebuffers are ignored).
    public static func shouldRestoreBuiltIn(builtInEnabled: Bool, displays: [DisplayInfo]) -> Bool {
        guard !builtInEnabled else { return false }
        return !displays.contains { !$0.isBuiltIn && !$0.isVirtual && $0.isOnline && $0.isEnabled }
    }

    /// `true` when at least one physical external display is still online (even if sleeping).
    static func hasOnlinePhysicalExternal(displays: [DisplayInfo]) -> Bool {
        displays.contains { !$0.isBuiltIn && !$0.isVirtual && $0.isOnline }
    }

    // MARK: Evaluation

    /// Synchronously evaluates the failsafe policy and restores the Built-in Display immediately
    /// (bypassing `disconnectGracePeriod`).
    /// - Returns: `true` if a restore was performed successfully.
    @discardableResult
    public func checkNow(trigger: FailsafeTrigger) -> Bool {
        guard !backend.isBuiltInDisplayEnabled() else {
            clearGraceCountdown()
            return false
        }
        guard Self.shouldRestoreBuiltIn(builtInEnabled: false, displays: backend.getOnlineDisplays()) else {
            clearGraceCountdown()
            return false
        }
        let restored = restoreBuiltIn(trigger: trigger)
        if restored { clearGraceCountdown() }
        return restored
    }

    /// Display reconfiguration event: evaluates with `disconnectGracePeriod` (coalesced) plus one delayed follow-up check.
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
                self.evaluateWithGracePeriod(trigger: .displayReconfiguration, isHeartbeat: false)
            }
        }
        if reconfigurationRecheckDelay > 0 {
            queue.asyncAfter(deadline: .now() + reconfigurationRecheckDelay) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let current = self.recheckGeneration == generation
                self.lock.unlock()
                if current { self.evaluateWithGracePeriod(trigger: .displayReconfiguration, isHeartbeat: false) }
            }
        }
    }

    /// System / screen sleep: pauses any pending grace countdown so normal idle display sleep
    /// (while the external cable is still plugged in) does not falsely wake the Built-in Display.
    public func handleSleep() {
        lock.lock()
        screensAsleep = true
        headlessSince = nil
        let workItem = graceWorkItem
        graceWorkItem = nil
        lock.unlock()
        workItem?.cancel()
    }

    /// System / screen wake: resumes monitoring with a fresh grace window plus delayed re-checks (cancelled by `stop()`).
    public func handleWake() {
        lock.lock()
        screensAsleep = false
        headlessSince = nil
        let workItem = graceWorkItem
        graceWorkItem = nil
        let lifecycle = lifecycleGeneration
        lock.unlock()
        workItem?.cancel()

        queue.async { [weak self] in self?.evaluateWithGracePeriod(trigger: .wake, isHeartbeat: false) }
        for delay in wakeRecheckDelays {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isCurrentLifecycle(lifecycle) else { return }
                self.evaluateWithGracePeriod(trigger: .wake, isHeartbeat: false)
            }
        }
    }

    /// Core grace-period state machine. Runs on `queue`.
    private func evaluateWithGracePeriod(trigger: FailsafeTrigger, isHeartbeat: Bool) {
        // Fast path: Built-in is already ON → nothing to protect.
        guard !backend.isBuiltInDisplayEnabled() else {
            clearGraceCountdown()
            return
        }

        let displays = backend.getOnlineDisplays()

        // During idle display sleep with the external cable still physically attached (online, just asleep),
        // don't wake the Built-in Display. If the cable was physically unplugged (0 online physical externals),
        // proceed normally so unplugging during sleep still recovers.
        lock.lock()
        let asleep = screensAsleep
        lock.unlock()
        if asleep && Self.hasOnlinePhysicalExternal(displays: displays) {
            clearGraceCountdown()
            return
        }

        guard Self.shouldRestoreBuiltIn(builtInEnabled: false, displays: displays) else {
            // A real physical external display is active (or returned within the grace period).
            if isGraceCountdownActive {
                failsafeLogger.notice("Physical external display returned within grace period — cancelling Built-in restore countdown")
            }
            clearGraceCountdown()
            return
        }

        if disconnectGracePeriod <= 0 {
            let restored = restoreBuiltIn(trigger: trigger)
            if restored { clearGraceCountdown() }
            return
        }

        let currentTime = now()
        var shouldRestoreNow = false
        var startedCountdown = false
        var effectiveTrigger = trigger
        var scheduleDelay: TimeInterval?
        var lifecycle = 0

        lock.lock()
        lifecycle = lifecycleGeneration
        if let since = headlessSince {
            let elapsed = currentTime.timeIntervalSince(since)
            if elapsed >= disconnectGracePeriod {
                shouldRestoreNow = true
                effectiveTrigger = isHeartbeat ? pendingTrigger : trigger
                graceWorkItem?.cancel()
                graceWorkItem = nil
            } else if graceWorkItem == nil {
                scheduleDelay = max(0.01, disconnectGracePeriod - elapsed)
            }
        } else {
            headlessSince = currentTime
            pendingTrigger = trigger
            scheduleDelay = disconnectGracePeriod
            startedCountdown = true
        }
        lock.unlock()

        if startedCountdown {
            let summary = displays.map { "\($0.id)(bi:\($0.isBuiltIn ? 1 : 0),v:\($0.isVirtual ? 1 : 0),on:\($0.isOnline ? 1 : 0),en:\($0.isEnabled ? 1 : 0))" }.joined(separator: ",")
            failsafeLogger.notice("No active physical external display [\(summary, privacy: .public)] — starting \(self.disconnectGracePeriod, privacy: .public)s failsafe countdown (trigger=\(trigger.rawValue, privacy: .public))")
        }

        if shouldRestoreNow {
            failsafeLogger.notice("Failsafe grace period (\(self.disconnectGracePeriod, privacy: .public)s) elapsed — restoring Built-in Display (trigger=\(effectiveTrigger.rawValue, privacy: .public))")
            if restoreBuiltIn(trigger: effectiveTrigger) {
                clearGraceCountdown()
            }
            // If restore transiently failed, keep `headlessSince` expired so the next heartbeat retries immediately.
            return
        }

        if let delay = scheduleDelay {
            scheduleGraceEvaluation(after: delay, lifecycle: lifecycle)
        }
    }

    private func scheduleGraceEvaluation(after delay: TimeInterval, lifecycle: Int) {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let valid = self.lifecycleGeneration == lifecycle
            self.graceWorkItem = nil
            let trigger = self.pendingTrigger
            self.lock.unlock()
            guard valid else { return }
            self.evaluateWithGracePeriod(trigger: trigger, isHeartbeat: true)
        }

        lock.lock()
        guard lifecycleGeneration == lifecycle else {
            lock.unlock()
            return
        }
        let previous = graceWorkItem
        graceWorkItem = item
        lock.unlock()

        previous?.cancel()
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func clearGraceCountdown() {
        lock.lock()
        headlessSince = nil
        let workItem = graceWorkItem
        graceWorkItem = nil
        lock.unlock()
        workItem?.cancel()
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
        clearGraceCountdown()
        guard !backend.isBuiltInDisplayEnabled() else { return true }
        return restoreBuiltIn(trigger: .quit)
    }

    /// Emergency restore (hotkey): enables all online displays, un-mirrors, and guarantees the Built-in
    /// Display is on. Synchronous and immediate. Returns `true` if the Built-in Display ends up enabled.
    @discardableResult
    public func emergencyRestoreAll() -> Bool {
        clearGraceCountdown()
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
            failsafeLogger.error("setBuiltInDisplayEnabled(true) threw: \(error.localizedDescription, privacy: .public); attempting emergencyRestoreAllDisplays()")
            // Fallback: full emergency restore.
            try? backend.emergencyRestoreAllDisplays()
        }
        let restored = backend.isBuiltInDisplayEnabled()
        failsafeLogger.notice("Built-in restore result=\(restored, privacy: .public) (trigger=\(trigger.rawValue, privacy: .public))")
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
