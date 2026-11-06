import Foundation
import Testing
@testable import Mumble

/// Only mouse bindings here: key bindings live in KeyboardShortcuts' standard defaults, which the
/// test host shares with the real app.
@MainActor
struct ShortcutStoreTests {
    let defaults: UserDefaults

    init() {
        let suite = "mumble-tests-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func startsWithOnePushToTalkShortcut() {
        let store = ShortcutStore(defaults: defaults)
        #expect(store.bindings.map(\.kind) == [.key])
        #expect(store.bindings.first?.action == .pushToTalk)
        #expect(store.bindings.first?.name == .talk)
    }

    @Test func carriesOverTheOldMouseButton() {
        defaults.set(3, forKey: "mouseButton")
        let store = ShortcutStore(defaults: defaults)
        #expect(store.mouseButtons == [3: .pushToTalk])
    }

    @Test func recordsMouseButtonsForEachAction() {
        let store = ShortcutStore(defaults: defaults)
        store.addMouse(for: .pushToTalk)
        store.recorded(button: 3)
        store.addMouse(for: .handsFree)
        store.recorded(button: 4)
        store.addMouse(for: .pushToTalk)
        store.recorded(button: 2)
        #expect(store.mouseButtons == [3: .pushToTalk, 4: .handsFree, 2: .pushToTalk])
        #expect(store.recordingMouse == nil)
        #expect(store.bindings(for: .pushToTalk).count == 3)
    }

    @Test func aButtonMovesRatherThanDoingTwoThings() {
        let store = ShortcutStore(defaults: defaults)
        store.addMouse(for: .pushToTalk)
        store.recorded(button: 3)
        store.addMouse(for: .handsFree)
        store.recorded(button: 3)
        #expect(store.mouseButtons == [3: .handsFree])
        #expect(store.bindings.filter { $0.kind == .mouse }.count == 1)
    }

    @Test func changesAButton() throws {
        let store = ShortcutStore(defaults: defaults)
        store.addMouse(for: .pushToTalk)
        store.recorded(button: 3)
        let binding = try #require(store.bindings.first { $0.kind == .mouse })
        store.changeMouse(binding.id)
        store.recorded(button: 4)
        #expect(store.mouseButtons == [4: .pushToTalk])
    }

    @Test func cancellingRecordingAddsNothing() {
        let store = ShortcutStore(defaults: defaults)
        store.addMouse(for: .handsFree)
        store.stopRecording()
        store.recorded(button: 3)
        #expect(store.mouseButtons.isEmpty)
    }

    @Test func removesAButton() throws {
        let store = ShortcutStore(defaults: defaults)
        store.addMouse(for: .pushToTalk)
        store.recorded(button: 3)
        store.remove(try #require(store.bindings.first { $0.kind == .mouse }))
        #expect(store.mouseButtons.isEmpty)
    }

    @Test func remembersBindings() {
        let store = ShortcutStore(defaults: defaults)
        store.addMouse(for: .handsFree)
        store.recorded(button: 4)
        let reloaded = ShortcutStore(defaults: defaults)
        #expect(reloaded.bindings == store.bindings)
    }

    @Test func describesTheFirstMouseButton() {
        let store = ShortcutStore(defaults: defaults)
        store.addMouse(for: .handsFree)
        store.recorded(button: 3)
        #expect(store.description(of: .handsFree) == "the back button")
        #expect(ShortcutStore.name(ofMouseButton: 2) == "Middle button")
        #expect(ShortcutStore.name(ofMouseButton: 5) == "Mouse button 6")
    }

    @Test func aModifierKeyDoesOneThing() {
        let store = ShortcutStore(defaults: defaults)
        store.addModifier(.fn, for: .pushToTalk)
        #expect(store.modifiers == [.fn: .pushToTalk])
        store.addModifier(.fn, for: .handsFree)
        #expect(store.modifiers == [.fn: .handsFree])
    }

    @Test func eitherSideReplacesOneSide() {
        let store = ShortcutStore(defaults: defaults)
        store.addModifier(.rightCommand, for: .handsFree)
        store.addModifier(.option, for: .pushToTalk)
        #expect(store.description(of: .handsFree) == "Right ⌘")
        store.addModifier(.command, for: .handsFree)
        #expect(store.modifiers == [.option: .pushToTalk, .command: .handsFree])
    }

    @Test func readsFnSavedTheOldWay() throws {
        let old = #"[{"action":"handsFree","id":"shortcut-1","kind":"fn"}]"#
        defaults.set(Data(old.utf8), forKey: "shortcuts")
        let store = ShortcutStore(defaults: defaults)
        #expect(store.modifiers == [.fn: .handsFree])
    }
}
