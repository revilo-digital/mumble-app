import AVFoundation

/// One block of microphone audio, copied out of the engine's tap.
struct AudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

enum MicrophoneError: Error {
    case noInput
}

/// Something that records audio. The real one is `Microphone`; tests use a fake.
@MainActor
protocol AudioSource: AnyObject {
    /// Starts recording. `onChunk` and `onLevel` (0…1) are called on the audio thread.
    func start(onChunk: @escaping @Sendable (AudioChunk) -> Void, onLevel: @escaping @Sendable (Float) -> Void) throws
    func stop()
}

@MainActor
final class Microphone: AudioSource {
    private var engine: AVAudioEngine?

    func start(onChunk: @escaping @Sendable (AudioChunk) -> Void, onLevel: @escaping @Sendable (Float) -> Void) throws {
        stop()
        // A fresh engine each time picks up the current input device (AirPods plugged in, etc.).
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MicrophoneError.noInput }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(onChunk: onChunk, onLevel: onLevel))
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    /// Built outside the main actor: the engine calls it on its own audio thread.
    nonisolated private static func tap(
        onChunk: @escaping @Sendable (AudioChunk) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            onLevel(level(of: buffer))
            if let copy = copy(of: buffer) { onChunk(AudioChunk(buffer: copy)) }
        }
    }

    /// The engine may reuse its buffer after the tap returns, so keep a copy.
    nonisolated static func copy(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(source.count, destination.count) {
            guard let from = source[index].mData, let to = destination[index].mData else { continue }
            let bytes = min(source[index].mDataByteSize, destination[index].mDataByteSize)
            memcpy(to, from, Int(bytes))
            destination[index].mDataByteSize = bytes
        }
        return copy
    }

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
