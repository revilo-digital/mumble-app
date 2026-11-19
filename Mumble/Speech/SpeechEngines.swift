import AVFoundation
import Foundation
import Observation

/// The speech engines the user can choose between.
enum SpeechEngineChoice: String, CaseIterable, Identifiable {
    case whisper, apple
    var id: Self { self }

    static let settingKey = "speechEngine"

    /// Whisper unless the user chose Apple: on a new Mac it downloads at first launch, and Apple's engine is used
    /// until it's ready.
    static var current: SpeechEngineChoice {
        UserDefaults.standard.string(forKey: settingKey).flatMap(SpeechEngineChoice.init(rawValue:)) ?? .whisper
    }
}

/// Uses the chosen engine. With Whisper, Apple's engine runs alongside: Whisper only starts once the user lets go,
/// so if it isn't loaded yet, fails or hears something from silence, Apple's text is there to use instead.
final class SpeechRouter: Transcriber {
    let apple: AppleTranscriber
    let whisper: WhisperEngine
    /// Which engine is chosen, read at the start of each dictation.
    private let choice: @Sendable () -> SpeechEngineChoice

    init(apple: AppleTranscriber, whisper: WhisperEngine, choice: @escaping @Sendable () -> SpeechEngineChoice = { SpeechEngineChoice.current }) {
        self.apple = apple
        self.whisper = whisper
        self.choice = choice
    }

    func prepare() async throws {
        try await apple.prepare()
    }

    /// How long Whisper gets before Apple's text is used instead. It usually takes about 2 s, plus about 1 s for each
    /// 30 s of speech; an 88 s dictation took 10 s while another app was using the GPU.
    static func whisperLimit(forSeconds seconds: Double) -> Double {
        6 + seconds * 0.15
    }

    func transcribe(_ audio: AsyncStream<AudioChunk>, hints: [String], session: TranscriptionSession) async throws -> String {
        guard choice() == .whisper, await whisper.isReady else {
            session.engine = "apple"
            return try await apple.transcribe(audio, hints: hints, session: session)
        }
        // Apple's engine gets every chunk as it arrives; Whisper gets them all at the end.
        let (appleAudio, appleFeed) = AsyncStream.makeStream(of: AudioChunk.self)
        let appleText = Task { [apple] in try await apple.transcribe(appleAudio, hints: hints, session: TranscriptionSession()) }
        let converter = AudioConverter(to: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!)
        var samples: [Float] = []
        for await chunk in audio {
            appleFeed.yield(chunk)
            if let converted = converter.convert(chunk.buffer), let channel = converted.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
            }
        }
        appleFeed.finish()
        if Task.isCancelled {
            appleText.cancel()
            throw CancellationError()
        }

        let started = Date()
        let seconds = Double(samples.count) / 16_000
        let limit = Self.whisperLimit(forSeconds: seconds)
        let prompt = session.prompt
        let work = Task { [whisper, samples] in try await whisper.transcribe(samples, prompt: prompt) }
        let heardByWhisper: String
        switch await result(of: work, within: .seconds(limit)) {
        case let .success(text):
            heardByWhisper = text
        case let .failure(error):
            Log.speech.error("Whisper failed, so used Apple's text: \(error.localizedDescription, privacy: .public)")
            session.engine = "apple"
            return try await appleText.value
        case nil:
            // Busy (another app using the GPU) or a very long dictation: Apple's text beats nothing.
            Log.speech.error("Whisper took over \(limit, format: .fixed(precision: 0), privacy: .public)s for \(seconds, format: .fixed(precision: 0), privacy: .public)s of speech, so used Apple's text")
            session.engine = "apple"
            return try await appleText.value
        }
        let heardByApple = (try? await appleText.value) ?? ""
        Log.speech.notice("Whisper took \(Date().timeIntervalSince(started), format: .fixed(precision: 2), privacy: .public)s")
        // Whisper invents text ("Thank you.") from silence; if Apple heard nothing, nothing was said.
        if heardByApple.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            session.engine = "apple"
            return ""
        }
        session.engine = "whisper"
        session.alsoHeard = heardByApple
        return heardByWhisper.isEmpty ? heardByApple : heardByWhisper
    }
}

/// The engine choice and Whisper's download and loading, for Settings.
@MainActor
@Observable
final class SpeechEngines {
    enum WhisperStatus: Equatable {
        case notDownloaded
        case downloading(Double)
        /// Setting up for the Neural Engine. The first time on a Mac this can take a few minutes.
        case loading
        case ready
        case failed(String)
    }

    private(set) var choice = SpeechEngineChoice.current
    private(set) var whisperStatus: WhisperStatus = WhisperEngine.isDownloaded ? .loading : .notDownloaded
    let whisper = WhisperEngine()
    @ObservationIgnored private var work: Task<Void, Never>?

