import AppKit
import SwiftUI

/// A floating panel that never takes focus, so the text box keeps it while you click ✕ or ✓.
final class WidgetPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Clicks work first time, without the panel needing to be active.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Shows the widget while a dictation is going, near the bottom of the screen you're on.
@MainActor
final class WidgetController {
    private let controller: DictationController
    private let panel = WidgetPanel()
    private let hosting: NSHostingView<WidgetView>
    private var escapeMonitors: [Any] = []

    init(controller: DictationController) {
        self.controller = controller
        hosting = FirstClickHostingView(rootView: WidgetView(controller: controller))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = controller.phase
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
    }

    private func update() {
        if controller.phase == .idle {
            removeEscapeMonitors()
            panel.orderOut(nil)
            return
        }
        if controller.phase == .listening { addEscapeMonitors() } else if controller.phase != .working { removeEscapeMonitors() }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let origin = NSPoint(x: (area.midX - size.width / 2).rounded(), y: area.minY + 28)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Esc cancels. The key still reaches the app in front, as there's no way to take it without more permissions.
    private func addEscapeMonitors() {
        guard escapeMonitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated { self?.controller.cancel() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) {
            escapeMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in handler(event); return event }) {
            escapeMonitors.append(local)
        }
    }

    private func removeEscapeMonitors() {
        escapeMonitors.forEach(NSEvent.removeMonitor)
        escapeMonitors.removeAll()
    }
}
