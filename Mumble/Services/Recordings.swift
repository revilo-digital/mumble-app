import AppKit
import AVFoundation

/// Keeps the last few dictations (audio and what Mumble made of them) on this Mac, so speech engines can be
/// compared on the user's own voice. Off unless turned on in Settings.
enum Recordings {
    static let settingKey = "keepRecordings"
    /// How many dictations to keep. Older ones are deleted.
    static let limit = 50

    static var isOn: Bool { UserDefaults.standard.bool(forKey: settingKey) }
    /// Posted on the main thread when a recording has been saved.
    static let saved = Notification.Name("MumbleRecordingSaved")

    static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "Mumble/Recordings", directoryHint: .isDirectory)
    }

    /// A writer for a new dictation, or nil when recordings are off.
    static func begin() -> RecordingWriter? {
        guard isOn else { return nil }
        return RecordingWriter(folder: folder, keep: limit)
    }
}

/// What was around the dictation: the app, the window and the text before the cursor.
struct DictationContext: Codable, Sendable, Equatable {
    var app: String?
    var bundleID: String?
    var windowTitle: String?
    /// Up to a few hundred characters before the cursor in the text box.
    var textBefore: String?
}

/// What's saved next to each recording's audio.
struct RecordingInfo: Codable {
    var date: Date
    var context: DictationContext
    var seconds: Double
    /// What Apple's speech engine heard, before any fixing.
    var heard: String
    /// What went into the text box, after custom words and cleanup.
    var inserted: String
    /// Seconds from letting go to the text going in.
    var finishSeconds: Double?
    /// Which speech engine was used: "apple" or "whisper".
    var engine: String?
    /// What the other engine heard, when both ran (Apple's text when Whisper was used).
    var alsoHeard: String?
    /// Filled in by hand: what was actually said.
    var meant: String?
    /// The user's verdict on what went in.
    var rating: Rating?

    enum Rating: String, Codable {
        case good, wrong
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Writes one dictation's audio (16 kHz mono WAV) as it arrives, on its own queue so the microphone never waits.
final class RecordingWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "nz.olly.Mumble.recording")
    private let folder: URL
    private let name: String
    /// Set once it's been read, just after the microphone starts.
    var context: DictationContext {
        get { queue.sync { storedContext } }
        set { queue.async { [self] in storedContext = newValue } }
    }
    private var storedContext: DictationContext
    private let keep: Int
    private let started = Date()
    // Used on `queue` only.
    private var file: AVAudioFile?
    private var converter: AudioConverter?
    private var frames: AVAudioFramePosition = 0
    private var failed = false

    init(folder: URL, context: DictationContext = DictationContext(), keep: Int) {
        self.folder = folder
        storedContext = context
        self.keep = keep
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        name = formatter.string(from: started)
    }

    var audioURL: URL { folder.appending(path: "\(name).wav") }
    var infoURL: URL { folder.appending(path: "\(name).json") }

