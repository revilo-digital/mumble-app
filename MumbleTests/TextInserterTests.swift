import CoreGraphics
import Foundation
import Testing
@testable import Mumble

@MainActor
struct TextInserterTests {
    let system = FakeSystem()
    let clipboard = FakeClipboard()
    let inserter: TextInserter

    init() {
        system.clipboard = clipboard
        inserter = TextInserter(system: system, clipboard: clipboard, restoreDelay: .zero)
    }

    @Test func insertsStraightIntoTheTextBox() async {
        let target = inserter.captureTarget()
        let outcome = await inserter.insert("Hello there.", into: target)
        #expect(outcome == .inserted)
        #expect(system.directInserts == ["Hello there."])
        #expect(system.pastes == 0)
        #expect(clipboard.text == "old")
    }

    @Test func pastesWhenTheBoxIgnoresAccessibilityAndPutsTheClipboardBack() async {
        system.acceptsDirectInsert = false
        let target = inserter.captureTarget()
        let outcome = await inserter.insert("Hello there.", into: target)
        #expect(outcome == .pasted)
        #expect(system.pastedText == ["Hello there."])
        #expect(clipboard.lastWasTransient)
        await inserter.pendingRestore?.value
        #expect(clipboard.text == "old")
    }

    @Test func leavesTheClipboardAloneIfSomethingElseWasCopied() async {
        system.acceptsDirectInsert = false
        let outcome = await inserter.insert("Hello there.", into: inserter.captureTarget())
        #expect(outcome == .pasted)
        clipboard.userCopies("newer")
        await inserter.pendingRestore?.value
        #expect(clipboard.text == "newer")
    }

    @Test func pastesIntoAnAppWhoseTextBoxCantBeSeen() async {
        // Some apps don't expose their text box to Accessibility; ⌘V still works if they're in front.
        system.focused = [:]
        let outcome = await inserter.insert("Hi", into: inserter.captureTarget())
        #expect(outcome == .pasted)
    }

    @Test func copiesInsteadOfPastingIntoADifferentBox() async {
        system.acceptsDirectInsert = false
        let target = inserter.captureTarget()
        system.focused[100] = FakeField(2)
        let outcome = await inserter.insert("Hi", into: target)
        #expect(outcome == .copied)
        #expect(system.pastes == 0)
        #expect(clipboard.text == "Hi")
        #expect(!clipboard.lastWasTransient)
    }

    @Test func copiesInsteadOfPastingIntoADifferentApp() async {
        system.focused = [:]
        let target = inserter.captureTarget()
        system.frontmost = 200
        let outcome = await inserter.insert("Hi", into: target)
        #expect(outcome == .copied)
        #expect(system.pastes == 0)
    }

    @Test func stillInsertsIntoTheOriginalBoxAfterClickingElsewhere() async {
        let target = inserter.captureTarget()
        system.frontmost = 200
        let outcome = await inserter.insert("Hi", into: target)
        #expect(outcome == .inserted)
        #expect(system.directInserts == ["Hi"])
    }

    @Test func copiesWhenTheAppHasQuit() async {
        let target = inserter.captureTarget()
        system.running = []
        #expect(await inserter.insert("Hi", into: target) == .copied)
        #expect(system.directInserts.isEmpty)
    }

    @Test func copiesWhenTheBoxHasGone() async {
        let target = inserter.captureTarget()
        system.dead = [1]
        system.focused[100] = nil
        #expect(await inserter.insert("Hi", into: target) == .copied)
    }

    @Test func neverTypesIntoAPasswordField() async {
        system.focused[100] = FakeField(1, secure: true)
        #expect(await inserter.insert("Hi", into: inserter.captureTarget()) == .copied)
        #expect(system.directInserts.isEmpty)
        #expect(system.pastes == 0)
    }

    @Test func copiesWhenNothingWasInFront() async {
        system.frontmost = nil
        #expect(await inserter.insert("Hi", into: inserter.captureTarget()) == .copied)
    }
}

struct SpacingTests {
    @Test(arguments: [
        (nil, "Hello", ""),
        (" ", "Hello", ""),
        ("\n", "Hello", ""),
        ("d", "Hello", " "),
        (".", "Hello", " "),
        ("(", "Hello", ""),
        ("d", ", then", ""),
        ("d", ".", ""),
        ("d", " already spaced", ""),
    ] as [(Character?, String, String)])
    func spaceBeforeInsertedText(previous: Character?, text: String, expected: String) {
        #expect(Spacing.prefix(after: previous, inserting: text) == expected)
    }
}

