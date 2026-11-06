import Foundation
import ServiceManagement

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Mumble should always be running, so it opens at login unless the user has turned that off.
    static func setUpOnFirstLaunch() {
        let key = "didSetUpLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            try set(true)
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            Log.dictation.error("Couldn't add login item: \(error.localizedDescription, privacy: .public)")
        }
    }
}
