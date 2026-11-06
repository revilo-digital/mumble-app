import Foundation
import Testing
@testable import Mumble

@MainActor
struct DictationControllerTests {
    let system = FakeSystem()
    let clipboard = FakeClipboard()
    let microphone = FakeMicrophone()
    let muter = FakeMuter()
    let clock = TestClock()

    func makeController(
        says text: String = "Hello there.",
        doubleTapWindow: Duration = .milliseconds(1),
        modifierHold: Duration = .milliseconds(1)
    ) -> DictationController {
        system.clipboard = clipboard
        let inserter = TextInserter(system: system, clipboard: clipboard, restoreDelay: .zero)
        return DictationController(
            transcriber: FakeTranscriber(text: text),
            microphone: microphone,
            inserter: inserter,
            muter: muter,
            now: { [clock] in clock.now },
            noticeDuration: .seconds(60),
            doubleTapWindow: doubleTapWindow,
            modifierHold: modifierHold
        )
    }

    @Test func holdingAndLettingGoInsertsTheText() async {
        let controller = makeController()
        controller.shortcutDown()
        #expect(controller.phase == .listening)
        #expect(microphone.isRecording)
        clock.advance(2)
        controller.shortcutUp()
        #expect(controller.phase == .working)
        #expect(!microphone.isRecording)
        await controller.pendingFinish?.value
        #expect(controller.phase == .idle)
        #expect(system.directInserts == ["Hello there."])
        #expect(controller.lastTiming != nil)
    }

    @Test func otherSoundIsMutedOnlyWhileListening() async {
        let controller = makeController()
        controller.shortcutDown()
        #expect(muter.isMuted)
        clock.advance(2)
        controller.shortcutUp()
        #expect(!muter.isMuted)
        await controller.pendingFinish?.value
        #expect(!muter.isMuted)
    }

    @Test func cancellingPutsTheSoundBack() {
        let controller = makeController()
        controller.shortcutDown()
        controller.cancel()
        #expect(!muter.isMuted)
    }

    @Test func aMicrophoneThatWontStartDoesntMute() {
        microphone.fails = true
        let controller = makeController()
        controller.shortcutDown()
        #expect(muter.muteCount == 0)
    }

