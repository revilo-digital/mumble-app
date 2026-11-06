import AppKit
import SwiftUI

/// Plain AppKit windows for Settings and setup, which an accessory app can bring to the front reliably.
@MainActor
final class AppWindow {
    private var window: NSWindow?

    func show<Content: View>(title: String, @ViewBuilder content: () -> Content) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: content()))
            window.title = title
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }
}
