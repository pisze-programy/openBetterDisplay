import AppKit
import SwiftUI
import OpenBetterDisplayCore

/// Dedicated settings window, so it can be activated reliably from an `LSUIElement` app.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let contentSize = NSSize(width: 640, height: 500)

    init(controller: AppController) {
        let hosting = NSHostingController(rootView: SettingsView(controller: controller))
        let window = NSWindow(contentViewController: hosting)
        window.title = "openBetterDisplay Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(Self.contentSize)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("openBetterDisplay.SettingsWindow")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