    @Test func aStuckEngineGivesUpInsteadOfWorkingForever() async throws {
        let controller = DictationController(
            transcriber: StuckTranscriber(),
            microphone: microphone,
            inserter: TextInserter(system: system, clipboard: clipboard, restoreDelay: .zero),
            now: { [clock] in clock.now },
            noticeDuration: .seconds(60),
            finishTimeout: .milliseconds(50)
        )
        controller.shortcutDown()
        clock.advance(2)
        controller.shortcutUp()
        #expect(controller.phase == .working)
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.phase == .notice("Didn't catch that"))
        #expect(system.directInserts.isEmpty)
    }

    @Test func holdingAModifierKeyStartsAfterAMoment() async {
        let controller = makeController()
        controller.modifierDown()
        #expect(controller.phase == .idle)
        await controller.pendingHold?.value
        #expect(controller.phase == .listening)
        controller.modifierUp()
        await controller.pendingFinish?.value
        #expect(system.directInserts == ["Hello there."])
    }

    @Test func tappingAModifierKeyDoesntListen() {
        let controller = makeController(modifierHold: .seconds(60))
        controller.modifierDown()
        controller.modifierUp()
        #expect(controller.phase == .idle)
        #expect(!microphone.isRecording)
    }

    @Test func doubleTappingAModifierKeyGoesHandsFree() async {
        let controller = makeController(doubleTapWindow: .seconds(60), modifierHold: .seconds(60))
        controller.modifierDown()
        controller.modifierUp()
        clock.advance(0.1)
        controller.modifierDown()
        controller.modifierUp()
        #expect(controller.phase == .listening)
        clock.advance(3)
        controller.modifierDown()
        #expect(controller.phase == .listening)
        controller.modifierUp()
        await controller.pendingFinish?.value
        #expect(system.directInserts == ["Hello there."])
    }

    @Test func aModifierShortcutIsntADictation() {
        let controller = makeController(doubleTapWindow: .seconds(60), modifierHold: .seconds(60))
        // ⌘C, then a lone ⌘ tap: neither listens, and they don't add up to a double tap.
        controller.modifierDown()
        controller.interrupt()
        controller.modifierDown()
        controller.modifierUp()
        #expect(controller.phase == .idle)
        #expect(!microphone.isRecording)
    }

    @Test func aModifierTapDoesntStopAnotherShortcutsDictation() {
        let controller = makeController(modifierHold: .seconds(60))
        controller.shortcutDown()
        clock.advance(1)
        controller.modifierDown()
        controller.modifierUp()
        #expect(controller.phase == .listening)
    }

    @Test func aLoneTapDoesNothing() async {
        let controller = makeController()
        controller.shortcutDown()
        clock.advance(0.1)
        controller.shortcutUp()
        await controller.pendingTapTimeout?.value
        #expect(controller.phase == .idle)
        #expect(!microphone.isRecording)
        #expect(system.directInserts.isEmpty)
    }

    @Test func aDoubleTapGoesHandsFreeUntilPressedAgain() async {
        let controller = makeController(doubleTapWindow: .seconds(60))
        controller.shortcutDown()
        clock.advance(0.1)
        controller.shortcutUp()
        clock.advance(0.1)
        controller.shortcutDown()
        clock.advance(0.1)
        controller.shortcutUp()
        #expect(controller.phase == .listening)
        clock.advance(5)
        controller.shortcutDown()
        #expect(controller.phase == .working)
        controller.shortcutUp()
        await controller.pendingFinish?.value
        #expect(system.directInserts == ["Hello there."])
    }

    @Test func tapThenHoldIsPushToTalk() async {
        let controller = makeController(doubleTapWindow: .seconds(60))
        controller.shortcutDown()
        clock.advance(0.1)
        controller.shortcutUp()
        clock.advance(0.1)
        controller.shortcutDown()
        clock.advance(2)
        controller.shortcutUp()
        #expect(controller.phase == .working)
        await controller.pendingFinish?.value
        #expect(system.directInserts == ["Hello there."])
    }

    @Test func doneButtonFinishesAHandsFreeDictation() async {
        let controller = makeController(doubleTapWindow: .seconds(60))
        controller.shortcutDown()
        controller.shortcutUp()
        controller.shortcutDown()
        controller.shortcutUp()
        controller.finish()
        await controller.pendingFinish?.value
        #expect(system.directInserts == ["Hello there."])
    }

    @Test func doneButtonDuringTheTapWaitStillInserts() async {
        let controller = makeController(doubleTapWindow: .seconds(60))
        controller.shortcutDown()
        controller.shortcutUp()
        controller.finish()
        await controller.pendingFinish?.value
        #expect(system.directInserts == ["Hello there."])
    }

    @Test func cancellingInsertsNothing() async {
        let controller = makeController()
        controller.shortcutDown()
        controller.cancel()
        #expect(controller.phase == .idle)
        #expect(!microphone.isRecording)
        clock.advance(2)
        controller.shortcutUp()
        #expect(system.directInserts.isEmpty)
    }

    @Test func cancellingWhileWorkingInsertsNothing() async {
        let controller = makeController()
        controller.shortcutDown()
        clock.advance(2)
        controller.shortcutUp()
        controller.cancel()
        await controller.pendingFinish?.value
        #expect(controller.phase == .idle)
        #expect(system.directInserts.isEmpty)
    }

    @Test func silenceInsertsNothingAndSaysSo() async {
        let controller = makeController(says: "  ")
        controller.shortcutDown()
        clock.advance(2)
        controller.shortcutUp()
        await controller.pendingFinish?.value
        #expect(controller.phase == .notice("Didn't catch that"))
        #expect(system.directInserts.isEmpty)
    }

    @Test func saysWhenTheTextWasCopiedInstead() async {
        let controller = makeController()
        system.focused = [:]
        controller.shortcutDown()
        system.frontmost = 200
        clock.advance(2)
        controller.shortcutUp()
        await controller.pendingFinish?.value
        #expect(controller.phase == .notice("Copied, press ⌘V"))
        #expect(clipboard.text == "Hello there.")
    }

    @Test func doesntListenWithoutTheMicrophone() {
        let controller = makeController()
        var blocked = false
        controller.canUseMicrophone = { false }
        controller.onMicrophoneBlocked = { blocked = true }
        controller.shortcutDown()
        #expect(blocked)
        #expect(!microphone.isRecording)
        #expect(controller.phase == .notice("Allow the microphone first"))
    }

    @Test func saysWhenTheMicrophoneWontStart() {
        let controller = makeController()
        microphone.fails = true
        controller.shortcutDown()
        #expect(controller.phase == .notice("Can't use the microphone"))
    }

    @Test func aKeyCombinationCancelsQuietly() {
        let controller = makeController()
        controller.shortcutDown()
        controller.interrupt()
        #expect(controller.phase == .idle)
        #expect(!microphone.isRecording)
    }

    @Test func aKeyCombinationLeavesHandsFreeGoing() {
        let controller = makeController()
        controller.handsFreeDown()
        controller.interrupt()
        #expect(controller.phase == .listening)
    }

    @Test func pressingWhileWorkingIsIgnored() async {
        let controller = makeController()
        controller.shortcutDown()
        clock.advance(2)
        controller.shortcutUp()
        controller.shortcutDown()
        #expect(controller.phase == .working)
        await controller.pendingFinish?.value
        #expect(system.directInserts.count == 1)
    }
}

