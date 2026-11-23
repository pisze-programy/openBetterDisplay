import SwiftUI
import OpenBetterDisplayCore

@main
struct openBetterDisplayApp: App {
    var body: some Scene {
        MenuBarExtra("openBetterDisplay", systemImage: "display.2") {
            Button("openBetterDisplay v1.0") {}
                .disabled(true)
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
