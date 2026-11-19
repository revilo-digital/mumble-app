// Transcribes WAV files with Apple's SpeechTranscriber (as Mumble does) and prints JSON lines:
// {"file": ..., "text": ..., "seconds": ...}. The model is loaded once, before timing starts.
import AVFoundation
import Foundation
import Speech

@main struct AppleTranscribe {
    static func main() async throws {
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) ?? Locale(identifier: "en_NZ")
        for path in CommandLine.arguments.dropFirst() {
            let module = SpeechTranscriber(locale: locale, preset: .transcription)
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            let started = Date()
            let results = Task {
                var text = ""
                for try await result in module.results where result.isFinal { text += String(result.text.characters) }
                return text
            }
            let analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [module], finishAfterFile: true)
            _ = analyzer
            let text = try await results.value
            let line: [String: Any] = ["file": path, "text": text.trimmingCharacters(in: .whitespaces), "seconds": Date().timeIntervalSince(started)]
            print(String(data: try JSONSerialization.data(withJSONObject: line), encoding: .utf8)!)
        }
    }
}
