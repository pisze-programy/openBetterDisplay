import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation

// MARK: - AppController

/// Central coordinator wiring every Stage 2 module together for the UI layer.
///
/// Threading model:
/// - All published state and UI-facing actions live on the main actor.
/// - Display reconfiguration (SkyLight/CoreGraphics transactions, HDR switching) runs on `displayQueue`.
/// - DDC/CI I²C traffic runs on `ddcQueue` (latest value wins, so slider drags never pile up).
/// - `FailsafeWatchdog` runs its own queue + CoreGraphics callback, independent of the main thread.
@MainActor
public final class AppController: ObservableObject {
    // MARK: Published state

    @Published public private(set) var displays: [DisplayInfo] = []
    @Published public var selectedDisplayID: CGDirectDisplayID?
    @Published public private(set) var brightnessByDisplay: [CGDirectDisplayID: Double] = [:]
    @Published public private(set) var brightnessMethodByDisplay: [CGDirectDisplayID: BrightnessMethod] = [:]
    @Published public private(set) var volumeByDisplay: [CGDirectDisplayID: Int] = [:]
    @Published public private(set) var mutedByDisplay: [CGDirectDisplayID: Bool] = [:]
    @Published public private(set) var inputSourceByDisplay: [CGDirectDisplayID: DDCInputSource?] = [:]
    @Published public private(set) var nightShiftStatus = NightShiftStatus(isActive: false, effectiveWarmth: 0, usedNative: false, overlayDisplayIDs: [])
    @Published public private(set) var nightShiftScheduleDescription: String = ""
    @Published public private(set) var hasAccessibilityPermission: Bool = false
    @Published public private(set) var isBusySwitching: Bool = false
    @Published public private(set) var lastDDCReports: [CGDirectDisplayID: DDCCapabilityReport] = [:]
    @Published public private(set) var profiles: [MonitorProfile] = []
    @Published public private(set) var isBuiltInEnabled: Bool = true
    @Published public private(set) var defaultAudioOutputName: String?
    @Published public private(set) var audioMonitorDisplayID: CGDirectDisplayID?
    @Published public private(set) var launchAtLoginEnabled: Bool = false
    @Published public private(set) var lastErrorMessage: String?

    public let settingsStore: SettingsStore
    public let profileStore: ProfileStore

    // MARK: Modules

    public let displayManager: DisplayManager
    public let ddcController: DDCController
    public let audioObserver: CoreAudioObserver
    public let nightShiftBackend: CoreBrightnessBridge
    public let overlayManager: OverlayManager
    public let osd: OSDHUDController
    public let brightnessController: CombinedBrightnessController
    public let nightShiftScheduler: NightShiftScheduler
    public let mediaKeyInterceptor: MediaKeyInterceptor
    public let shortcutManager: GlobalShortcutManager
    public let launchAtLoginManager: LaunchAtLoginManager
    public let failsafeWatchdog: FailsafeWatchdog

    // MARK: Private

    private let displayQueue = DispatchQueue(label: "com.piszeprogramy.openbetterdisplay.display-config", qos: .userInitiated)
    private let ddcQueue = DispatchQueue(label: "com.piszeprogramy.openbetterdisplay.ddc-actions", qos: .userInitiated)
    private let writeGate = LatestWriteGate()
    private var started = false
    private var refreshGeneration = 0
    private var pendingPersist: [CGDirectDisplayID: Task<Void, Never>] = [:]
    private var accessibilityTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var probedDisplayIDs: Set<CGDirectDisplayID> = []
    /// Storage keys of monitors whose profile was just restored; UI state is re-synced on the next refresh.
    private var pendingProfileSyncKeys: Set<String> = []
    /// Last (id, enabled, HDR) signature, used to re-apply Night Shift when the display topology changes.
    private var lastTopologySignature: [String] = []

    // MARK: Init