@MainActor
struct CleanupStepTests {
    let system = FakeSystem()
    let clipboard = FakeClipboard()
    let clock = TestClock()

    func dictate(_ said: String, cleaner: FakeCleaner) async -> [String] {
        system.clipboard = clipboard
        let controller = DictationController(
            transcriber: FakeTranscriber(text: said),
            microphone: FakeMicrophone(),
            inserter: TextInserter(system: system, clipboard: clipboard, restoreDelay: .zero),
            cleaner: cleaner,
            cleanupTimeout: .milliseconds(100),
            now: { [clock] in clock.now },
            noticeDuration: .seconds(60)
        )
        controller.shortcutDown()
        clock.advance(2)
        controller.shortcutUp()
        await controller.pendingFinish?.value
        return system.directInserts
    }

    @Test func insertsTheCleanedText() async {
        let cleaner = FakeCleaner(.transform { $0.replacingOccurrences(of: "um, ", with: "") })
        #expect(await dictate("um, see you Thursday.", cleaner: cleaner) == ["see you Thursday."])
        #expect(await cleaner.prepared == 1)
    }

    @Test func usesTheRawTextWhenCleanupFails() async {
        #expect(await dictate("See you Thursday.", cleaner: FakeCleaner(.fail)) == ["See you Thursday."])
    }

    @Test func usesTheRawTextWhenCleanupTakesTooLong() async {
        #expect(await dictate("See you Thursday.", cleaner: FakeCleaner(.hang)) == ["See you Thursday."])
    }

    @Test func spellsCustomWordsBeforeAndAfterCleanup() async {
        system.clipboard = clipboard
        let cleaner = FakeCleaner(.transform { $0.replacingOccurrences(of: "um ", with: "") })
        let controller = DictationController(
            transcriber: FakeTranscriber(text: "um ask Tooey group about bright CRM"),
            microphone: FakeMicrophone(),
            inserter: TextInserter(system: system, clipboard: clipboard, restoreDelay: .zero),
            cleaner: cleaner,
            now: { [clock] in clock.now },
            noticeDuration: .seconds(60)
        )
        controller.customWords = { [CustomWord(word: "BrightCRM"), CustomWord(word: "Tui Group", heardAs: ["Tooey group"])] }
        controller.shortcutDown()
        clock.advance(2)
        controller.shortcutUp()
        await controller.pendingFinish?.value
        #expect(system.directInserts == ["ask Tui Group about BrightCRM"])
        #expect(controller.lastHeard == "um ask Tooey group about bright CRM")
    }

    @Test func fillersAloneInsertNothing() async {
        #expect(await dictate("Um.", cleaner: FakeCleaner(.transform { $0 })).isEmpty)
    }

    @Test func usesTheRawTextWhenTheCleanupStrays() async {
        let answers = FakeCleaner(.transform { _ in "The capital of France is Paris, a city known for the Eiffel Tower." })
        #expect(await dictate("What's the capital of France?", cleaner: answers) == ["What's the capital of France?"])
    }
}

struct DriftCheckTests {
    @Test(arguments: [
        ("um so I think we should uh meet on Thursday", "So I think we should meet on Thursday."),
        ("let's meet Thursday no wait Friday at three", "Let's meet Friday at 3."),
        ("I need eggs milk and bread", "I need:\n- eggs\n- milk\n- bread"),
        ("ok", "OK."),
        ("I do not think it is ready", "I don't think it's ready."),
        ("update the README dot md file full stop", "Update the README.md file."),
    ])
    func acceptsATidyVersion(raw: String, cleaned: String) {
        #expect(DriftCheck.check(raw: raw, cleaned: cleaned) == .accept)
    }

