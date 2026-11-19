import AppKit
import SwiftUI

/// Plain AppKit windows for Settings and setup, which an accessory app can bring to the front reliably.
@MainActor
final class AppWindow {
    private var window: NSWindow?

    func show<Content: View>(
        title: String, resizable: Bool = false, initialSize: NSSize? = nil, @ViewBuilder content: () -> Content
    ) {
        if window == nil {
            let host = NSHostingController(rootView: content())
            if resizable { host.sizingOptions = [.minSize] }
            let window = NSWindow(contentViewController: host)
            window.title = title
            window.styleMask = resizable ? [.titled, .closable, .resizable, .miniaturizable] : [.titled, .closable]
            if let size = resizable ? initialSize : nil {
                // Fits a laptop screen, with room for the sidebar, the list and the details.
                let screen = NSScreen.main?.visibleFrame.size ?? size
                window.setContentSize(NSSize(width: min(size.width, screen.width - 40), height: min(size.height, screen.height - 40)))
            }
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