    public init(
        settingsStore: SettingsStore? = nil,
        profileStore: ProfileStore? = nil,
        displayManager: DisplayManager = DisplayManager(),
        ddcController: DDCController = DDCController(),
        audioObserver: CoreAudioObserver = CoreAudioObserver(),
        nightShiftBackend: CoreBrightnessBridge = CoreBrightnessBridge()
    ) {
        let settingsStore = settingsStore ?? SettingsStore()
        let profileStore = profileStore ?? ProfileStore()
        let overlay = OverlayManager()

        self.settingsStore = settingsStore
        self.profileStore = profileStore
        self.displayManager = displayManager
        self.ddcController = ddcController
        self.audioObserver = audioObserver
        self.nightShiftBackend = nightShiftBackend
        self.overlayManager = overlay
        self.osd = OSDHUDController()
        self.brightnessController = CombinedBrightnessController(
            displayBackend: displayManager,
            ddcBackend: ddcController,
            overlay: overlay,
            asyncDDCWrites: true
        )
        self.launchAtLoginManager = LaunchAtLoginManager()
        self.shortcutManager = GlobalShortcutManager()

        // Closures below need `self`; they are wired through weak boxes after init.
        let selfBox = WeakBox<AppController>()
        self.nightShiftScheduler = NightShiftScheduler(
            backend: nightShiftBackend,
            overlay: overlay,
            config: settingsStore.settings.nightShift,
            displayProvider: { MainActor.assumeIsolated { selfBox.value?.displays ?? [] } }
        )
        self.mediaKeyInterceptor = MediaKeyInterceptor(
            audioBackend: audioObserver,
            activeDisplayIDsProvider: { DisplayManager.activeDisplayIDs() },
            targetProvider: { MainActor.assumeIsolated { selfBox.value?.settingsStore.settings.brightnessTarget ?? .cursorDisplay } }
        )
        self.failsafeWatchdog = FailsafeWatchdog(
            backend: displayManager,
            observeDisplayReconfiguration: true,
            onRestore: { trigger in
                // Quit: app is terminating. Emergency: `emergencyRestoreAllDisplays()` handles its own UI.
                guard trigger != .quit, trigger != .emergency else { return }
                Task { @MainActor in selfBox.value?.handleFailsafeRestore(trigger) }
            }
        )
        selfBox.value = self

        profiles = profileStore.allProfiles()
        nightShiftScheduleDescription = nightShiftScheduler.scheduleDescription
        launchAtLoginEnabled = launchAtLoginManager.isEnabled
        hasAccessibilityPermission = MediaKeyInterceptor.isAccessibilityTrusted
    }

    // MARK: - Lifecycle

    public func start() {
        guard !started else { return }
        started = true

        // Failsafe first: it must be armed before anything else can change the configuration.
        failsafeWatchdog.start()

        wireProfileStore()
        wireInput()
        wireNightShift()
        applySettings(settingsStore.settings)
        settingsStore.onChange = { [weak self] settings in self?.applySettings(settings) }

        displayManager.startReconfigurationObserver { [weak self] in
            Task { @MainActor in self?.handleDisplayReconfiguration() }
        }
        audioObserver.startObservingAudioOutputChanges { [weak self] in
            Task { @MainActor in self?.refreshAudioOutput() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDisplays()
                self?.refreshAccessibilityStatus()
            }
        }

        refreshAccessibilityStatus()
        refreshAudioOutput()
        refreshDisplays(probeDDC: true)
        // Restore known monitor profiles for monitors connected at launch (debounced, link-training safe).
        profileStore.handleDisplayReconfiguration()
    }

    /// Call from `applicationWillTerminate`. Restores the Built-in Display synchronously first.
    public func handleApplicationWillTerminate() {
        // 1. Zero Black-Screen Guarantee: the watchdog stops with the app, so the Built-in must come back now.
        failsafeWatchdog.restoreBuiltInForQuit()
        failsafeWatchdog.stop()

        // 2. Tear down interceptors and overlays.
        mediaKeyInterceptor.stop()
        shortcutManager.unregisterAll()
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
        nightShiftScheduler.restoreNeutral()
        overlayManager.removeAllOverlays()
        osd.hide(animated: false)
        audioObserver.stopObservingAudioOutputChanges()
        displayManager.stopReconfigurationObserver()
        profileStore.cancelPendingHotplug()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        flushPendingPersists()
        started = false
    }

    // MARK: - Wiring

