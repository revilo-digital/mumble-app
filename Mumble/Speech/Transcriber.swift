import AVFoundation
import Speech
import Synchronization
import os

/// Turns audio into raw text. Swappable: Apple's engine, or Whisper.
protocol Transcriber: Sendable {
    /// Gets the engine ready (speech model installed), so the first dictation doesn't wait for it.
    func prepare() async throws
    /// Reads audio until the stream finishes, then returns the text. Cancelling the task throws.
    /// `hints` are the user's custom words, for engines that can listen out for them. `session` carries the
    /// context in (for Whisper) and which engine was used out.
    func transcribe(_ audio: AsyncStream<AudioChunk>, hints: [String], session: TranscriptionSession) async throws -> String
}

extension Transcriber {
    func transcribe(_ audio: AsyncStream<AudioChunk>, hints: [String] = []) async throws -> String {
        try await transcribe(audio, hints: hints, session: TranscriptionSession())
    }
}

/// One dictation's exchange with the speech engine. The context is filled in just after listening starts (reading
/// it can be slow) and read when the audio ends; the engine says which one it was.
final class TranscriptionSession: Sendable {
    private let state = Mutex(State())

    private struct State {
        var prompt = ""
        var engine = "apple"
        var alsoHeard: String?
    }

    init() {}

    /// For Whisper: custom words and what came just before.
    var prompt: String {
        get { state.withLock { $0.prompt } }
        set { state.withLock { $0.prompt = newValue } }
    }

    /// "apple" or "whisper".
    var engine: String {
        get { state.withLock { $0.engine } }
        set { state.withLock { $0.engine = newValue } }
    }

    /// What the other engine heard, when both ran (Apple's text when Whisper was used).
    var alsoHeard: String? {
        get { state.withLock { $0.alsoHeard } }
        set { state.withLock { $0.alsoHeard = newValue } }
    }
}

enum TranscriptionError: Error {
    case noAudioFormat
}

/// Apple's on-device `SpeechTranscriber` (SpeechAnalyzer, macOS 26).
actor AppleTranscriber: Transcriber {
    private var setup: Task<Locale, Error>?

    func prepare() async throws {
        _ = try await readyLocale()
    }

    func transcribe(_ audio: AsyncStream<AudioChunk>, hints: [String], session: TranscriptionSession) async throws -> String {
        let locale = try await readyLocale()
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(
            modules: [module],
            options: .init(priority: .userInitiated, modelRetention: .processLifetime)
        )
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw TranscriptionError.noAudioFormat
        }

        let results = Task {
            var text = ""
            for try await result in module.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }

        if !hints.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = hints
            try await analyzer.setContext(context)
        }
        let (input, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.start(inputSequence: input)

        // Audio arrives while the user talks, so most of the work is done by the time they let go.
        let converter = AudioConverter(to: format)
        var fed = 0
        for await chunk in audio {
            if let converted = converter.convert(chunk.buffer) {
                feed.yield(AnalyzerInput(buffer: converted))
                fed += 1
            }
        }
        feed.finish()

        // With no audio at all (stopped straight away), finalizing never returns.
        if Task.isCancelled || fed == 0 {
            await analyzer.cancelAndFinishNow()
            results.cancel()
            if fed == 0, !Task.isCancelled { return "" }
            throw CancellationError()
        }
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await results.value
    }

    /// Picks the speech model for the Mac's language and installs it if macOS hasn't yet.
    private func readyLocale() async throws -> Locale {
        if let setup { return try await setup.value }
        let task = Task { () throws -> Locale in
            let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current)
                ?? Locale(identifier: "en_GB")
            let module = SpeechTranscriber(locale: locale, preset: .transcription)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                Log.speech.notice("Installing speech model for \(locale.identifier, privacy: .public)")
                try await request.downloadAndInstall()
            }
            Log.speech.notice("Speech model ready: \(locale.identifier, privacy: .public)")
            return locale
        }
        setup = task
        do {
            return try await task.value
        } catch {
            setup = nil
            throw error
        }
    }
}

/// Converts microphone audio (often 48 kHz float) to the format the speech model wants (16 kHz mono).
final class AudioConverter {
    let output: AVAudioFormat
    private var converter: AVAudioConverter?

    init(to output: AVAudioFormat) {
        self.output = output
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == output { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: output)
        }
        guard let converter else { return nil }
        let ratio = output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }

        let input = OneShotInput(buffer)
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, status in
            input.next(status)
        }
        guard status != .error, converted.frameLength > 0 else { return nil }
        return converted
    }
}

/// Hands the converter one buffer, then says there's nothing more for now.
private final class OneShotInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let buffer else {
            status.pointee = .noDataNow
            return nil
        }
        self.buffer = nil
        status.pointee = .haveData
        return buffer
    }
}