struct InputTapStateTests {
    @Test func takesOnlyButtonsUsedForTalking() {
        let state = InputTapState()
        state.configure(buttons: [3: .pushToTalk, 4: .handsFree], modifiers: [:], recording: false)
        #expect(state.handleMouse(button: 3, isDown: true))
        #expect(state.handleMouse(button: 3, isDown: false))
        #expect(state.handleMouse(button: 4, isDown: true))
        #expect(!state.handleMouse(button: 2, isDown: true))
    }

    @Test func takesNothingWithoutButtons() {
        #expect(!InputTapState().handleMouse(button: 3, isDown: true))
    }

    @Test func takesAnyButtonWhileRecording() {
        let state = InputTapState()
        state.configure(buttons: [:], modifiers: [:], recording: true)
        #expect(state.handleMouse(button: 5, isDown: true))
        #expect(state.handleMouse(button: 5, isDown: false))
    }
}

@MainActor
struct ModifierKeyTests {
    /// Collects what the tap state sends to the main thread.
    final class Events {
        var log: [String] = []
    }

    /// Presses and lets go of modifier keys, with the flags macOS would send.
    final class Keyboard {
        let state: InputTapState
        private var flags: UInt64 = 0
        init(_ state: InputTapState) { self.state = state }

        private func bit(_ code: Int) -> UInt64 {
            ModifierKey.fn.keyCodes.contains(code) ? CGEventFlags.maskSecondaryFn.rawValue : InputTapState.sideBits[code]!
        }

        func press(_ code: Int) {
            flags |= bit(code)
            state.handleFlags(keyCode: code, flags: flags)
        }

        func release(_ code: Int) {
            flags &= ~bit(code)
            state.handleFlags(keyCode: code, flags: flags)
        }
    }

    static let fn = 63, leftCommand = 55, rightCommand = 54, leftShift = 56, leftControl = 59

    func makeKeyboard(_ events: Events, _ modifiers: [ModifierKey: TalkAction]) -> Keyboard {
        let state = InputTapState()
        state.configure(buttons: [:], modifiers: modifiers, recording: false)
        state.onPress = { action, down in events.log.append("\(action.rawValue) \(down ? "down" : "up")") }
        state.onModifier = { action, down in events.log.append("modifier \(action.rawValue) \(down ? "down" : "up")") }
        state.onInterrupt = { events.log.append("interrupt") }
        return Keyboard(state)
    }

    /// The tap state sends to the main queue; let it run.
    func drain() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    @Test func holdingFnPressesAndReleases() async {
        let events = Events()
        let keys = makeKeyboard(events, [.fn: .pushToTalk])
        keys.press(Self.fn)
        keys.release(Self.fn)
        await drain()
        #expect(events.log == ["pushToTalk down", "pushToTalk up"])
    }

    @Test func fnWithAnotherKeyIsACombination() async {
        let events = Events()
        let keys = makeKeyboard(events, [.fn: .pushToTalk])
        keys.press(Self.fn)
        keys.state.handleOtherInput()
        keys.state.handleOtherInput()
        keys.release(Self.fn)
        await drain()
        #expect(events.log == ["pushToTalk down", "interrupt"])
    }

    @Test func fnWithAnotherModifierIsACombination() async {
        let events = Events()
        let keys = makeKeyboard(events, [.fn: .pushToTalk])
        keys.press(Self.fn)
        keys.press(Self.leftControl)
        await drain()
        #expect(events.log == ["pushToTalk down", "interrupt"])
    }

    @Test func commandOnItsOwnWaitsForAHold() async {
        let events = Events()
        let keys = makeKeyboard(events, [.command: .pushToTalk])
        keys.press(Self.leftCommand)
        keys.release(Self.leftCommand)
        await drain()
        #expect(events.log == ["modifier pushToTalk down", "modifier pushToTalk up"])
    }

