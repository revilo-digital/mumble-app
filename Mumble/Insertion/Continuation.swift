import Foundation
import NaturalLanguage

/// Fits a dictation to the text before the cursor, so it reads as a continuation of what's there: mid-sentence it
/// starts in lower case ("I've just sent" + "An internal email" → "an internal email"), after a full stop or at
/// the start of a line it starts with a capital, and it gets the space a paste would otherwise miss.
enum Continuation {
    enum Position: Equatable {
        case sentenceStart
        case midSentence
        /// Nothing before the cursor, or something ambiguous (a colon, an opening quote): left as it is.
        case unknown
    }

    /// `keep` is words always spelled as they are (custom words). `isEverydayWord` says whether a lower-case word is
    /// in the dictionary: names fail it ("brendan", "monday"), so they keep their capital.
    static func fit(_ text: String, after before: String?, keep: Set<String> = [], isEverydayWord: (String) -> Bool) -> String {
        guard let before, !before.isEmpty, !text.isEmpty else { return text }
        var fitted = text
        switch position(after: before) {
        case .midSentence: fitted = lowercasingFirstWord(of: text, keep: keep, isEverydayWord: isEverydayWord)
        case .sentenceStart: fitted = capitalisingFirstLetter(of: text)
        case .unknown: break
        }
        return Spacing.prefix(after: before.last, inserting: fitted) + fitted
    }

    static func position(after before: String) -> Position {
        // Skip the spaces after the last word, including the no-break spaces Outlook and browsers leave.
        var rest = Substring(before)
        while let last = rest.last, last.isWhitespace, !last.isNewline { rest.removeLast() }
        // A closing quote or bracket counts as whatever it closes: `said "no."` ends a sentence.
        while let last = rest.last, "\"'”’)]}".contains(last) { rest.removeLast() }
        guard let last = rest.last else { return .unknown }
        if last.isNewline || ".!?…".contains(last) { return .sentenceStart }
        if last.isLetter || last.isNumber || ",;–—-&".contains(last) { return .midSentence }
        return .unknown
    }

    private static func lowercasingFirstWord(of text: String, keep: Set<String>, isEverydayWord: (String) -> Bool) -> String {
        let word = String(text.prefix { $0.isLetter || $0 == "'" || $0 == "’" })
        guard let first = word.first, first.isUppercase else { return text }
        // "I", "I'm", "I've"; acronyms and words with capitals inside (API, JavaScript); custom words.
        if word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") { return text }
        if word.dropFirst().contains(where: \.isUppercase) || keep.contains(word) { return text }
        if !isEverydayWord(word.lowercased()) || isName(word, in: text) { return text }
        return first.lowercased() + text.dropFirst()
    }

    /// Whether the tagger reads the first word as a person, place or organisation (Google, English).
    private static func isName(_ word: String, in text: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let (tag, _) = tagger.tag(at: text.startIndex, unit: .word, scheme: .nameType)
        return tag == .personalName || tag == .placeName || tag == .organizationName
    }

    private static func capitalisingFirstLetter(of text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        // "iPhone" and "eBay" start in lower case on purpose.
        let word = text.prefix { $0.isLetter }
        if word.dropFirst().contains(where: \.isUppercase) { return text }
        return first.uppercased() + text.dropFirst()
    }
}
