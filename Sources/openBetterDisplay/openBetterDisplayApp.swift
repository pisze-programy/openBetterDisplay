import SwiftUI
import OpenBetterDisplayCore

/// App entry point. All UI (status item, popover, settings window) is owned by `AppDelegate` so the
/// `LSUIElement` menu bar app can activate its windows reliably.
@main
struct openBetterDisplayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // A scene is required by `App`; the real Settings window is `SettingsWindowController`.
        Settings {
            EmptyView()
        }
    }
}
