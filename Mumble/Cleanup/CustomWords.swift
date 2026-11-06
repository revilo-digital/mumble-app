import Foundation
import Observation

/// A name or term spelled the user's way, and what the speech engine hears instead.
struct CustomWord: Codable, Equatable, Identifiable, Sendable {
    var word: String
    /// What it comes out as when it's misheard ("Tooey group" for "Tui Group").
    var heardAs: [String] = []

    var id: String { word }
}

/// Names and terms the user wants spelled their way (product names, client names, people's names), saved in
/// UserDefaults. Apple's speech engine ignores hints and the cleanup model gets worse when told them, so
/// they're applied by `CustomSpelling` before and after the cleanup.
@MainActor
@Observable
final class CustomWords {
    private static let key = "customWords"
    @ObservationIgnored private let defaults: UserDefaults

    private(set) var words: [CustomWord]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        words = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([CustomWord].self, from: $0) } ?? []
    }

    /// Adds a word or phrase. Returns false if it's empty or already there.
    @discardableResult
    func add(_ word: String) -> Bool {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, !words.contains(where: { $0.word.caseInsensitiveCompare(word) == .orderedSame }) else {
            return false
        }
        words.append(CustomWord(word: word))
        save()
        return true
    }

    func remove(_ word: CustomWord) {
        words.removeAll { $0.word == word.word }
        save()
    }

    /// Sets what it's heard as, from comma-separated text.
    func setHeardAs(_ text: String, for word: CustomWord) {
        guard let index = words.firstIndex(where: { $0.word == word.word }) else { return }
        words[index].heardAs = text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(words) { defaults.set(data, forKey: Self.key) }
    }
}

enum CustomSpelling {
    /// Spells the custom words the user's way wherever the transcript has the same letters, split up or in
    /// another case ("bright CRM" and "Bright C R M" become "BrightCRM"), or what they're heard as.
    static func apply(_ words: [CustomWord], to text: String) -> String {
        let targets = words.flatMap { word in
            ([word.word] + word.heardAs).compactMap { spelling -> (key: String, word: String, pieces: Int)? in
                let key = letters(spelling)
                return key.isEmpty ? nil : (key, word.word, spelling.split(whereSeparator: \.isWhitespace).count)
            }
        }
        guard !targets.isEmpty else { return text }
        let longest = targets.map(\.pieces).max() ?? 1
        let tokens = Self.tokens(in: text)
        var result = ""
        var copiedUpTo = text.startIndex
        var index = 0
        while index < tokens.count {
            var matched = false
            // Spoken letters can split a word into many pieces ("R F P"), so look a little further.
            for length in stride(from: min(longest + 4, tokens.count - index), through: 1, by: -1) {
                let run = tokens[index..<(index + length)]
                guard joinsOnlyBySpaces(run, in: text) else { continue }
                let key = run.map { letters(String(text[$0])) }.joined()
                guard let target = targets.first(where: { $0.key == key }) else { continue }
                result += text[copiedUpTo..<run.first!.lowerBound] + target.word
                copiedUpTo = run.last!.upperBound
                index += length
                matched = true
                break
            }
            if !matched { index += 1 }
        }
        return result + text[copiedUpTo...]
    }

    private static func letters(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func tokens(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        for index in text.indices {
            let isWordCharacter = text[index].isLetter || text[index].isNumber
            if isWordCharacter, start == nil { start = index }
            if !isWordCharacter, let begun = start {
                ranges.append(begun..<index)
                start = nil
            }
        }
        if let start { ranges.append(start..<text.endIndex) }
        return ranges
    }

    /// Only join pieces with spaces or hyphens between them, never across a full stop or comma.
    private static func joinsOnlyBySpaces(_ run: ArraySlice<Range<String.Index>>, in text: String) -> Bool {
        zip(run, run.dropFirst()).allSatisfy { previous, next in
            text[previous.upperBound..<next.lowerBound].allSatisfy { $0 == " " || $0 == "-" }
        }
    }
}