    private func wireProfileStore() {
        profileStore.configureBackends(display: displayManager, ddc: BackgroundWriteDDCBackend(base: ddcController, queue: ddcQueue))
        profileStore.brightnessApplier = { [weak self] displayID, level in
            self?.setBrightness(level, for: displayID, showOSD: false, persist: false)
        }
        profileStore.onProfilesChanged = { [weak self] in
            guard let self else { return }
            self.profiles = self.profileStore.allProfiles()
        }
        profileStore.onHotplugEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .restored(let key, let name):
                self.pendingProfileSyncKeys.insert(key)
                self.showNotice(title: "Profile Restored", subtitle: name)
            case .captured, .skippedAutoRestoreDisabled:
                break
            }
            self.refreshDisplays(probeDDC: true)
        }
    }

    private func wireInput() {
        mediaKeyInterceptor.onBrightnessKey = { [weak self] delta, displayIDs in
            MainActor.assumeIsolated { self?.handleBrightnessKey(delta: delta, displayIDs: displayIDs) ?? false }
        }
        mediaKeyInterceptor.onVolumeKey = { [weak self] key, displayID, step in
            MainActor.assumeIsolated { self?.handleVolumeKey(key, displayID: displayID, step: step) ?? false }
        }
        shortcutManager.onAction = { [weak self] action in
            self?.perform(shortcut: action)
        }
        // DDC failures (e.g. HDR lockout) switch the controller to the overlay asynchronously; reflect it in the UI.
        brightnessController.onMethodChange = { [weak self] displayID, method in
            self?.brightnessMethodByDisplay[displayID] = method
        }
    }

    private func wireNightShift() {
        nightShiftScheduler.onStatusChange = { [weak self] status in
            self?.nightShiftStatus = status
        }
    }

    private func applySettings(_ settings: AppSettings) {
        osd.apply(settings: settings)
        shortcutManager.update(from: settings)
        nightShiftScheduler.update(config: settings.nightShift)
        nightShiftScheduleDescription = nightShiftScheduler.scheduleDescription
        if started, !nightShiftScheduler.isRunning {
            nightShiftScheduler.start()
        }
        nightShiftStatus = nightShiftScheduler.status
    }

    // MARK: - Display refresh

    /// Re-reads the display list off the main thread. With `probeDDC`, newly seen DDC displays are probed.
    public func refreshDisplays(probeDDC: Bool = false) {
        refreshGeneration += 1
        let generation = refreshGeneration
        let manager = displayManager
        displayQueue.async { [weak self] in
            let list = manager.getOnlineDisplays()
            let builtInEnabled = manager.isBuiltInDisplayEnabled()
            let builtInBrightness = manager.getBuiltInBrightness()
            Task { @MainActor in
                guard let self, generation == self.refreshGeneration else { return }
                self.applyDisplayList(list, builtInEnabled: builtInEnabled, builtInBrightness: builtInBrightness, probeDDC: probeDDC)
            }
        }
    }

    private func applyDisplayList(_ list: [DisplayInfo], builtInEnabled: Bool, builtInBrightness: Double?, probeDDC: Bool) {
        let previousIDs = Set(displays.map(\.id))
        let currentIDs = Set(list.filter { $0.isEnabled }.map(\.id))
        displays = list
        isBuiltInEnabled = builtInEnabled

        // Forget state of displays that disappeared / were disabled.
        for gone in previousIDs.subtracting(currentIDs) {
            brightnessController.forget(displayID: gone)
            overlayManager.removeOverlay(for: gone)
            brightnessMethodByDisplay.removeValue(forKey: gone)
            probedDisplayIDs.remove(gone)
        }

        if let builtIn = list.first(where: { $0.isBuiltIn }) {
            if let builtInBrightness {
                brightnessByDisplay[builtIn.id] = builtInBrightness
                brightnessMethodByDisplay[builtIn.id] = .nativeBuiltIn
            }
        }
        for display in list where !display.isBuiltIn && display.isEnabled {
            if let method = brightnessController.method(for: display.id) {
                brightnessMethodByDisplay[display.id] = method
            } else {
                brightnessMethodByDisplay[display.id] = CombinedBrightnessController.calculateCurve(
                    level: brightnessByDisplay[display.id] ?? 1,
                    isBuiltIn: false,
                    isHDREnabled: display.isHDREnabled,
                    supportsDDC: display.supportsDDC
                ).method
            }
            if brightnessByDisplay[display.id] == nil,
               let profile = profileStore.profile(for: display.identifier) {
                brightnessByDisplay[display.id] = profile.combinedBrightness
                volumeByDisplay[display.id] = volumeByDisplay[display.id] ?? profile.ddcVolume
                mutedByDisplay[display.id] = mutedByDisplay[display.id] ?? profile.isMuted
            }
        }

        if let selected = selectedDisplayID, list.contains(where: { $0.id == selected && $0.isEnabled }) {
            // keep selection
        } else {
            selectedDisplayID = (list.first { !$0.isBuiltIn && $0.isEnabled } ?? list.first { $0.isEnabled })?.id
        }

        // Profiles just restored on hotplug: mirror their values in the UI and re-probe the hardware
        // (the probe is queued on `ddcQueue` behind the restore writes, so it reads the restored values).
        if !pendingProfileSyncKeys.isEmpty {
            for display in list where pendingProfileSyncKeys.contains(display.identifier.storageKey) {
                pendingProfileSyncKeys.remove(display.identifier.storageKey)
                if let profile = profileStore.profile(for: display.identifier) {
                    brightnessByDisplay[display.id] = profile.combinedBrightness
                    volumeByDisplay[display.id] = profile.ddcVolume
                    mutedByDisplay[display.id] = profile.isMuted
                }
                probedDisplayIDs.remove(display.id)
            }
        }

        if probeDDC {
            for display in list where display.supportsDDC && !probedDisplayIDs.contains(display.id) {
                self.probeDDC(for: display.id)
            }
        }

        // Re-apply Night Shift whenever displays appear/disappear or switch HDR (overlay vs native routing).
        let signature = list.map { "\($0.id):\($0.isEnabled ? 1 : 0):\($0.isHDREnabled ? 1 : 0)" }.sorted()
        if signature != lastTopologySignature {
            lastTopologySignature = signature
            if started, nightShiftScheduler.isRunning { nightShiftScheduler.applyNow() }
        }
        refreshAudioOutput()
    }

    private func handleDisplayReconfiguration() {
        // FailsafeWatchdog observes CoreGraphics reconfigurations itself (own callback + queue), so it is
        // intentionally not forwarded here: it must keep working even if the main thread is busy.
        profileStore.handleDisplayReconfiguration()
        let ddc = ddcController
        ddcQueue.async { ddc.resetCache() }
        refreshDisplays()
    }

    private func handleFailsafeRestore(_ trigger: FailsafeTrigger) {
        overlayManager.removeAllOverlays()
        for display in displays { brightnessController.forget(displayID: display.id) }
        brightnessMethodByDisplay.removeAll()
        showNotice(title: "Built-in Display Restored", subtitle: trigger == .wake ? "No external display after wake" : "No active external display")
        refreshDisplays(probeDDC: true)
        nightShiftScheduler.applyNow()
    }

    // MARK: - Lookup helpers

    private func displayInfo(for displayID: CGDirectDisplayID) -> DisplayInfo? {
        if let cached = displays.first(where: { $0.id == displayID }) { return cached }
        // Hotplug paths may ask before the async refresh lands; fall back to a synchronous read.
        let fresh = displayManager.getOnlineDisplays()
        return fresh.first { $0.id == displayID }
    }

    /// Main external display (if any), otherwise the first enabled external display.
    public var primaryExternalDisplay: DisplayInfo? {
        let externals = displays.filter { !$0.isBuiltIn && $0.isOnline && $0.isEnabled }
        return externals.first { $0.isMain } ?? externals.first
    }

    // MARK: - Built-in display

    public func setBuiltInDisplayEnabled(_ enabled: Bool) {
        isBusySwitching = true
        let manager = displayManager
        let target = primaryExternalDisplay
        displayQueue.async { [weak self] in
            let result = Result { try manager.setBuiltInDisplayEnabled(enabled) }
            Task { @MainActor in
                guard let self else { return }
                self.isBusySwitching = false
                switch result {
                case .success:
                    self.lastErrorMessage = nil
                    if let target {
                        var profile = self.profileStore.recordCurrentState(from: target, builtInEnabled: enabled)
                        profile.builtInDisplayEnabled = enabled
                        profile.autoDisableBuiltInOnConnect = !enabled
                        self.profileStore.saveProfile(profile)
                    }
                    self.showNotice(title: enabled ? "Built-in Display On" : "Built-in Display Off", subtitle: nil)
                case .failure(let error):
                    self.report(error)
                }
                self.refreshDisplays()
            }
        }
    }

    // MARK: - Brightness

    public func setBrightness(_ level: Double, for displayID: CGDirectDisplayID, showOSD: Bool = false) {
        setBrightness(level, for: displayID, showOSD: showOSD, persist: true)
    }

    private func setBrightness(_ level: Double, for displayID: CGDirectDisplayID, showOSD: Bool, persist: Bool) {
        guard let display = displayInfo(for: displayID), display.isEnabled else { return }
        let clamped = level.isFinite ? min(max(level, 0), 1) : 0
        let method: BrightnessMethod
        if display.isBuiltIn {
            let manager = displayManager
            method = brightnessController.applyBrightness(
                clamped, for: displayID, supportsDDC: false, isHDREnabled: false,
                builtInSetter: { value in manager.setBuiltInBrightness(value) }
            )
        } else {
            // Query HDR live: profile restores may have just switched it.
            let hdr = display.supportsHDR && displayManager.isHDREnabled(displayID: displayID)
            method = brightnessController.applyBrightness(
                clamped, for: displayID, supportsDDC: display.supportsDDC, isHDREnabled: hdr
            )
        }
        brightnessByDisplay[displayID] = clamped
        brightnessMethodByDisplay[displayID] = method
        if showOSD {
            osd.show(OSDItem(kind: .brightness, value: clamped, title: "Brightness", subtitle: "\(display.name) · \(method.badgeText)", displayID: displayID))
        }
        if persist && !display.isBuiltIn { schedulePersist(displayID: displayID) }
    }

    public func stepBrightness(by delta: Double, for displayIDs: [CGDirectDisplayID]) {
        for id in displayIDs {
            let current = brightnessByDisplay[id] ?? brightnessController.level(for: id) ?? 0.5
            setBrightness(current + delta, for: id, showOSD: true)
        }
    }

    private func handleBrightnessKey(delta: Double, displayIDs: [CGDirectDisplayID]) -> Bool {
        let targets = displayIDs.compactMap { id in displays.first { $0.id == id && $0.isEnabled } }
        // Let macOS handle the Built-in panel natively (system HUD) when it is the only target.
        guard targets.contains(where: { !$0.isBuiltIn }) else { return false }
        stepBrightness(by: delta, for: targets.map(\.id))
        return true
    }

    // MARK: - Volume & mute

    public func setVolume(_ percent: Int, for displayID: CGDirectDisplayID, showOSD: Bool = false) {
        guard let display = displayInfo(for: displayID), !display.isBuiltIn else { return }
        let value = min(max(percent, 0), 100)
        volumeByDisplay[displayID] = value
        let ddc = ddcController
        let gate = writeGate
        let unmute = mutedByDisplay[displayID] == true && value > 0
        if unmute { mutedByDisplay[displayID] = false }
        let token = gate.next("volume-\(displayID)")
        ddcQueue.async {
            guard gate.isLatest("volume-\(displayID)", token) else { return }
            if unmute { _ = ddc.writeMute(displayID: displayID, muted: false) }
            _ = ddc.writeVolume(displayID: displayID, value: UInt16(value))
        }
        if showOSD {
            osd.show(OSDItem(kind: .volume, value: Double(value) / 100, isMuted: mutedByDisplay[displayID] ?? false, title: "Volume", subtitle: display.name, displayID: displayID))
        }
        schedulePersist(displayID: displayID)
    }

    public func toggleMute(for displayID: CGDirectDisplayID, showOSD: Bool = false) {
        guard let display = displayInfo(for: displayID), !display.isBuiltIn else { return }
        let muted = !(mutedByDisplay[displayID] ?? false)
        mutedByDisplay[displayID] = muted
        let ddc = ddcController
        ddcQueue.async { _ = ddc.writeMute(displayID: displayID, muted: muted) }
        if showOSD {
            osd.show(OSDItem(kind: muted ? .mute : .volume, value: Double(volumeByDisplay[displayID] ?? 0) / 100, isMuted: muted, title: muted ? "Muted" : "Volume", subtitle: display.name, displayID: displayID))
        }
        schedulePersist(displayID: displayID)
    }

    private func handleVolumeKey(_ key: MediaKey, displayID: CGDirectDisplayID, step: Double) -> Bool {
        guard displays.contains(where: { $0.id == displayID && !$0.isBuiltIn }) else { return false }
        if key == .mute {
            toggleMute(for: displayID, showOSD: true)
        } else {
            let current = volumeByDisplay[displayID] ?? 50
            setVolume(current + Int((step * 100).rounded()), for: displayID, showOSD: true)
        }
        return true
    }

    // MARK: - Display configuration

    public func setDisplayMode(_ mode: DisplayModeInfo, for displayID: CGDirectDisplayID) {
        runDisplayChange(displayID: displayID) { manager in
            try manager.setDisplayMode(displayID: displayID, mode: mode)
        }
    }

    public func setHDREnabled(_ enabled: Bool, for displayID: CGDirectDisplayID) {
        runDisplayChange(displayID: displayID, notice: enabled ? "HDR On" : "HDR Off") { manager in
            try manager.setHDREnabled(displayID: displayID, enabled: enabled)
        } completion: { [weak self] in
            guard let self else { return }
            // Re-route Combined Brightness (DDC ↔ overlay) for the new HDR state, then re-tint Night Shift.
            self.brightnessController.resetDDCFailure(for: displayID)
            if let level = self.brightnessByDisplay[displayID] {
                self.setBrightness(level, for: displayID, showOSD: false, persist: false)
            }
            self.nightShiftScheduler.applyNow()
        }
    }

    public func setMainDisplay(_ displayID: CGDirectDisplayID) {
        runDisplayChange(displayID: displayID, notice: "Main Display") { manager in
            try manager.setMainDisplay(displayID: displayID)
        }
    }

    public func setMirror(displayID: CGDirectDisplayID, mirrorOf: CGDirectDisplayID?) {
        runDisplayChange(displayID: displayID, notice: mirrorOf == nil ? "Mirroring Off" : "Mirroring On") { manager in
            try manager.setDisplayMirror(displayID: displayID, mirrorOf: mirrorOf)
        }
    }

    public func setRotation(_ degrees: Int, for displayID: CGDirectDisplayID) {
        runDisplayChange(displayID: displayID, notice: "Rotation \(degrees)°") { manager in
            try manager.setDisplayRotation(displayID: displayID, rotation: degrees)
        }
    }

    /// Runs a display mutation on `displayQueue`, then refreshes, persists the monitor profile, and reports errors.
    private func runDisplayChange(
        displayID: CGDirectDisplayID,
        notice: String? = nil,
        _ work: @escaping @Sendable (DisplayManager) throws -> Void,
        completion: (@MainActor () -> Void)? = nil
    ) {
        isBusySwitching = true
        let manager = displayManager
        displayQueue.async { [weak self] in
            let result = Result { try work(manager) }
            let list = manager.getOnlineDisplays()
            let builtInEnabled = manager.isBuiltInDisplayEnabled()
            let builtInBrightness = manager.getBuiltInBrightness()
            Task { @MainActor in
                guard let self else { return }
                self.isBusySwitching = false
                self.refreshGeneration += 1
                self.applyDisplayList(list, builtInEnabled: builtInEnabled, builtInBrightness: builtInBrightness, probeDDC: false)
                switch result {
                case .success:
                    self.lastErrorMessage = nil
                    if let display = list.first(where: { $0.id == displayID }), !display.isBuiltIn {
                        self.persistNow(display: display)
                    }
                    if let notice { self.showNotice(title: notice, subtitle: list.first { $0.id == displayID }?.name) }
                case .failure(let error):
                    self.report(error)
                }
                completion?()
            }
        }
    }

    // MARK: - Input source

    public func setInputSource(_ source: DDCInputSource, for displayID: CGDirectDisplayID) {
        guard let display = displayInfo(for: displayID), !display.isBuiltIn else { return }
        let ddc = ddcController
        ddcQueue.async { [weak self] in
            let ok = ddc.writeInputSource(displayID: displayID, source: source)
            Task { @MainActor in
                guard let self else { return }
                if ok {
                    self.inputSourceByDisplay[displayID] = source
                    var profile = self.profileStore.profile(for: display.identifier) ?? ProfileStore.makeNewProfile(from: display)
                    profile.preferredInputSource = source
                    self.profileStore.saveProfile(profile)
                    self.showNotice(title: source.displayName, subtitle: display.name)
                } else {
                    self.report(DisplayError.ddcCommunicationFailed("Input source switch to \(source.displayName) failed."))
                }
            }
        }
    }

    // MARK: - DDC probing

    public func probeDDC(for displayID: CGDirectDisplayID) {
        probedDisplayIDs.insert(displayID)
        let ddc = ddcController
        let hdr = displays.first { $0.id == displayID }?.isHDREnabled ?? false
        ddcQueue.async { [weak self] in
            let report = ddc.probeCapabilities(displayID: displayID)
            let muted = report.supportsVolume ? ddc.readMute(displayID: displayID) : nil
            Task { @MainActor in
                guard let self else { return }
                self.lastDDCReports[displayID] = report
                if let volume = report.currentVolume { self.volumeByDisplay[displayID] = Int(volume) }
                if let muted { self.mutedByDisplay[displayID] = muted }
                if report.supportsInputSource { self.inputSourceByDisplay[displayID] = report.currentInputSource }
                // Derive the combined level from hardware luminance (SDR only; HDR uses the overlay).
                if !hdr, let luminance = report.currentLuminance, self.brightnessByDisplay[displayID] == nil {
                    let knee = self.brightnessController.kneePoint
                    self.brightnessByDisplay[displayID] = knee + Double(luminance) / 100 * (1 - knee)
                }
            }
        }
    }

    // MARK: - Night Shift & settings

    public func toggleNightShift() {
        let willEnable = !settingsStore.settings.nightShift.enabled
        updateSettings { $0.nightShift.enabled = willEnable }
        showNotice(title: willEnable ? "Night Shift On" : "Night Shift Off", subtitle: nightShiftScheduleDescription)
    }

    public func updateSettings(_ transform: (inout AppSettings) -> Void) {
        settingsStore.update(transform)
    }

    public func setLaunchAtLogin(_ enabled: Bool) throws {
        try launchAtLoginManager.setEnabled(enabled)
        launchAtLoginEnabled = launchAtLoginManager.isEnabled
        updateSettings { $0.launchAtLogin = enabled }
    }

    // MARK: - Emergency restore

    public func emergencyRestoreAllDisplays() {
        // Neutralize everything visual immediately on the main thread.
        nightShiftScheduler.restoreNeutral()
        // Keep settings and scheduler in sync: Night Shift stays OFF until the user re-enables it.
        if settingsStore.settings.nightShift.enabled {
            updateSettings { $0.nightShift.enabled = false }
        }
        overlayManager.removeAllOverlays()
        for display in displays { brightnessController.forget(displayID: display.id) }
        brightnessMethodByDisplay.removeAll()

        isBusySwitching = true
        let watchdog = failsafeWatchdog
        displayQueue.async { [weak self] in
            let ok = watchdog.emergencyRestoreAll()
            Task { @MainActor in
                guard let self else { return }
                self.isBusySwitching = false
                self.showNotice(title: ok ? "Displays Restored" : "Restore Incomplete", subtitle: ok ? "All displays enabled" : "Check display connections")
                self.refreshDisplays(probeDDC: true)
            }
        }
    }

    // MARK: - Shortcuts

    private func perform(shortcut action: ShortcutAction) {
        switch action {
        case .toggleBuiltIn:
            setBuiltInDisplayEnabled(!isBuiltInEnabled)
        case .toggleHDR:
            let candidates = displays.filter { !$0.isBuiltIn && $0.isEnabled && $0.supportsHDR }
            guard let target = candidates.first(where: { $0.isMain }) ?? candidates.first else {
                showNotice(title: "HDR Unavailable", subtitle: "No HDR-capable display")
                return
            }
            setHDREnabled(!target.isHDREnabled, for: target.id)
        case .toggleNightShift:
            toggleNightShift()
        case .emergencyRestore:
            emergencyRestoreAllDisplays()
        }
    }

    // MARK: - Accessibility

    public func requestAccessibilityPermission() {
        _ = mediaKeyInterceptor.requestAccessibilityPermission()
        refreshAccessibilityStatus()
    }

    public func openAccessibilitySettings() {
        MediaKeyInterceptor.openAccessibilitySettings()
        refreshAccessibilityStatus()
    }

    public func refreshAccessibilityStatus() {
        let trusted = MediaKeyInterceptor.isAccessibilityTrusted
        hasAccessibilityPermission = trusted
        if trusted {
            accessibilityTimer?.invalidate()
            accessibilityTimer = nil
            if started, !mediaKeyInterceptor.isRunning { mediaKeyInterceptor.start() }
        } else if started, accessibilityTimer == nil {
            // Poll until the user grants permission in System Settings.
            let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshAccessibilityStatus() }
            }
            RunLoop.main.add(timer, forMode: .common)
            accessibilityTimer = timer
        }
    }

    // MARK: - Audio

    private func refreshAudioOutput() {
        defaultAudioOutputName = audioObserver.defaultOutputDeviceName()
        audioMonitorDisplayID = mediaKeyInterceptor.activeAudioMonitor()
    }

    // MARK: - Profiles

    public func deleteProfile(forKey key: String) {
        profileStore.deleteProfile(forKey: key)
        profiles = profileStore.allProfiles()
    }

    public func resetProfiles() {
        profileStore.deleteAllProfiles()
        profiles = profileStore.allProfiles()
    }

    // MARK: - Persistence

    /// Debounced profile persistence for continuous adjustments (sliders, key repeat).
    private func schedulePersist(displayID: CGDirectDisplayID) {
        pendingPersist[displayID]?.cancel()
        pendingPersist[displayID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self else { return }
            self.pendingPersist[displayID] = nil
            if let display = self.displays.first(where: { $0.id == displayID }) {
                self.persistNow(display: display)
            }
        }
    }

    private func flushPendingPersists() {
        let ids = Array(pendingPersist.keys)
        pendingPersist.values.forEach { $0.cancel() }
        pendingPersist.removeAll()
        for id in ids {
            if let display = displays.first(where: { $0.id == id }) { persistNow(display: display) }
        }
    }

    private func persistNow(display: DisplayInfo) {
        guard !display.isBuiltIn else { return }
        profileStore.recordCurrentState(
            from: display,
            brightness: brightnessByDisplay[display.id],
            volume: volumeByDisplay[display.id],
            isMuted: mutedByDisplay[display.id],
            builtInEnabled: nil
        )
    }

    // MARK: - Feedback

    private func showNotice(title: String, subtitle: String?) {
        osd.show(OSDItem(kind: .notice, title: title, subtitle: subtitle, displayID: primaryExternalDisplay?.id ?? CGMainDisplayID()))
    }

    private func report(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        lastErrorMessage = message
        if let displayError = error as? DisplayError, displayError == .singleDisplayGuardViolation {
            showNotice(title: "Built-in Display Kept On", subtitle: "Connect an external display first")
        } else {
            showNotice(title: "Action Failed", subtitle: message)
        }
    }
}

