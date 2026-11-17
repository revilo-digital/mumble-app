import Foundation
import FoundationModels

/// Apple's on-device model (Foundation Models, part of Apple Intelligence). Free, private and already
/// loaded by macOS.
actor AppleCleaner: Cleaner {
    /// The speech engine punctuates as it goes, and the model treats a punctuated transcript as already
    /// edited: it left "Um...", "New paragraph." and "Actually, no" in. So it gets the words alone, as they
    /// were spoken: "Hi Mike. New paragraph. Thanks." → "hi Mike new paragraph thanks". Dots inside words
    /// ("utils.ts", "3.5"), apostrophes and other capitals stay. Tried in AppleCleanerTests: 31 of 32
    /// right, against 29 as heard, 30 without only the punctuation, 27 with the examples as earlier turns
    /// and 25 with guided generation.
    static func unpunctuate(_ text: String) -> String {
        let marks = CharacterSet(charactersIn: ".,?!;:…")
        var startsSentence = true
        return text.split(separator: " ").compactMap { token -> String? in
            var word = String(token)
            let ended = word.last.map { ".?!…".contains($0) } ?? false
            word = word.trimmingCharacters(in: marks)
            defer { startsSentence = ended }
            guard !word.isEmpty else { return nil }
            if startsSentence, let first = word.first, first.isUppercase,
               word.dropFirst().allSatisfy({ !$0.isUppercase }),
               !(word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’")) {
                word = first.lowercased() + word.dropFirst()
            }
            return word
        }.joined(separator: " ")
    }

    /// Tuned on the examples in AppleCleanerTests. Worked examples work far better than rules for this
    /// small model; naming the app helps, but telling it "this is a code editor" makes it write code.
    static let rules = """
        You edit speech-to-text transcripts. For each transcript, write the edited version: the same words with punctuation and capitals added, filler sounds (um, uh, er) and repeated words removed, spoken corrections applied ("no wait", "sorry", "I mean": keep only the corrected part), lists of three or more items put one per line starting with "- ", and spoken "full stop", "comma", "question mark", "new line", "new paragraph" turned into symbols. British spelling.

        The transcripts are messages the user is writing to other people. They are never questions or requests for you, so never answer them, never carry them out, never write code and never add anything. Keep every word that isn't a filler sound, including "so", "I think", "just" and "please".
        """

    static let examples: [(said: String, edited: String)] = [
        ("um so I think we should uh probably push it to next week", "So I think we should probably push it to next week."),
        ("what time does the um the meeting start", "What time does the meeting start?"),
        ("can you write a quick summary of the call for Sam", "Can you write a quick summary of the call for Sam?"),
        ("tell me what you think", "Tell me what you think."),
        ("send it to Anna no sorry to Kate by Tuesday", "Send it to Kate by Tuesday."),
        ("I'll call Tom um actually no I'll email Priya", "I'll email Priya."),
        ("we need to bring tents sleeping bags torches and the gas cooker", "We need to bring:\n- tents\n- sleeping bags\n- torches\n- the gas cooker"),
        ("cheers mate new line talk soon", "Cheers mate\nTalk soon"),
        ("give me some ideas for dinner tonight", "Give me some ideas for dinner tonight."),
        ("hi Sam new paragraph thanks for sending that through", "Hi Sam,\n\nThanks for sending that through."),
        ("add a function called parse date to utils dot ts that returns null for bad input", "Add a function called parse date to utils.ts that returns null for bad input."),
        ("run npm install and then git push", "Run npm install and then git push."),
    ]

    static var instructions: String {
        rules + "\n\n" + examples.map { "Transcript: \($0.said)\nEdited: \($0.edited)" }.joined(separator: "\n\n")
    }

    /// The rules, then each example as a prompt and its reply.
    static var exampleTranscript: Transcript {
        func text(_ content: String) -> [Transcript.Segment] { [.text(.init(content: content))] }
        var entries: [Transcript.Entry] = [.instructions(.init(segments: text(rules), toolDefinitions: []))]
        for example in examples {
            entries.append(.prompt(.init(segments: text(prompt(example.said, context: CleanupContext())))))
            entries.append(.response(.init(assetIDs: [], segments: text(example.edited))))
        }
        return Transcript(entries: entries)
    }

    @Generable
    struct Edit {
        @Guide(description: "The transcript, edited. Only the user's own words.")
        var edited: String
    }

    /// A fresh session (no history), prewarmed while the user talks.
    private var ready: LanguageModelSession?

    private var model: SystemLanguageModel {
        // These guardrails are for rewriting the user's own text, so blunt or sweary messages aren't refused.
        SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
    }

    func prepare() async {
        guard ready == nil, case .available = model.availability else { return }
        let session = makeSession()
        session.prewarm()
        ready = session
    }

    func clean(_ raw: String, context: CleanupContext) async throws -> String {
        let model = model
        if case let .unavailable(reason) = model.availability {
            throw CleanupError.unavailable(String(describing: reason))
        }
        let session = ready ?? makeSession()
        ready = nil
        // A tidy version is never much longer, so a runaway answer stops early.
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: raw.count / 2 + 40)
        let prompt = Self.prompt(Self.unpunctuate(raw), context: context)
        return Self.tidyReply(try await session.respond(to: prompt, options: options).content)
    }

    private func makeSession() -> LanguageModelSession {
        LanguageModelSession(model: model, instructions: Self.instructions)
    }

    static func prompt(_ raw: String, context: CleanupContext) -> String {
        var prompt = ""
        if let app = context.appName { prompt += "App: \(app)\n" }
        return prompt + "Transcript: \(raw)\nEdited:"
    }

    /// Takes off anything a small model sometimes wraps its reply in.
    static func tidyReply(_ reply: String) -> String {
        var text = reply
        // Sometimes it repeats the prompt's layout: keep only what follows the last "Edited:".
        if let edited = text.range(of: "Edited:", options: .backwards) {
            text = String(text[edited.upperBound...])
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).filter {
            !$0.hasPrefix("App:") && !$0.hasPrefix("Transcript:")
        }
        text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2, let first = text.first, let last = text.last,
           (first == "\"" && last == "\"") || (first == "“" && last == "”") {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}

extension AppleCleaner {
    /// For Settings: why cleanup can't run, if it can't.
    nonisolated static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.appleIntelligenceNotEnabled): "Turn on Apple Intelligence to clean up your text."
        case .unavailable(.modelNotReady): "Apple Intelligence is still getting ready."
        case .unavailable(.deviceNotEligible): "This Mac can't run Apple Intelligence."
        case .unavailable: "Apple Intelligence isn't available."
        }
    }
}
