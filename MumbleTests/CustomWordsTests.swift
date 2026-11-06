import Foundation
import Testing
@testable import Mumble

struct CustomSpellingTests {
    let words = [
        CustomWord(word: "BrightCRM"),
        CustomWord(word: "Tui Group", heardAs: ["Tooey group", "two e group"]),
        CustomWord(word: "OneDrive"),
    ]

    @Test(arguments: [
        ("We use bright CRM daily.", "We use BrightCRM daily."),
        ("We use Bright C R M daily.", "We use BrightCRM daily."),
        ("brightcrm is live", "BrightCRM is live"),
        ("Bright CRM's pricing", "BrightCRM's pricing"),
        ("Call tui group today.", "Call Tui Group today."),
        ("Call Tooey Group today.", "Call Tui Group today."),
        ("Call two e group today.", "Call Tui Group today."),
        ("log it in one drive please", "log it in OneDrive please"),
        ("Just bright. CRM comes later.", "Just bright. CRM comes later."),
        ("Nothing to change here.", "Nothing to change here."),
    ])
    func spellsCustomWords(heard: String, expected: String) {
        #expect(CustomSpelling.apply(words, to: heard) == expected)
    }

    @Test func noWordsChangesNothing() {
        #expect(CustomSpelling.apply([], to: "bright CRM") == "bright CRM")
    }
}

@MainActor
struct CustomWordsStoreTests {
    let defaults: UserDefaults

    init() {
        let suite = "CustomWordsStoreTests-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func addsSavesAndRemoves() {
        let store = CustomWords(defaults: defaults)
        #expect(store.add("  BrightCRM "))
        #expect(!store.add("brightcrm"))
        #expect(!store.add(" "))
        store.setHeardAs("bright C R M,  bright ", for: store.words[0])
        let reloaded = CustomWords(defaults: defaults)
        #expect(reloaded.words == [CustomWord(word: "BrightCRM", heardAs: ["bright C R M", "bright"])])
        reloaded.remove(reloaded.words[0])
        #expect(CustomWords(defaults: defaults).words.isEmpty)
    }
}
