import Foundation
import Testing
@testable import Mumble

struct SpeechContextTests {
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test(arguments: [
        ("Quarterly plan - Claude - High memory usage - 937 MB - Google Chrome – Sam (Work)", "Google Chrome",
         "Quarterly plan - Claude"),
        ("Fix the to-do list — Cursor", "Cursor", "Fix the to-do list"),
        ("Eva Barrett", "Messages", "Eva Barrett"),
        ("Google Chrome", "Google Chrome", nil),
    ])
    func cleansWindowTitles(title: String, app: String, expected: String?) {
        #expect(SpeechContext.cleanTitle(title, app: app) == expected)
    }

    @Test func recentDictationsInTheSameAppCountForLonger() {
        let context = DictationContext(app: "Cursor", bundleID: "cursor", windowTitle: "auth.ts — Cursor", textBefore: "// TODO")
        let earlier: [SpeechContext.Earlier] = [
            .init(text: "Old Cursor talk.", bundleID: "cursor", date: now.addingTimeInterval(-20 * 60)),
            .init(text: "The Shopify auth flow is broken.", bundleID: "cursor", date: now.addingTimeInterval(-10 * 60)),
            .init(text: "Mail from a while ago.", bundleID: "mail", date: now.addingTimeInterval(-5 * 60)),
            .init(text: "Just said in Slack.", bundleID: "slack", date: now.addingTimeInterval(-60)),
        ]
        let prompt = SpeechContext.prompt(words: ["Shopify", "Kōwhai"], context: context, earlier: earlier, now: now)
        #expect(prompt == "Shopify, Kōwhai. auth.ts. The Shopify auth flow is broken. Just said in Slack. // TODO")
    }

    @Test func noContextIsEmpty() {
        #expect(SpeechContext.prompt(words: [], context: DictationContext(), earlier: [], now: now).isEmpty)
    }
}

@MainActor
struct DictationContextTests {
    @Test func theLastDictationIsContextForTheNext() async {
        let system = FakeSystem()
        let clipboard = FakeClipboard()
        let log = PromptLog()
        system.clipboard = clipboard
        let controller = DictationController(
            transcriber: FakeTranscriber(text: "I'm logged into the store.", prompts: log),
            microphone: FakeMicrophone(),
            inserter: TextInserter(system: system, clipboard: clipboard, restoreDelay: .zero),
            noticeDuration: .seconds(60)
        )
        for _ in 0..<2 {
            controller.handsFreeDown()
            try? await Task.sleep(for: .milliseconds(600))
            controller.handsFreeDown()
            await controller.pendingFinish?.value
        }
        #expect(log.all.count == 2)
        #expect(log.all.first == "")
        #expect(log.all.last == "I'm logged into the store.")
    }
}