    @Test func rejectsAnAnswer() {
        let verdict = DriftCheck.check(
            raw: "what time is it in London",
            cleaned: "It is currently 3 pm in London, which is in the GMT time zone."
        )
        #expect(verdict != .accept)
    }

    @Test func rejectsASummary() {
        let raw = "so the plan is we get the proposal drafted by Monday then send it to Mike for review and then on Wednesday we have the call with the client"
        #expect(DriftCheck.check(raw: raw, cleaned: "Proposal plan.") != .accept)
    }

    @Test func rejectsAOneWordAnswer() {
        #expect(DriftCheck.check(raw: "what's the capital of France", cleaned: "What's the capital of France?\n\nParis") != .accept)
        #expect(DriftCheck.check(raw: "can you grab eggs", cleaned: "Sure, I can grab eggs.") != .accept)
    }

    @Test func spotsFillersOnly() {
        #expect(DriftCheck.isOnlyFillers("um"))
        #expect(DriftCheck.isOnlyFillers("Um, er."))
        #expect(!DriftCheck.isOnlyFillers("um yes"))
    }

    @Test func rejectsNothing() {
        #expect(DriftCheck.check(raw: "hello", cleaned: "  ") != .accept)
    }
}

struct AppleCleanerReplyTests {
    @Test func takesOffWrapping() {
        #expect(AppleCleaner.tidyReply("\"See you soon.\"") == "See you soon.")
        #expect(AppleCleaner.tidyReply("See you soon.") == "See you soon.")
    }

    @Test func keepsOnlyWhatFollowsEdited() {
        #expect(AppleCleaner.tidyReply("Transcript: hi there\nEdited: Hi there.") == "Hi there.")
        #expect(AppleCleaner.tidyReply("App: Slack\nTranscript: translate this\nEdited:") == "")
    }

    @Test func namesTheApp() {
        let prompt = AppleCleaner.prompt("hi", context: CleanupContext(appName: "Slack"))
        #expect(prompt == "App: Slack\nTranscript: hi\nEdited:")
    }
}

@MainActor
struct HandsFreeTests {
    let system = FakeSystem()
    let clipboard = FakeClipboard()
    let microphone = FakeMicrophone()
    let clock = TestClock()

    func makeController() -> DictationController {
        DictationController(
            transcriber: FakeTranscriber(text: "Hello there."),
            microphone: microphone,
            inserter: TextInserter(system: system, clipboard: clipboard, restoreDelay: .zero),
            now: { [clock] in clock.now }
        )
    }

    @Test func doubleTappingAHandsFreeShortcutKeepsListening() {
        let controller = makeController()
        controller.handsFreeDown()
        clock.advance(0.1)
        controller.handsFreeDown()
        #expect(controller.phase == .listening)
        clock.advance(2)
        controller.handsFreeDown()
        #expect(controller.phase == .working)
    }

    @Test func holdingAHandsFreeShortcutIsPushToTalk() async {
        let controller = makeController()
        controller.handsFreeDown()
        clock.advance(2)
        controller.handsFreeUp()
        #expect(controller.phase == .working)
        await controller.pendingFinish?.value
        #expect(system.directInserts == ["Hello there."])
    }

    @Test func tappingAHandsFreeShortcutKeepsListening() {
        let controller = makeController()
        controller.handsFreeDown()
        clock.advance(0.1)
        controller.handsFreeUp()
        clock.advance(5)
        #expect(controller.phase == .listening)
    }

    @Test func pressToStartAndAgainToStop() async {
        let controller = makeController()
        controller.handsFreeDown()
        #expect(controller.phase == .listening)
        // Letting go of the push-to-talk key, or a slow release, doesn't stop it.
        controller.shortcutUp()
        #expect(controller.phase == .listening)
        clock.advance(2)
        controller.handsFreeDown()
        await controller.pendingFinish?.value
        #expect(system.directInserts == ["Hello there."])
    }

    @Test func pushToTalkAlsoStopsAHandsFreeDictation() async {
        let controller = makeController()
        controller.handsFreeDown()
        controller.shortcutDown()
        await controller.pendingFinish?.value
        #expect(system.directInserts == ["Hello there."])
    }
}