    func append(_ chunk: AudioChunk) {
        queue.async { [self] in
            guard !failed else { return }
            do {
                if file == nil {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let settings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: 16_000,
                        AVNumberOfChannelsKey: 1,
                        AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false,
                    ]
                    let opened = try AVAudioFile(forWriting: audioURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                    file = opened
                    converter = AudioConverter(to: opened.processingFormat)
                }
                guard let file, let converted = converter?.convert(chunk.buffer) else { return }
                try file.write(from: converted)
                frames += AVAudioFramePosition(converted.frameLength)
            } catch {
                failed = true
                Log.dictation.error("Couldn't save the recording: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Saves what Mumble made of it, then deletes the oldest recordings past the limit.
    func finish(heard: String, inserted: String, finishSeconds: Double?, engine: String? = nil, alsoHeard: String? = nil) {
        queue.async { [self] in
            let hadAudio = file != nil
            file = nil  // Closes the WAV.
            guard hadAudio, !failed else { return }
            let info = RecordingInfo(
                date: started, context: storedContext, seconds: Double(frames) / 16_000,
                heard: heard, inserted: inserted, finishSeconds: finishSeconds, engine: engine, alsoHeard: alsoHeard
            )
            do {
                try RecordingInfo.encoder.encode(info).write(to: infoURL)
            } catch {
                Log.dictation.error("Couldn't save the recording's details: \(error.localizedDescription, privacy: .public)")
            }
            prune()
            DispatchQueue.main.async { NotificationCenter.default.post(name: Recordings.saved, object: nil) }
        }
    }

    /// Cancelled: nothing is kept.
    func discard() {
        queue.async { [self] in
            file = nil
            try? FileManager.default.removeItem(at: audioURL)
        }
    }

    /// Waits for everything queued so far to be written (for tests).
    func flush() {
        queue.sync {}
    }

    private func prune() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        let recordings = names.filter { $0.hasSuffix(".wav") }.sorted()
        for old in recordings.dropLast(keep) {
            let base = folder.appending(path: String(old.dropLast(4)))
            try? FileManager.default.removeItem(at: base.appendingPathExtension("wav"))
            try? FileManager.default.removeItem(at: base.appendingPathExtension("json"))
        }
    }
}

/// One saved dictation, for the Recordings page.
struct SavedRecording: Identifiable, Equatable {
    let name: String
    var info: RecordingInfo
    let audioURL: URL
    let infoURL: URL
    var id: String { name }

    static func == (a: SavedRecording, b: SavedRecording) -> Bool {
        a.name == b.name && a.info.meant == b.info.meant && a.info.rating == b.info.rating
    }
}

/// The saved recordings, newest first, for viewing and marking right or wrong.
@MainActor
@Observable
final class RecordingList {
    private(set) var items: [SavedRecording] = []
    let folder: URL

    init(folder: URL = Recordings.folder) {
        self.folder = folder
    }

    func reload() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        items = names.filter { $0.hasSuffix(".json") }.sorted(by: >).compactMap { file in
            let infoURL = folder.appending(path: file)
            let audioURL = infoURL.deletingPathExtension().appendingPathExtension("wav")
            guard FileManager.default.fileExists(atPath: audioURL.path(percentEncoded: false)),
                  let data = try? Data(contentsOf: infoURL),
                  let info = try? RecordingInfo.decoder.decode(RecordingInfo.self, from: data) else { return nil }
            return SavedRecording(name: String(file.dropLast(5)), info: info, audioURL: audioURL, infoURL: infoURL)
        }
    }

    /// Right as it went in: what was meant is what was typed.
    func markGood(_ item: SavedRecording) {
        var info = item.info
        info.rating = .good
        info.meant = info.inserted
        save(info, for: item)
    }

    /// Wrong: saves what was actually said.
    func markWrong(_ item: SavedRecording, meant: String) {
        var info = item.info
        info.rating = .wrong
        let trimmed = meant.trimmingCharacters(in: .whitespacesAndNewlines)
        info.meant = trimmed.isEmpty ? nil : trimmed
        save(info, for: item)
    }

    /// The dictations just before this one, as context for it.
    func earlier(than item: SavedRecording) -> [SpeechContext.Earlier] {
        items.filter { $0.info.date < item.info.date && !$0.info.inserted.isEmpty }
            .sorted { $0.info.date < $1.info.date }
            .suffix(5)
            .map { SpeechContext.Earlier(text: $0.info.inserted, bundleID: $0.info.context.bundleID, date: $0.info.date) }
    }

    func delete(_ item: SavedRecording) {
        try? FileManager.default.removeItem(at: item.audioURL)
        try? FileManager.default.removeItem(at: item.infoURL)
        items.removeAll { $0.name == item.name }
    }

    private func save(_ info: RecordingInfo, for item: SavedRecording) {
        do {
            try RecordingInfo.encoder.encode(info).write(to: item.infoURL)
        } catch {
            Log.dictation.error("Couldn't save the rating: \(error.localizedDescription, privacy: .public)")
            return
        }
        if let index = items.firstIndex(where: { $0.name == item.name }) { items[index].info = info }
    }

    /// Words in what was meant that the engine didn't get and that look like names or terms worth adding as
    /// custom words: not an everyday word in lower case (Tama, Shopify), or with capitals or digits inside
    /// (BrightCRM, M3). Everyday words it got wrong ("logged" heard as "locked") aren't custom words.
    static func suggestedWords(
        meant: String, heard: String, existing: [String],
        isEverydayWord: @MainActor (String) -> Bool = RecordingList.isEverydayWord
    ) -> [String] {
        func words(_ text: String) -> [String] {
            text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "-" }).map(String.init)
        }
        let heardWords = Set(words(heard).map { $0.lowercased() })
        let known = Set(existing.map { $0.lowercased() })
        var seen = Set<String>()
        return words(meant).filter { word in
            let lower = word.lowercased()
            guard word.count > 1, !heardWords.contains(lower), !known.contains(lower), seen.insert(lower).inserted
            else { return false }
            let hasInnerCapsOrDigits = word.dropFirst().contains(where: { $0.isUppercase || $0.isNumber })
            return hasInnerCapsOrDigits || !isEverydayWord(lower)
        }
    }

    /// The system spell checker knows "logged" but not "blake" or "shopify".
    static func isEverydayWord(_ word: String) -> Bool {
        let checker = NSSpellChecker.shared
        let miss = checker.checkSpelling(of: word, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return miss.location == NSNotFound
    }
}
