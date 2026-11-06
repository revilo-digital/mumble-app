import Foundation
import Testing
@testable import Mumble

@MainActor
struct SoundMuterTests {
    /// Never touches the real sound: with the setting off, mute does nothing at all.
    @Test func doesNothingWhenTurnedOff() {
        let defaults = UserDefaults(suiteName: "SoundMuterTests")!
        defaults.removePersistentDomain(forName: "SoundMuterTests")
        defaults.set(false, forKey: SystemSoundMuter.settingKey)
        let muter = SystemSoundMuter(defaults: defaults)
        muter.mute()
        #expect(defaults.data(forKey: "mutedOutput") == nil)
        muter.restore()
    }
}
