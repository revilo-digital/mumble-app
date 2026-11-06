import AVFoundation
import Foundation
import Testing
@testable import Mumble

/// Runs Apple's real speech engine on a clip made with `say`, fed in the way the microphone feeds it.
struct AppleTranscriberTests {
    @Test(.timeLimit(.minutes(1)))
    func transcribesStreamedAudio() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mumble-test-\(UUID()).aiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "Can we meet on Thursday at three?"]
        try say.run()
        say.waitUntilExit()

        // Like the microphone: float audio in small blocks, at a different rate from the model's.
        let file = try AVAudioFile(forReading: url)
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        while file.framePosition < file.length {
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024)!
            try file.read(into: buffer)
            continuation.yield(AudioChunk(buffer: buffer))
        }

        let transcriber = AppleTranscriber()
        try await transcriber.prepare()
        let started = Date()
        let task = Task { try await transcriber.transcribe(stream) }
        try await Task.sleep(for: .seconds(1))
        let released = Date()
        continuation.finish()
        let text = try await task.value
        let afterRelease = Date().timeIntervalSince(released)
        print("Transcribed \(text.debugDescription) in \(Date().timeIntervalSince(started))s, \(afterRelease)s after the audio ended")

        #expect(text.localizedCaseInsensitiveContains("thursday"))
        #expect(text.localizedCaseInsensitiveContains("meet"))
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingThrows() async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let transcriber = AppleTranscriber()
        let task = Task { try await transcriber.transcribe(stream) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        continuation.finish()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// A double tap can stop it almost at once. It must still finish, not sit there working.
    @Test(.timeLimit(.minutes(1)), arguments: [0, 4])
    func finishesWithAlmostNoAudio(blocks: Int) async throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        for _ in 0..<blocks {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)!
            buffer.frameLength = 960 // 20 ms of silence
            continuation.yield(AudioChunk(buffer: buffer))
        }
        continuation.finish()

        let transcriber = AppleTranscriber()
        try await transcriber.prepare()
        let started = Date()
        let text = try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { try await transcriber.transcribe(stream) }
            group.addTask { try await Task.sleep(for: .seconds(5)); return nil }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        print("Short audio (\(blocks) blocks) took \(Date().timeIntervalSince(started))s")
        #expect(text == "")
    }

    /// Makes a clip with `say` and streams it in like the microphone does.
    static func spoken(_ text: String) throws -> AsyncStream<AudioChunk> {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mumble-test-\(UUID()).aiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, text]
        try say.run()
        say.waitUntilExit()
        let file = try AVAudioFile(forReading: url)
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        while file.framePosition < file.length {
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024)!
            try file.read(into: buffer)
            continuation.yield(AudioChunk(buffer: buffer))
        }
        continuation.finish()
        return stream
    }

    /// Custom words, as hints and then the spelling fix, get names right.
    @Test(.timeLimit(.minutes(1)))
    func customWordsGetNamesRight() async throws {
        let sentence = "We sent the BrightCRM proposal to Siobhan and the Tui Group on Tuesday."
        let names = ["BrightCRM", "Tui Group", "Siobhan"]
        let words = [
            CustomWord(word: "BrightCRM"),
            CustomWord(word: "Tui Group", heardAs: []),
            CustomWord(word: "Siobhan", heardAs: []),
        ]
        let transcriber = AppleTranscriber()
        try await transcriber.prepare()
        let plain = try await transcriber.transcribe(try Self.spoken(sentence), hints: [])
        // Apple's engine ignores hints today, but they're passed in case that changes.
        let hinted = try await transcriber.transcribe(try Self.spoken(sentence), hints: names)
        let fixed = CustomSpelling.apply(words, to: hinted)
        print("HINTS without: \(plain.debugDescription)")
        print("HINTS with:    \(hinted.debugDescription)")
        print("HINTS fixed:   \(fixed.debugDescription)")
        #expect(fixed.contains("BrightCRM"))
        #expect(fixed.contains("Tui Group"))
        #expect(fixed.contains("Siobhan"))
    }
}
