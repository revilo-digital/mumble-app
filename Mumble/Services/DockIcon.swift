import AppKit

/// Mumble is a background app (`LSUIElement`), so it has no Dock icon unless this is on. Clicking the Dock
/// icon opens Settings.
@MainActor
enum DockIcon {
    static let settingKey = "showInDock"

    static var isShown: Bool {
        UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true
    }

    /// Shows or hides the Dock icon to match the setting.
    static func apply() {
        let policy: NSApplication.ActivationPolicy = isShown ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Switching hides the app's windows' focus; keep Settings in front if it's open.
        if NSApp.windows.contains(where: \.isVisible) { NSApp.activate() }
    }
}
