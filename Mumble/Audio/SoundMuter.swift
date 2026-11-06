import AudioToolbox
import CoreAudio
import Foundation

/// Quietens the Mac's other sound while the user talks.
@MainActor
protocol SoundMuter: AnyObject {
    func mute()
    /// Puts the sound back as it was. Safe to call when nothing was muted.
    func restore()
}

/// Mutes the default output device, or turns its volume to 0 if it can't be muted (some USB and HDMI
/// outputs), and puts it back afterwards. If the sound was already off, it leaves it alone.
///
/// What it changed is saved, so if Mumble quits while you're talking, the next launch puts it back.
@MainActor
final class SystemSoundMuter: SoundMuter {
    static let settingKey = "muteWhileTalking"
    private static let savedKey = "mutedOutput"

    private struct Saved: Codable {
        var deviceUID: String
        /// The volume before, if the volume was turned down instead of muting.
        var volume: Float32?
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var isOn: Bool { defaults.object(forKey: Self.settingKey) as? Bool ?? true }

    private var saved: Saved? {
        get { defaults.data(forKey: Self.savedKey).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.savedKey) }
    }

    func mute() {
        guard isOn, saved == nil, let device = Self.defaultOutput(), let uid = Self.uid(of: device) else { return }
        if Self.canSet(kAudioDevicePropertyMute, on: device) {
            guard Self.get(UInt32.self, kAudioDevicePropertyMute, on: device) == 0 else { return }
            saved = Saved(deviceUID: uid)
            Self.set(UInt32(1), kAudioDevicePropertyMute, on: device)
            Log.dictation.notice("Muted other sound")
        } else if Self.canSet(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, on: device),
                  let volume = Self.get(Float32.self, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, on: device),
                  volume > 0 {
            saved = Saved(deviceUID: uid, volume: volume)
            Self.set(Float32(0), kAudioHardwareServiceDeviceProperty_VirtualMainVolume, on: device)
            Log.dictation.notice("Turned other sound down")
        }
    }

    func restore() {
        guard let saved else { return }
        self.saved = nil
        guard let device = Self.device(uid: saved.deviceUID) else { return }
        if let volume = saved.volume {
            // Only if it's still at 0, in case the user turned it up meanwhile.
            if Self.get(Float32.self, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, on: device) == 0 {
                Self.set(volume, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, on: device)
            }
        } else {
            Self.set(UInt32(0), kAudioDevicePropertyMute, on: device)
        }
        Log.dictation.notice("Sound back on")
    }

    // MARK: Core Audio

    private static func address(_ selector: AudioObjectPropertySelector, output: Bool) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: output ? kAudioDevicePropertyScopeOutput : kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func defaultOutput() -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice, output: false)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func uid(of device: AudioObjectID) -> String? {
        var address = address(kAudioDevicePropertyDeviceUID, output: false)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private static func device(uid: String) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslateUIDToDevice, output: false)
        var cfUID = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), pointer, &size, &device
            )
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func canSet(_ selector: AudioObjectPropertySelector, on device: AudioObjectID) -> Bool {
        var address = address(selector, output: true)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private static func get<T: Numeric & BitwiseCopyable>(_: T.Type, _ selector: AudioObjectPropertySelector, on device: AudioObjectID) -> T? {
        var address = address(selector, output: true)
        var value: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func set<T: BitwiseCopyable>(_ value: T, _ selector: AudioObjectPropertySelector, on device: AudioObjectID) {
        var address = address(selector, output: true)
        var value = value
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value)
        if status != noErr {
            Log.dictation.error("Couldn't change the sound: \(status, privacy: .public)")
        }
    }
}
