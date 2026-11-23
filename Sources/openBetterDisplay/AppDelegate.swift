import AppKit
import OpenBetterDisplayCore

/// Owns `AppController`, the menu bar item and the Settings window.
///
/// Supported launch flags (used for automated UI verification):
/// - `--show-popover`      opens the menu bar popover shortly after launch
/// - `--show-settings`     opens the Settings window immediately
/// - `--skip-quit-restore` test-safe mode: uses throw-away profile/settings storage (so no saved profile is
///                         ever auto-applied) and does NOT re-enable the Built-in Display on quit.
///                         Never use this flag in normal operation.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    enum LaunchFlag {
        static let showPopover = "--show-popover"
        static let showSettings = "--show-settings"
        static let skipQuitRestore = "--skip-quit-restore"
    }

    private let arguments = CommandLine.arguments
    private lazy var skipQuitRestore = arguments.contains(LaunchFlag.skipQuitRestore)

    private(set) var appController: AppController!
    private var menuBarController: MenuBarController!
    private var settingsWindowController: SettingsWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        appController = makeAppController()
        settingsWindowController = SettingsWindowController(controller: appController)
        menuBarController = MenuBarController(
            controller: appController,
            openSettings: { [weak self] in self?.showSettings() }
        )

        appController.start()

        if arguments.contains(LaunchFlag.showSettings) {
            showSettings()
        }
        if arguments.contains(LaunchFlag.showPopover) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.menuBarController.showPopover(activate: true)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let appController else { return }
        if skipQuitRestore {
            // Test-safe teardown: identical to `handleApplicationWillTerminate()` minus the Built-in restore.
            appController.failsafeWatchdog.stop()
            appController.mediaKeyInterceptor.stop()
            appController.shortcutManager.unregisterAll()
            appController.nightShiftScheduler.restoreNeutral()
            appController.overlayManager.removeAllOverlays()
            appController.osd.hide(animated: false)
            appController.audioObserver.stopObservingAudioOutputChanges()
            appController.displayManager.stopReconfigurationObserver()
            appController.profileStore.cancelPendingHotplug()
        } else {
            // Synchronously restores the Built-in Display and removes every overlay.
            appController.handleApplicationWillTerminate()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Helpers

    private func showSettings() {
        menuBarController?.closePopover()
        settingsWindowController.show()
    }

    private func makeAppController() -> AppController {
        guard skipQuitRestore else { return AppController() }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("openBetterDisplay-uitest-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        let profiles = ProfileStore(fileURL: scratch.appendingPathComponent("profiles.json"))
        let suite = "com.piszeprogramy.openbetterdisplay.uitest"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return AppController(settingsStore: SettingsStore(defaults: defaults), profileStore: profiles)
    }
}