// MARK: - Helpers

/// Weak reference box used to hand `self` to closures created during `init`.
private final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
}

/// Thread-safe "latest value wins" token gate for coalescing background writes.
private final class LatestWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generations: [String: Int] = [:]

    func next(_ key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let value = (generations[key] ?? 0) + 1
        generations[key] = value
        return value
    }

    func isLatest(_ key: String, _ token: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generations[key] == token
    }
}

/// DDC backend handed to `ProfileStore` (which runs on the main actor): reads stay synchronous, but writes
/// (volume / mute / brightness / input restore on hotplug) are queued on the DDC queue so the main thread
/// never blocks on I²C transfers. Writes report `true` optimistically.
private struct BackgroundWriteDDCBackend: DDCBackendProtocol {
    let base: DDCBackendProtocol
    let queue: DispatchQueue

    func probeCapabilities(displayID: CGDirectDisplayID) -> DDCCapabilityReport { base.probeCapabilities(displayID: displayID) }
    func readBrightness(displayID: CGDirectDisplayID) -> UInt16? { base.readBrightness(displayID: displayID) }
    func readVolume(displayID: CGDirectDisplayID) -> UInt16? { base.readVolume(displayID: displayID) }
    func readMute(displayID: CGDirectDisplayID) -> Bool? { base.readMute(displayID: displayID) }
    func readInputSource(displayID: CGDirectDisplayID) -> DDCInputSource? { base.readInputSource(displayID: displayID) }

    func writeBrightness(displayID: CGDirectDisplayID, value: UInt16) -> Bool {
        let base = base
        queue.async { _ = base.writeBrightness(displayID: displayID, value: value) }
        return true
    }

    func writeVolume(displayID: CGDirectDisplayID, value: UInt16) -> Bool {
        let base = base
        queue.async { _ = base.writeVolume(displayID: displayID, value: value) }
        return true
    }

    func writeMute(displayID: CGDirectDisplayID, muted: Bool) -> Bool {
        let base = base
        queue.async { _ = base.writeMute(displayID: displayID, muted: muted) }
        return true
    }

    func writeInputSource(displayID: CGDirectDisplayID, source: DDCInputSource) -> Bool {
        let base = base
        queue.async { _ = base.writeInputSource(displayID: displayID, source: source) }
        return true
    }
}
