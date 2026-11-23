import CoreGraphics
import Foundation

/// Events emitted by `ProfileStore` during hotplug processing.
public enum ProfileHotplugEvent: Equatable, Sendable {
    case restored(storageKey: String, displayName: String)
    case captured(storageKey: String, displayName: String)
    case skippedAutoRestoreDisabled(storageKey: String)
}

/// Persists per-monitor profiles and applies hotplug automation
/// (debounced restore for known monitors, capture for unseen monitors).
@MainActor
public final class ProfileStore {
    public nonisolated static let defaultDebounceInterval: TimeInterval = 1.5

    public static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("openBetterDisplay", isDirectory: true)
            .appendingPathComponent("profiles.json", isDirectory: false)
    }

    public let fileURL: URL
    public let debounceInterval: TimeInterval

    /// Applies combined brightness (0...1) to a display (wired to `CombinedBrightnessController`).
    public var brightnessApplier: ((CGDirectDisplayID, Double) -> Void)?
    /// Called for each hotplug outcome (e.g. to show an OSD notice).
    public var onHotplugEvent: ((ProfileHotplugEvent) -> Void)?
    /// Called after the profile dictionary changes on disk.
    public var onProfilesChanged: (() -> Void)?

    private var profiles: [String: MonitorProfile] = [:]
    private var displayBackend: DisplayBackendProtocol?
    private var ddcBackend: DDCBackendProtocol?
    private var hotplugTask: Task<Void, Never>?
    private var hotplugGeneration = 0
    private var isProcessing = false
    private var needsRerun = false
    private nonisolated let hardwareQueue = DispatchQueue(label: "com.piszeprogramy.openbetterdisplay.profile-hotplug", qos: .userInitiated)
    /// Storage keys of external monitors that were present at the last hotplug evaluation.
    private var connectedKeys: Set<String> = []

    public init(
        fileURL: URL? = nil,
        debounceInterval: TimeInterval = ProfileStore.defaultDebounceInterval,
        displayBackend: DisplayBackendProtocol? = nil,
        ddcBackend: DDCBackendProtocol? = nil,
        brightnessApplier: ((CGDirectDisplayID, Double) -> Void)? = nil
    ) {
        self.fileURL = fileURL ?? ProfileStore.defaultFileURL
        self.debounceInterval = debounceInterval
        self.displayBackend = displayBackend
        self.ddcBackend = ddcBackend
        self.brightnessApplier = brightnessApplier
        self.profiles = ProfileStore.loadFromDisk(url: self.fileURL)
    }

    deinit {
        hotplugTask?.cancel()
    }

    /// Late-binds backends (useful when the store is created before the display backend).
    public func configureBackends(display: DisplayBackendProtocol?, ddc: DDCBackendProtocol?) {
        self.displayBackend = display
        self.ddcBackend = ddc
    }

    // MARK: - CRUD

    public func profile(for identifier: DisplayIdentifier) -> MonitorProfile? {
        profiles[identifier.storageKey]
    }

    public func profile(forKey key: String) -> MonitorProfile? {
        profiles[key]
    }

    public func allProfiles() -> [MonitorProfile] {
        profiles.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public func saveProfile(_ profile: MonitorProfile) {
        var copy = profile
        copy.updatedAt = Date()
        profiles[copy.identifier.storageKey] = copy
        persist()
    }

    public func deleteProfile(forKey key: String) {
        guard profiles.removeValue(forKey: key) != nil else { return }
        connectedKeys.remove(key)
        persist()
    }

    public func deleteAllProfiles() {
        profiles.removeAll()
        connectedKeys.removeAll()
        persist()
    }

    /// Updates (or creates) the profile for `display` from live state. Preserves user flags
    /// (`autoRestoreOnConnect`, `autoDisableBuiltInOnConnect`, `preferredInputSource`).
    /// Nil arguments keep the previous stored value (or the model default for new profiles).
    @discardableResult
    public func recordCurrentState(
        from display: DisplayInfo,
        brightness: Double? = nil,
        volume: Int? = nil,
        isMuted: Bool? = nil,
        builtInEnabled: Bool? = nil
    ) -> MonitorProfile {
        let key = display.identifier.storageKey
        var profile = profiles[key] ?? ProfileStore.makeNewProfile(from: display)

        if let mode = display.currentMode {
            profile.targetWidth = mode.width
            profile.targetHeight = mode.height
            profile.targetPixelWidth = mode.pixelWidth
            profile.targetPixelHeight = mode.pixelHeight
            profile.targetRefreshRate = mode.refreshRate
            profile.targetIsHiDPI = mode.isHiDPI
        }
        profile.displayName = display.name
        profile.hdrEnabled = display.isHDREnabled
        profile.isMainDisplay = display.isMain
        profile.rotation = display.rotation
        if let brightness = brightness { profile.combinedBrightness = min(max(brightness, 0), 1) }
        if let volume = volume { profile.ddcVolume = min(max(volume, 0), 100) }
        if let isMuted = isMuted { profile.isMuted = isMuted }
        if let builtInEnabled = builtInEnabled { profile.builtInDisplayEnabled = builtInEnabled }

        saveProfile(profile)
        return profiles[key] ?? profile
    }

    // MARK: - Hotplug

    /// Call on every `CGDisplayRegisterReconfigurationCallback` event. Non-blocking: coalesces events
    /// for `debounceInterval`, then processes on a background hardware queue.
    public func handleDisplayReconfiguration() {
        hotplugTask?.cancel()
        hotplugGeneration += 1
        let generation = hotplugGeneration
        let nanos = UInt64(max(debounceInterval, 0) * 1_000_000_000)
        hotplugTask = Task { [weak self] in
            if nanos > 0 {
                try? await Task.sleep(nanoseconds: nanos)
            }
            guard !Task.isCancelled, let self = self else { return }
            await self.processConnectedDisplaysNow()
            if self.hotplugGeneration == generation { self.hotplugTask = nil }
        }
    }

    public func cancelPendingHotplug() {
        hotplugTask?.cancel()
        hotplugTask = nil
    }

    /// True while a debounce is pending or a hotplug pass is running.
    public var isHotplugBusy: Bool { hotplugTask != nil || isProcessing }

    /// Waits until the debounce has fired and processing has finished (for deterministic tests).
    public func waitUntilIdle() async {
        while isHotplugBusy {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Starts an immediate (non-debounced) pass; the returned task completes when it has finished.
    @discardableResult
    public func processConnectedDisplays() -> Task<Void, Never> {
        Task { [weak self] in await self?.processConnectedDisplaysNow() }
    }

    /// Evaluates connected external displays right now (no debounce). Only monitors that appeared
    /// since the last evaluation are restored/captured, so our own mode changes don't cause loops.
    /// Display enumeration, display mutations and DDC reads run on a background queue; the main actor is
    /// only used for profile state, `brightnessApplier` and event callbacks.
    /// If a pass is already running this schedules a re-run and returns immediately.
    public func processConnectedDisplaysNow() async {
        guard displayBackend != nil else { return }
        if isProcessing {
            needsRerun = true
            return
        }
        isProcessing = true
        repeat {
            needsRerun = false
            await runPass()
        } while needsRerun
        isProcessing = false
    }

    private func runPass() async {
        guard let backend = displayBackend else { return }
        let ddc = ddcBackend

        let displays = await onHardwareQueue { backend.getOnlineDisplays() }
        let externals = displays.filter { !$0.isBuiltIn && $0.isOnline && $0.isEnabled && !$0.isMirrored }
        let currentKeys = Set(externals.map { $0.identifier.storageKey })
        let newlyConnected = externals.filter { !connectedKeys.contains($0.identifier.storageKey) }
        connectedKeys = currentKeys

        for display in newlyConnected {
            let key = display.identifier.storageKey
            if let profile = profiles[key] {
                if profile.autoRestoreOnConnect {
                    // Deterministic order: mode → HDR → brightness → volume/mute → main → rotation → built-in.
                    await onHardwareQueue { ProfileStore.restoreModeAndHDR(profile: profile, display: display, backend: backend) }
                    brightnessApplier?(display.id, profile.combinedBrightness)
                    await onHardwareQueue {
                        ProfileStore.restoreAudioAndLayout(profile: profile, display: display, backend: backend, ddc: ddc)
                    }
                    onHotplugEvent?(.restored(storageKey: key, displayName: display.name))
                } else {
                    onHotplugEvent?(.skippedAutoRestoreDisabled(storageKey: key))
                }
            } else {
                let snapshot = await onHardwareQueue { ProfileStore.readInitialDDCState(display: display, ddc: ddc) }
                captureNewMonitor(display, ddc: snapshot)
                onHotplugEvent?(.captured(storageKey: key, displayName: display.name))
            }
        }
    }

    /// Synchronous full restore (blocks; call off the main thread or from tests with mocks).
    public func restore(profile: MonitorProfile, to display: DisplayInfo, backend: DisplayBackendProtocol) {
        ProfileStore.restoreModeAndHDR(profile: profile, display: display, backend: backend)
        brightnessApplier?(display.id, profile.combinedBrightness)
        ProfileStore.restoreAudioAndLayout(profile: profile, display: display, backend: backend, ddc: ddcBackend)
    }

    private nonisolated static func restoreModeAndHDR(profile: MonitorProfile, display: DisplayInfo, backend: DisplayBackendProtocol) {
        let id = display.id
        if let mode = closestMode(for: profile, in: display.availableModes),
           !isSameMode(mode, display.currentMode) {
            try? backend.setDisplayMode(displayID: id, mode: mode)
        }
        // `supportsHDR` may be unknown off the main thread; if the profile wants HDR, just try.
        if display.supportsHDR || profile.hdrEnabled, backend.isHDREnabled(displayID: id) != profile.hdrEnabled {
            try? backend.setHDREnabled(displayID: id, enabled: profile.hdrEnabled)
        }
    }

    private nonisolated static func restoreAudioAndLayout(
        profile: MonitorProfile,
        display: DisplayInfo,
        backend: DisplayBackendProtocol,
        ddc: DDCBackendProtocol?
    ) {
        let id = display.id
        if let ddc = ddc, display.supportsDDC {
            _ = ddc.writeVolume(displayID: id, value: UInt16(min(max(profile.ddcVolume, 0), 100)))
            _ = ddc.writeMute(displayID: id, muted: profile.isMuted)
        }
        if profile.isMainDisplay && !display.isMain {
            try? backend.setMainDisplay(displayID: id)
        }
        if display.supportsRotation, display.rotation != profile.rotation {
            try? backend.setDisplayRotation(displayID: id, rotation: profile.rotation)
        }
        // Built-in: only ever auto-disable when the user explicitly opted in for this monitor.
        // The backend enforces the single-display guard.
        if profile.autoDisableBuiltInOnConnect && !profile.builtInDisplayEnabled {
            try? backend.setBuiltInDisplayEnabled(false)
        } else if profile.builtInDisplayEnabled && !backend.isBuiltInDisplayEnabled() {
            try? backend.setBuiltInDisplayEnabled(true)
        }
    }

    private struct InitialDDCState: Sendable {
        var brightness: UInt16?
        var volume: UInt16?
        var muted: Bool?
    }

    private nonisolated static func readInitialDDCState(display: DisplayInfo, ddc: DDCBackendProtocol?) -> InitialDDCState {
        guard let ddc = ddc, display.supportsDDC else { return InitialDDCState() }
        return InitialDDCState(
            brightness: display.isHDREnabled ? nil : ddc.readBrightness(displayID: display.id),
            volume: ddc.readVolume(displayID: display.id),
            muted: ddc.readMute(displayID: display.id)
        )
    }

    private func captureNewMonitor(_ display: DisplayInfo, ddc: InitialDDCState) {
        var profile = ProfileStore.makeNewProfile(from: display)
        if let raw = ddc.brightness { profile.combinedBrightness = min(max(Double(raw) / 100.0, 0), 1) }
        if let vol = ddc.volume { profile.ddcVolume = min(max(Int(vol), 0), 100) }
        if let mute = ddc.muted { profile.isMuted = mute }
        // Never auto-disable Built-in for an unseen monitor.
        profile.builtInDisplayEnabled = true
        profile.autoDisableBuiltInOnConnect = false
        saveProfile(profile)
    }

    private nonisolated func onHardwareQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            hardwareQueue.async { continuation.resume(returning: work()) }
        }
    }

    // MARK: - Pure helpers

    public nonisolated static func makeNewProfile(from display: DisplayInfo) -> MonitorProfile {
        let mode = display.currentMode
        return MonitorProfile(
            identifier: display.identifier,
            displayName: display.name,
            targetWidth: mode?.width ?? 0,
            targetHeight: mode?.height ?? 0,
            targetPixelWidth: mode?.pixelWidth ?? 0,
            targetPixelHeight: mode?.pixelHeight ?? 0,
            targetRefreshRate: mode?.refreshRate ?? 60,
            targetIsHiDPI: mode?.isHiDPI ?? false,
            hdrEnabled: display.isHDREnabled,
            isMainDisplay: display.isMain,
            builtInDisplayEnabled: true,
            rotation: display.rotation,
            autoRestoreOnConnect: true,
            autoDisableBuiltInOnConnect: false
        )
    }

    /// Picks the available mode closest to the profile's target (size, pixel size, refresh, HiDPI).
    public nonisolated static func closestMode(for profile: MonitorProfile, in modes: [DisplayModeInfo]) -> DisplayModeInfo? {
        guard profile.targetWidth > 0, profile.targetHeight > 0 else { return nil }
        func score(_ m: DisplayModeInfo) -> Double {
            var s = 0.0
            s += Double(abs(m.width - profile.targetWidth)) * 10
            s += Double(abs(m.height - profile.targetHeight)) * 10
            s += Double(abs(m.pixelWidth - profile.targetPixelWidth)) * 2
            s += Double(abs(m.pixelHeight - profile.targetPixelHeight)) * 2
            s += abs(m.refreshRate - profile.targetRefreshRate) * 5
            if m.isHiDPI != profile.targetIsHiDPI { s += 5000 }
            return s
        }
        return modes.min { score($0) < score($1) }
    }

    public nonisolated static func isSameMode(_ a: DisplayModeInfo, _ b: DisplayModeInfo?) -> Bool {
        guard let b = b else { return false }
        return a.width == b.width && a.height == b.height
            && a.pixelWidth == b.pixelWidth && a.pixelHeight == b.pixelHeight
            && a.isHiDPI == b.isHiDPI && abs(a.refreshRate - b.refreshRate) < 0.5
    }

    // MARK: - Persistence

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        return d
    }

    private static func loadFromDisk(url: URL) -> [String: MonitorProfile] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? makeDecoder().decode([String: MonitorProfile].self, from: data) else {
            return [:]
        }
        return decoded
    }

    public func reloadFromDisk() {
        profiles = ProfileStore.loadFromDisk(url: fileURL)
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try ProfileStore.makeEncoder().encode(profiles)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("openBetterDisplay: failed to persist profiles: \(error.localizedDescription)")
        }
        onProfilesChanged?()
    }
}
