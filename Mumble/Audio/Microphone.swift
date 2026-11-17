import AudioToolbox
import AVFoundation
import CoreAudio

/// One block of microphone audio, in its own buffer.
struct AudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

enum MicrophoneError: Error {
    case noInput
    /// A Core Audio call failed, with its status.
    case coreAudio(String, OSStatus)
}

/// Something that records audio. The real one is `Microphone`; tests use a fake.
@MainActor
protocol AudioSource: AnyObject {
    /// Starts recording without waiting for the device. `onChunk` and `onLevel` (0…1) are called on the
    /// audio thread. If the device can't be started, `onFailure` is called on the main thread later; problems
    /// found straight away are thrown.
    func start(
        onChunk: @escaping @Sendable (AudioChunk) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void,
        onFailure: @escaping @MainActor @Sendable (Error) -> Void
    ) throws
    func stop()
}

/// Records from the chosen microphone with a Core Audio input unit (AUHAL).
///
/// Not `AVAudioEngine`: that always starts on the default devices (through an aggregate device when input
/// and output differ) and has to be switched afterwards, which failed with 'nope' and once hung the main
/// thread for good. The input unit is bound to the device before it starts and never touches the output.
///
/// Core Audio can block for a long time (a device waking up, Bluetooth switching), so all of it runs on
/// each recording's own queue. A recording that gets stuck never holds up the app or the next recording.
@MainActor
final class Microphone: AudioSource {
    private var session: InputSession?
    private let choose: @Sendable () -> InputDevice?

    init(choose: @escaping @Sendable () -> InputDevice? = { MicrophoneChoice.current() }) {
        self.choose = choose
    }

    func start(
        onChunk: @escaping @Sendable (AudioChunk) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void,
        onFailure: @escaping @MainActor @Sendable (Error) -> Void
    ) throws {
        stop()
        let session = InputSession(onChunk: onChunk, onLevel: onLevel)
        self.session = session
        let choose = choose
        session.queue.async {
            do {
                try session.open(choose())
            } catch {
                Log.dictation.error("Microphone didn't start: \(String(describing: error), privacy: .public)")
                session.close()
                Task { @MainActor in onFailure(error) }
            }
        }
    }

    func stop() {
        guard let session else { return }
        self.session = nil
        session.queue.async { session.close() }
    }
}

/// One recording. Everything except the render callback happens on `queue`.
private final class InputSession: @unchecked Sendable {
    let queue = DispatchQueue(label: "nz.olly.Mumble.microphone", qos: .userInitiated)
    private let onChunk: @Sendable (AudioChunk) -> Void
    private let onLevel: @Sendable (Float) -> Void
    private var unit: AudioUnit?
    private var isRunning = false
    private var isClosed = false
    /// Set before the unit starts, and only read by the render callback after that.
    private var format: AVAudioFormat?

    init(onChunk: @escaping @Sendable (AudioChunk) -> Void, onLevel: @escaping @Sendable (Float) -> Void) {
        self.onChunk = onChunk
        self.onLevel = onLevel
    }

    func open(_ chosen: InputDevice?) throws {
        // Stopped before it got going.
        guard !isClosed else { return }
        guard let device = chosen?.id ?? InputDevices.defaultID else { throw MicrophoneError.noInput }

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else { throw MicrophoneError.noInput }
        var created: AudioUnit?
        try check("create", AudioComponentInstanceNew(component, &created))
        guard let unit = created else { throw MicrophoneError.noInput }
        self.unit = unit

        // Input on (element 1), output off (element 0), so only the microphone is involved.
        try set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1), "enable input")
        try set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(0), "disable output")
        try set(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, device, "choose device")

        // The device's own rate (the input unit doesn't convert it), as 32-bit float. One channel is all
        // speech needs; the unit takes the device's first.
        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check("read format", AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size))
        guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: hardware.mSampleRate,
                  channels: 1,
                  interleaved: false
              )
        else { throw MicrophoneError.noInput }
        try set(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, format.streamDescription.pointee, "set format")
        self.format = format

        var callback = AURenderCallbackStruct(
            inputProc: inputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        try check("set callback", AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
            &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ))
        try check("initialise", AudioUnitInitialize(unit))
        try check("start", AudioOutputUnitStart(unit))
        isRunning = true
        Log.dictation.notice("Mic: \(chosen?.name ?? "default", privacy: .public), \(Int(format.sampleRate), privacy: .public) Hz")
    }

    func close() {
        isClosed = true
        guard let unit else { return }
        // Stopping waits for the render callback to finish, so it's safe to let go of the unit after.
        if isRunning { AudioOutputUnitStop(unit) }
        isRunning = false
        self.unit = nil
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    /// Called on Core Audio's thread with each block of input: pulls it into a fresh buffer and hands it on.
    fileprivate func render(
        _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        _ time: UnsafePointer<AudioTimeStamp>,
        _ frames: UInt32
    ) -> OSStatus {
        guard let unit, let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return noErr }
        buffer.frameLength = frames
        let status = AudioUnitRender(unit, flags, time, 1, frames, buffer.mutableAudioBufferList)
        guard status == noErr else { return status }
        onLevel(Microphone.level(of: buffer))
        onChunk(AudioChunk(buffer: buffer))
        return noErr
    }

    private func set<T: BitwiseCopyable>(
        _ unit: AudioUnit, _ property: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: AudioUnitElement,
        _ value: T, _ what: String
    ) throws {
        var value = value
        try check(what, AudioUnitSetProperty(unit, property, scope, element, &value, UInt32(MemoryLayout<T>.size)))
    }

    private func check(_ what: String, _ status: OSStatus) throws {
        if status != noErr { throw MicrophoneError.coreAudio(what, status) }
    }
}

private func inputCallback(
    refCon: UnsafeMutableRawPointer,
    flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    time: UnsafePointer<AudioTimeStamp>,
    bus: UInt32,
    frames: UInt32,
    data: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    Unmanaged<InputSession>.fromOpaque(refCon).takeUnretainedValue().render(flags, time, frames)
}

extension Microphone {
    /// Loudness of the first channel as 0…1, for the widget's dots (-50 dB is silence, -10 dB is full).
    nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let decibels = 20 * log10(max(rms, 0.000_01))
        return min(max((decibels + 50) / 40, 0), 1)
    }
}