    @Test func commandCIsAShortcutNotADictation() async {
        let events = Events()
        let keys = makeKeyboard(events, [.command: .pushToTalk])
        keys.press(Self.leftCommand)
        keys.state.handleOtherInput()
        keys.release(Self.leftCommand)
        await drain()
        #expect(events.log == ["modifier pushToTalk down", "interrupt"])
    }

    @Test func rightCommandIgnoresTheLeftOne() async {
        let events = Events()
        let keys = makeKeyboard(events, [.rightCommand: .pushToTalk])
        keys.press(Self.leftCommand)
        keys.release(Self.leftCommand)
        keys.press(Self.rightCommand)
        keys.release(Self.rightCommand)
        await drain()
        #expect(events.log == ["modifier pushToTalk down", "modifier pushToTalk up"])
    }

    @Test func commandAfterAnotherModifierIsIgnored() async {
        let events = Events()
        let keys = makeKeyboard(events, [.command: .pushToTalk])
        keys.press(Self.leftShift)
        keys.press(Self.leftCommand)
        keys.release(Self.leftCommand)
        keys.release(Self.leftShift)
        await drain()
        #expect(events.log.isEmpty)
    }

    @Test func shiftForACapitalIsACombination() async {
        let events = Events()
        let keys = makeKeyboard(events, [.shift: .handsFree])
        keys.press(Self.leftShift)
        keys.state.handleOtherInput()
        keys.release(Self.leftShift)
        await drain()
        #expect(events.log == ["modifier handsFree down", "interrupt"])
    }

    @Test func typingWithoutAModifierIsIgnored() async {
        let events = Events()
        let keys = makeKeyboard(events, [.fn: .pushToTalk])
        keys.state.handleOtherInput()
        keys.press(Self.leftControl)
        keys.release(Self.leftControl)
        await drain()
        #expect(events.log.isEmpty)
    }

    @Test func nothingUnlessChosen() async {
        let events = Events()
        let keys = makeKeyboard(events, [:])
        keys.press(Self.fn)
        keys.release(Self.fn)
        keys.press(Self.leftCommand)
        keys.release(Self.leftCommand)
        await drain()
        #expect(events.log.isEmpty)
    }
}

@MainActor
struct ContinuationTests {
    @Test(arguments: [
        // Mid-sentence: carries on in lower case, with a space if there isn't one.
        ("I’ve just sent\u{a0}", "An internal email to all stakeholders.", "an internal email to all stakeholders."),
        ("I’ve just sent", "An internal email.", " an internal email."),
        ("If it works,", "Ship it.", " ship it."),
        // A new sentence or line starts with a capital.
        ("Thanks for that. ", "Can you check?", "Can you check?"),
        ("Thanks for that.", "Can you check?", " Can you check?"),
        ("thanks for that. ", "can you check?", "Can you check?"),
        ("Hi Tama,\n", "Thanks for the update.", "Thanks for the update."),
        ("He said “no.” ", "Then he left.", "Then he left."),
        ("Done. ", "iPhone works now.", "iPhone works now."),
        // Names, "I", acronyms and words with capitals inside keep theirs.
        ("Send it to ", "Rawiri tomorrow.", "Rawiri tomorrow."),
        ("Let's meet on ", "Monday at ten.", "Monday at ten."),
        ("Honestly ", "I think so.", "I think so."),
        ("Honestly ", "I'm not sure.", "I'm not sure."),
        ("We use ", "JavaScript here.", "JavaScript here."),
        ("Check the ", "API docs.", "API docs."),
        // Nothing before the cursor, or something ambiguous: left as it is.
        (nil, "Hello.", "Hello."),
        ("", "Hello.", "Hello."),
        ("Note: ", "The build failed.", "The build failed."),
    ] as [(String?, String, String)])
    func fitsTheTextBeforeTheCursor(before: String?, text: String, expected: String) {
        #expect(Continuation.fit(text, after: before, isEverydayWord: RecordingList.isEverydayWord) == expected)
    }

    @Test func customWordsKeepTheirCapital() {
        #expect(Continuation.fit("Mumble is better.", after: "Honestly ", isEverydayWord: RecordingList.isEverydayWord) == "mumble is better.")
        #expect(Continuation.fit("Mumble is better.", after: "Honestly ", keep: ["Mumble"], isEverydayWord: RecordingList.isEverydayWord) == "Mumble is better.")
    }
}
