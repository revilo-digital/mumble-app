import CoreAudio
import Testing
@testable import Mumble

struct MicrophoneChoiceTests {
    static let builtIn = InputDevice(id: 1, uid: "built-in", name: "MacBook Air Microphone", transport: kAudioDeviceTransportTypeBuiltIn)
    static let webcam = InputDevice(id: 2, uid: "brio", name: "MX Brio", transport: kAudioDeviceTransportTypeUSB)
    static let teams = InputDevice(id: 3, uid: "teams", name: "Microsoft Teams Audio", transport: kAudioDeviceTransportTypeVirtual)
    static let airPods = InputDevice(id: 4, uid: "airpods", name: "AirPods", transport: kAudioDeviceTransportTypeBluetooth)
    static let all = [builtIn, teams, webcam, airPods]

    @Test func automaticFollowsTheMac() {
        #expect(MicrophoneChoice.pick(savedUID: "", devices: Self.all, defaultID: 1, lidClosed: false) == Self.builtIn)
        #expect(MicrophoneChoice.pick(savedUID: "", devices: Self.all, defaultID: 4, lidClosed: false) == Self.airPods)
    }

    /// The built-in mic hears nothing with the lid shut, so a real mic is used, never a virtual one.
    @Test func lidClosedSkipsTheBuiltInMic() {
        #expect(MicrophoneChoice.pick(savedUID: "", devices: Self.all, defaultID: 1, lidClosed: true) == Self.webcam)
        #expect(MicrophoneChoice.pick(savedUID: "built-in", devices: Self.all, defaultID: 1, lidClosed: true) == Self.webcam)
    }

    @Test func lidClosedWithNothingElseKeepsTheMacsInput() {
        let devices = [Self.builtIn, Self.teams]
        #expect(MicrophoneChoice.pick(savedUID: "", devices: devices, defaultID: 1, lidClosed: true) == Self.builtIn)
    }

    @Test func chosenMicWins() {
        #expect(MicrophoneChoice.pick(savedUID: "airpods", devices: Self.all, defaultID: 1, lidClosed: false) == Self.airPods)
        #expect(MicrophoneChoice.pick(savedUID: "teams", devices: Self.all, defaultID: 1, lidClosed: true) == Self.teams)
    }

    /// Unplugged: fall back to what Automatic would use.
    @Test func chosenMicMissingFallsBack() {
        #expect(MicrophoneChoice.pick(savedUID: "gone", devices: Self.all, defaultID: 4, lidClosed: false) == Self.airPods)
        #expect(MicrophoneChoice.pick(savedUID: "gone", devices: Self.all, defaultID: 1, lidClosed: true) == Self.webcam)
    }
}
