import Foundation
@preconcurrency import WhisperKit

/// OpenAI's Whisper (large-v3 turbo, through WhisperKit on the Neural Engine). Slower than Apple's engine, as it
/// only starts once the user lets go, but better with accents and names, and it can be given context: the text
/// that came before, which it treats as what was just said.
actor WhisperEngine {
    static let variant = "openai_whisper-large-v3-v20240930_turbo_632MB"
    /// About 630 MB.
    static let downloadSize = "630 MB"

    static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "Mumble/Whisper", directoryHint: .isDirectory)
    }

    static var modelFolder: URL {
        folder.appending(path: "models/argmaxinc/whisperkit-coreml/\(variant)", directoryHint: .isDirectory)
    }

    private static var tokenizerFile: URL {
        folder.appending(path: "models/openai/whisper-large-v3/tokenizer.json")
    }

    static var isDownloaded: Bool {
        let files = [modelFolder.appending(path: "AudioEncoder.mlmodelc"), modelFolder.appending(path: "TextDecoder.mlmodelc"), tokenizerFile]
        return files.allSatisfy { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    private var kit: WhisperKit?
    private var loading: Task<WhisperKit, Error>?

    var isReady: Bool { kit != nil }

    /// Downloads the model and its tokenizer from Hugging Face (argmaxinc/whisperkit-coreml, openai/whisper-large-v3).
    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        _ = try await WhisperKit.download(variant: Self.variant, downloadBase: Self.folder) { update in
            progress(update.fractionCompleted)
        }
        // Loading once fetches the tokenizer too, and does the slow first set-up for the Neural Engine.
        try await load()
    }

    /// Loads the model. The first load on a Mac sets it up for the Neural Engine, which can take a few minutes.
    func load() async throws {
        if kit != nil { return }
        if let loading {
            kit = try await loading.value
            return
        }
        let config = WhisperKitConfig(
            downloadBase: Self.folder,
            modelFolder: Self.modelFolder.path(percentEncoded: false),
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false
        )
        let task = Task { try await WhisperKit(config) }
        loading = task
        defer { loading = nil }
        let started = Date()
        let loaded = try await task.value
        kit = loaded
        Log.speech.notice("Whisper loaded in \(Date().timeIntervalSince(started), format: .fixed(precision: 1), privacy: .public)s")
    }

    /// Frees the model when Whisper isn't the chosen engine.
    func unload() async {
        loading?.cancel()
        loading = nil
        await kit?.unloadModels()
        kit = nil
    }

    /// Transcribes 16 kHz mono audio. `prompt` is the context: custom words and what came just before.
    func transcribe(_ samples: [Float], prompt: String) async throws -> String {
        guard let kit else { throw WhisperError.notReady }
        var options = DecodingOptions()
        options.language = "en"
        options.temperature = 0
        options.usePrefillPrompt = true
        options.skipSpecialTokens = true
        options.withoutTimestamps = true
        options.chunkingStrategy = .vad
        if !prompt.isEmpty, let tokenizer = kit.tokenizer {
            let tokens = tokenizer.encode(text: " " + prompt).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            // Whisper reads at most about 224 tokens of context; keep the most recent.
            options.promptTokens = Array(tokens.suffix(200))
        }
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum WhisperError: Error {
    case notReady
}
