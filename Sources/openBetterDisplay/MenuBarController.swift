import AppKit
import SwiftUI
import OpenBetterDisplayCore

/// `NSStatusItem` + transient `NSPopover` hosting `PopoverView`.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let controller: AppController
    private let openSettings: () -> Void
    private let statusItem: NSStatusItem
    private let popover = NSPopover()

    init(controller: AppController, openSettings: @escaping () -> Void) {
        self.controller = controller
        self.openSettings = openSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "openBetterDisplay")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "openBetterDisplay"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let hosting = NSHostingController(
            rootView: PopoverView(
                controller: controller,
                openSettings: { [weak self] in self?.openSettings() },
                quit: { NSApp.terminate(nil) }
            )
        )
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    // MARK: - Popover

    var isPopoverShown: Bool { popover.isShown }

    func showPopover(activate: Bool) {
        guard !popover.isShown, let button = statusItem.button else { return }
        controller.refreshDisplays()
        controller.refreshAccessibilityStatus()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func closePopover() {
        if popover.isShown { popover.performClose(nil) }
    }

    func togglePopover() {
        popover.isShown ? closePopover() : showPopover(activate: true)
    }

    // MARK: - Status item

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func showContextMenu() {
        closePopover()
        let menu = NSMenu()
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(menuOpenSettings), keyEquivalent: ",")
        settings.target = self
        let restore = menu.addItem(withTitle: "Restore All Displays", action: #selector(menuRestoreAll), keyEquivalent: "")
        restore.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit openBetterDisplay", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuOpenSettings() { openSettings() }
    @objc private func menuRestoreAll() { controller.emergencyRestoreAllDisplays() }
    @objc private func menuQuit() { NSApp.terminate(nil) }
}
