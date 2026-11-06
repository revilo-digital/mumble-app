import AppKit
import Foundation

/// Where the text is going, so the cleanup can match it.
struct CleanupContext: Sendable, Equatable {
    var appName: String?
    var bundleID: String?

    init(appName: String? = nil, bundleID: String? = nil) {
        self.appName = appName
        self.bundleID = bundleID
    }

    /// The app the text box belongs to (or the app in front, if there's no text box).
    @MainActor
    init(pid: pid_t?) {
        let app = pid.flatMap { NSRunningApplication(processIdentifier: $0) } ?? NSWorkspace.shared.frontmostApplication
        self.init(appName: app?.localizedName, bundleID: app?.bundleIdentifier)
    }
}

/// Tidies the raw transcript: fillers, spoken corrections, lists and punctuation. Swappable, so another
/// model can be added later.
protocol Cleaner: Sendable {
    /// Gets the model loaded while the user talks, so the cleanup starts warm.
    func prepare() async
    func clean(_ raw: String, context: CleanupContext) async throws -> String
}

enum CleanupError: Error {
    case unavailable(String)
}

/// Decides whether the cleaned text can be trusted, or the raw text should go in instead.
enum DriftCheck {
    enum Verdict: Equatable {
        case accept
        case reject(String)
    }

    /// Sounds the cleanup is meant to remove, so they don't count as words it dropped.
    static let fillers: Set<String> = ["um", "uh", "er", "erm", "ah", "hmm", "mm"]

    static func check(raw: String, cleaned: String) -> Verdict {
        let rawWords = words(raw)
        let cleanedWords = words(cleaned)
        guard !cleanedWords.isEmpty else { return .reject("empty") }
        // Bullets and line breaks add a little; much more means it added its own words.
        if cleaned.count > raw.count + raw.count / 4 + 20 { return .reject("much longer") }
        // Words it brought in that were never said, like an answer ("Paris") or a reply ("Sure").
        // Small words, numbers ("three" becomes "3") and contractions of what was said are fine.
        let said = Set(rawWords)
        let added = cleanedWords.filter { !said.contains($0) && !isHarmless($0, said: said) }
        if added.count > rawWords.count / 30 { return .reject("new words: \(added.prefix(3).joined(separator: " "))") }
        // Corrections drop some words, but not half of them.
        let spoken = rawWords.filter { !fillers.contains($0) }
        if spoken.count >= 6, cleanedWords.count * 2 < spoken.count { return .reject("much shorter") }
        return .accept
    }

    /// Words a tidy-up may add or change without adding meaning.
    static let smallWords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "be", "to", "of", "and", "or", "in", "on", "at", "for", "it",
        "i", "ok", "okay", "that", "this", "with", "so", "but", "not",
    ]

    private static func isHarmless(_ word: String, said: Set<String>) -> Bool {
        if smallWords.contains(word) || word.allSatisfy(\.isNumber) { return true }
        // "don't" for "do not", "it's" for "it is".
        let contractions = ["n't": "", "'s": "", "'re": "", "'ll": "", "'ve": "", "'d": "", "'m": ""]
        for (ending, _) in contractions where word.hasSuffix(ending) {
            let stem = String(word.dropLast(ending.count))
            let full = ["ca": "can", "wo": "will", "sha": "shall"][stem] ?? stem
            if said.contains(full) || smallWords.contains(full) { return true }
        }
        return false
    }

    /// True when nothing but filler sounds was said ("um").
    static func isOnlyFillers(_ text: String) -> Bool {
        words(text).allSatisfy(fillers.contains)
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }
}
