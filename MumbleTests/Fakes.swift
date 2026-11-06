import AVFoundation
import Foundation
@testable import Mumble

final class FakeField: FocusedField {
    let id: Int
    let isSecure: Bool

    init(_ id: Int, secure: Bool = false) {
        self.id = id
        isSecure = secure
    }

    func isSame(as other: any FocusedField) -> Bool {
        (other as? FakeField)?.id == id
    }
}

@MainActor
final class FakeSystem: SystemUI {
    var frontmost: pid_t? = 100
    var running: Set<pid_t> = [100, 200]
    var focused: [pid_t: FakeField] = [100: FakeField(1)]
    var dead: Set<Int> = []
    var acceptsDirectInsert = true
    private(set) var directInserts: [String] = []
    private(set) var pastes = 0
    /// What the clipboard held when ⌘V was sent.
    var clipboard: FakeClipboard?
    private(set) var pastedText: [String] = []

    func frontmostPID() -> pid_t? { frontmost }
    func isRunning(_ pid: pid_t) -> Bool { running.contains(pid) }
    func focusedField(in pid: pid_t) -> (any FocusedField)? { focused[pid] }
    func isAlive(_ field: any FocusedField) -> Bool { !dead.contains((field as! FakeField).id) }

    func insertDirectly(_ text: String, into field: any FocusedField) async -> Bool {
        guard acceptsDirectInsert else { return false }
        directInserts.append(text)
        return true
    }

    func sendPaste() {
        pastes += 1
        if let text = clipboard?.text { pastedText.append(text) }
    }
}

@MainActor
final class FakeClipboard: Clipboard {
    private(set) var changeCount = 0
    var contents = ClipboardSnapshot(items: [["public.utf8-plain-text": Data("old".utf8)]])
    private(set) var lastWasTransient = false

    var text: String? {
        contents.items.first?["public.utf8-plain-text"].flatMap { String(data: $0, encoding: .utf8) }
    }

    func snapshot() -> ClipboardSnapshot { contents }

    func restore(_ snapshot: ClipboardSnapshot) {
        contents = snapshot
        changeCount += 1
    }

    func setText(_ text: String, transient: Bool) {
        contents = ClipboardSnapshot(items: [["public.utf8-plain-text": Data(text.utf8)]])
        lastWasTransient = transient
        changeCount += 1
    }

    /// Something else copied while Mumble was waiting to put the clipboard back.
    func userCopies(_ text: String) { setText(text, transient: false) }
}

@MainActor
final class FakeMicrophone: AudioSource {
    private(set) var isRecording = false
    var fails = false
    private var onChunk: (@Sendable (AudioChunk) -> Void)?

    func start(onChunk: @escaping @Sendable (AudioChunk) -> Void, onLevel: @escaping @Sendable (Float) -> Void) throws {
        if fails { throw MicrophoneError.noInput }
        isRecording = true
        self.onChunk = onChunk
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        onChunk(AudioChunk(buffer: AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!))
    }

    func stop() {
        isRecording = false
        onChunk = nil
    }
}

@MainActor
final class FakeMuter: SoundMuter {
    private(set) var isMuted = false
    private(set) var muteCount = 0

    func mute() {
        isMuted = true
        muteCount += 1
    }

    func restore() { isMuted = false }
}

/// Cleans up by a rule given in the test, or fails, or never finishes.
actor FakeCleaner: Cleaner {
    enum Behaviour { case transform(@Sendable (String) -> String), fail, hang }
    let behaviour: Behaviour
    private(set) var prepared = 0
    private(set) var contexts: [CleanupContext] = []

    init(_ behaviour: Behaviour) { self.behaviour = behaviour }

    func prepare() async { prepared += 1 }

    func clean(_ raw: String, context: CleanupContext) async throws -> String {
        contexts.append(context)
        switch behaviour {
        case let .transform(rule): return rule(raw)
        case .fail: throw CleanupError.unavailable("test")
        case .hang:
            try await Task.sleep(for: .seconds(3600))
            return raw
        }
    }
}

/// Never finishes, like the speech engine did with no audio.
struct StuckTranscriber: Transcriber {
    func prepare() async throws {}

    func transcribe(_ audio: AsyncStream<AudioChunk>, hints: [String]) async throws -> String {
        for await _ in audio {}
        try await Task.sleep(for: .seconds(3600))
        return ""
    }
}

/// Reads all the audio, then returns a fixed transcript.
struct FakeTranscriber: Transcriber {
    var text: String

    func prepare() async throws {}

    func transcribe(_ audio: AsyncStream<AudioChunk>, hints: [String]) async throws -> String {
        for await _ in audio {}
        try Task.checkCancellation()
        return text
    }
}

/// A clock the tests move by hand.
@MainActor
final class TestClock {
    var now = Date(timeIntervalSinceReferenceDate: 0)
    func advance(_ seconds: TimeInterval) { now += seconds }
}
