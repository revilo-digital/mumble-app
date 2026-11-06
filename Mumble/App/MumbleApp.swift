import SwiftUI

@main
struct MumbleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let app = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(app: app)
        } label: {
            MenuBarIcon(controller: app.controller)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.launch() }
    }

    /// Clicking the Dock icon opens Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainActor.assumeIsolated { AppModel.shared.showSettings() }
        return false
    }
}
