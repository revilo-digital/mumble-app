import CoreAudio
import Foundation
import IOKit

/// A microphone (any audio device with input).
struct InputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    /// Stays the same across restarts and replugging, so it's what the setting saves.
    let uid: String
    let name: String
    let transport: UInt32

    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }

    /// Software devices (Teams, Loom, aggregates) only carry sound another app sends them.
    var isVirtual: Bool {
        transport == kAudioDeviceTransportTypeVirtual
            || transport == kAudioDeviceTransportTypeAggregate
            || transport == kAudioDeviceTransportTypeAutoAggregate
    }
}

/// Which microphone to record from. "Automatic" (saved as "") follows the Mac's input setting.
/// Either way, a MacBook's built-in mic records only silence while the lid is closed, so then another
/// connected mic is used instead.
enum MicrophoneChoice {
    /// The chosen device's UID, or "" for Automatic.
    static let settingKey = "microphone"
    /// Its name, to show while it's unplugged.
    static let nameKey = "microphoneName"

    static func pick(savedUID: String, devices: [InputDevice], defaultID: AudioDeviceID?, lidClosed: Bool) -> InputDevice? {
        let usable = devices.filter { !(lidClosed && $0.isBuiltIn) }
        if !savedUID.isEmpty, let saved = usable.first(where: { $0.uid == savedUID }) { return saved }
        if let system = usable.first(where: { $0.id == defaultID }) { return system }
        return usable.first { !$0.isVirtual } ?? devices.first { $0.id == defaultID }
    }

    /// The mic to use right now.
    static func current(_ defaults: UserDefaults = .standard) -> InputDevice? {
        pick(
            savedUID: defaults.string(forKey: settingKey) ?? "",
            devices: InputDevices.all(),
            defaultID: InputDevices.defaultID,
            lidClosed: InputDevices.lidClosed
        )
    }
}

/// Reads the Mac's audio devices from Core Audio.
enum InputDevices {
    static func all() -> [InputDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap(device)
    }

    /// The input chosen in System Settings › Sound.
    static var defaultID: AudioDeviceID? {
        number(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
    }

    /// True when a MacBook's lid is shut (running on an external display).
    static var lidClosed: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }

    private static func device(_ id: AudioDeviceID) -> InputDevice? {
        guard hasInput(id),
              let uid = string(id, kAudioDevicePropertyDeviceUID),
              let name = string(id, kAudioObjectPropertyName)
        else { return nil }
        return InputDevice(id: id, uid: uid, name: name, transport: number(id, kAudioDevicePropertyTransportType) ?? 0)
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = Self.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func number(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = Self.address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = Self.address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}