    /// At launch: loads Whisper in the background if it's the chosen engine.
    func launch() {
        whisperStatus = WhisperEngine.isDownloaded ? .loading : .notDownloaded
        if choice == .whisper { loadWhisper() }
    }

    func choose(_ engine: SpeechEngineChoice) {
        choice = engine
        UserDefaults.standard.set(engine.rawValue, forKey: SpeechEngineChoice.settingKey)
        switch engine {
        case .whisper:
            loadWhisper()
        case .apple:
            work?.cancel()
            work = nil
            Task { [whisper] in await whisper.unload() }
            if WhisperEngine.isDownloaded { whisperStatus = .loading }
        }
    }

    /// Runs Whisper on a saved recording, with the context it would have had. Returns the text and seconds taken.
    func tryWhisper(on audioURL: URL, words: [String], context: DictationContext, earlier: [SpeechContext.Earlier], date: Date) async throws -> (String, TimeInterval) {
        let samples = try Self.samples(from: audioURL)
        let prompt = SpeechContext.prompt(words: words, context: context, earlier: earlier, now: date)
        let started = Date()
        let text = try await whisper.transcribe(samples, prompt: prompt)
        return (text, Date().timeIntervalSince(started))
    }

    /// A saved recording's audio as 16 kHz mono floats.
    nonisolated static func samples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    /// Downloads Whisper (if needed) and loads it.
    func loadWhisper() {
        guard work == nil, whisperStatus != .ready else { return }
        let needsDownload = !WhisperEngine.isDownloaded
        whisperStatus = needsDownload ? .downloading(0) : .loading
        work = Task { [whisper] in
            do {
                if needsDownload {
                    try await whisper.download { fraction in
                        Task { @MainActor in
                            // The tokenizer and Neural Engine set-up come after the files.
                            self.whisperStatus = fraction < 1 ? .downloading(fraction) : .loading
                        }
                    }
                } else {
                    try await whisper.load()
                }
                guard !Task.isCancelled else { return }
                whisperStatus = .ready
            } catch {
                guard !Task.isCancelled else { return }
                Log.speech.error("Whisper didn't load: \(error.localizedDescription, privacy: .public)")
                whisperStatus = .failed(error.localizedDescription)
            }
            work = nil
        }
    }
}

/// What Whisper is told came before this dictation.
enum SpeechContext {
    /// A recent dictation.
    struct Earlier: Equatable {
        var text: String
        var bundleID: String?
        var date: Date
    }

    /// Recent dictations count for this long in the same app, and only briefly in another: switching from Cursor
    /// to Mail usually means a new topic.
    static let sameAppWindow: TimeInterval = 15 * 60
    static let otherAppWindow: TimeInterval = 2 * 60

    /// Custom words first, then the window, recent dictations and the text before the cursor, nearest last.
    static func prompt(words: [String], context: DictationContext, earlier: [Earlier], now: Date) -> String {
        var parts: [String] = []
        if !words.isEmpty { parts.append(words.joined(separator: ", ") + ".") }
        if let title = cleanTitle(context.windowTitle, app: context.app) { parts.append(title + ".") }
        for item in earlier {
            let age = now.timeIntervalSince(item.date)
            let window = item.bundleID == context.bundleID ? sameAppWindow : otherAppWindow
            if age >= 0, age <= window { parts.append(item.text) }
        }
        if let before = context.textBefore?.trimmingCharacters(in: .whitespacesAndNewlines), !before.isEmpty {
            parts.append(String(before.suffix(300)))
        }
        return parts.joined(separator: " ")
    }

    /// Drops the app's name and browser clutter ("High memory usage - 937 MB", "Sam (Work)") from a window title.
    static func cleanTitle(_ title: String?, app: String?) -> String? {
        guard let title else { return nil }
        // Split on spaced dashes and bars only, so "to-do" stays whole.
        var parts = title.split(separator: /\s[-–—|]\s/).map { $0.trimmingCharacters(in: .whitespaces) }
        if let app, let index = parts.firstIndex(where: { $0.caseInsensitiveCompare(app) == .orderedSame }) {
            parts = Array(parts[..<index])  // Browsers put the profile name after the app's.
        }
        parts.removeAll { part in
            part.isEmpty || part.localizedCaseInsensitiveContains("memory usage")
                || part.range(of: #"^\d+(\.\d+)?\s?(KB|MB|GB)$"#, options: .regularExpression) != nil
        }
        let cleaned = parts.joined(separator: " - ")
        return cleaned.isEmpty ? nil : cleaned
    }
}
