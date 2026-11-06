import Foundation
import KeyboardShortcuts
import Observation

/// What a shortcut does.
enum TalkAction: String, Codable, CaseIterable, Identifiable {
    /// Hold to talk, let go to insert. Double tap goes hands-free.
    case pushToTalk
    /// Press to start, press again to stop and insert (also a double tap of a push-to-talk binding).
    case handsFree

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pushToTalk: "Push to talk"
        case .handsFree: "Hands-free"
        }
    }

    var detail: String {
        switch self {
        case .pushToTalk: "Hold while you speak, then let go. Esc or ✕ cancels."
        case .handsFree: "Keeps listening until you press again or click ✓. Shortcuts added here start and stop with one press."
        }
    }
}

/// A modifier key used on its own, like fn or Right ⌘.
enum ModifierKey: String, Codable, CaseIterable, Identifiable {
    case fn, control, option, command, shift
    case rightControl, rightOption, rightCommand, rightShift

    var id: String { rawValue }

    /// The key codes that count: either side, or just the right-hand key.
    var keyCodes: Set<Int> {
        switch self {
        case .fn: [63, 179] // kVK_Function, and the 🌐 key on newer keyboards
        case .control: [59, 62]
        case .option: [58, 61]
        case .command: [55, 54]
        case .shift: [56, 60]
        case .rightControl: [62]
        case .rightOption: [61]
        case .rightCommand: [54]
        case .rightShift: [60]
        }
    }

    var title: String {
        switch self {
        case .fn: "fn"
        case .control: "⌃ Control"
        case .option: "⌥ Option"
        case .command: "⌘ Command"
        case .shift: "⇧ Shift"
        case .rightControl: "Right ⌃ Control"
        case .rightOption: "Right ⌥ Option"
        case .rightCommand: "Right ⌘ Command"
        case .rightShift: "Right ⇧ Shift"
        }
    }

    /// For "Hold Right ⌘ to talk".
    var shortName: String {
        switch self {
        case .fn: "fn"
        case .control: "⌃"
        case .option: "⌥"
        case .command: "⌘"
        case .shift: "⇧"
        case .rightControl: "Right ⌃"
        case .rightOption: "Right ⌥"
        case .rightCommand: "Right ⌘"
        case .rightShift: "Right ⇧"
        }
    }

    /// ⌃ ⌥ ⌘ ⇧ are pressed all the time for shortcuts and capitals, so they only start listening once
    /// held a moment with nothing else pressed. fn starts straight away.
    var waitsForHold: Bool { self != .fn }
}

/// One keyboard shortcut, mouse button or modifier key for an action.
struct ShortcutBinding: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case key
        case mouse
        /// A modifier key on its own (fn, ⌘ and so on).
        case modifier

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            // Saved as "fn" before the other modifier keys were added.
            self = raw == "fn" ? .modifier : Kind(rawValue: raw) ?? .key
        }
    }

    let id: String
    let action: TalkAction
    let kind: Kind
    /// macOS's button number, for mouse bindings: 2 middle, 3 back, 4 forward.
    var mouseButton: Int?
    var modifier: ModifierKey?

    /// The modifier key, for modifier bindings (older fn bindings have none saved).
    var modifierKey: ModifierKey? {
        kind == .modifier ? modifier ?? .fn : nil
    }

    /// Where KeyboardShortcuts keeps the keys, for key bindings. The first one keeps the original
    /// `talk` name, so its ⌃⌥M default (or the user's choice) carries over.
    var name: KeyboardShortcuts.Name {
        id == KeyboardShortcuts.Name.talk.rawValue ? .talk : KeyboardShortcuts.Name(id)
    }
}

/// All the shortcuts and mouse buttons, saved in UserDefaults. Key bindings are registered as global
/// hotkeys; mouse buttons and modifier keys are handed to the `InputListener`.
@MainActor
@Observable
final class ShortcutStore {
    enum MouseRecording: Equatable {
        case new(TalkAction)
        case change(String)
    }

    private(set) var bindings: [ShortcutBinding]
    /// Waiting for a mouse button press to record.
    private(set) var recordingMouse: MouseRecording?
    /// Bumped when a key changes, as KeyboardShortcuts keeps the keys itself.
    private(set) var revision = 0

    @ObservationIgnored var onPress: (TalkAction, Bool) -> Void = { _, _ in }
    /// Told whenever the mouse buttons, modifier keys or recording change.
    @ObservationIgnored var onInputChange: () -> Void = {}
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var registered: Set<String> = []
    private static let key = "shortcuts"
    private static let oldMouseKey = "mouseButton"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([ShortcutBinding].self, from: data) {
            bindings = saved
        } else {
            // First launch, or from the single Talk shortcut and mouse button.
            var initial = [ShortcutBinding(id: KeyboardShortcuts.Name.talk.rawValue, action: .pushToTalk, kind: .key)]
            if let button = defaults.object(forKey: Self.oldMouseKey) as? Int {
                initial.append(ShortcutBinding(id: Self.newID(), action: .pushToTalk, kind: .mouse, mouseButton: button))
            }
            bindings = initial
            save()
            defaults.removeObject(forKey: Self.oldMouseKey)
        }
    }

    func bindings(for action: TalkAction) -> [ShortcutBinding] {
        bindings.filter { $0.action == action }
    }

    /// Mouse button → action, for the listener.
    var mouseButtons: [Int: TalkAction] {
        var map: [Int: TalkAction] = [:]
        for binding in bindings where binding.kind == .mouse {
            if let button = binding.mouseButton { map[button] = binding.action }
        }
        return map
    }

    /// Modifier key → action, for the listener.
    var modifiers: [ModifierKey: TalkAction] {
        var map: [ModifierKey: TalkAction] = [:]
        for binding in bindings {
            if let key = binding.modifierKey { map[key] = binding.action }
        }
        return map
    }

    /// Uses a modifier key on its own for this action. A key does one thing, so it moves here from
    /// anywhere else, and ⌘ replaces Right ⌘ (and the other way round).
    func addModifier(_ key: ModifierKey, for action: TalkAction) {
        bindings.removeAll { $0.modifierKey.map { !$0.keyCodes.isDisjoint(with: key.keyCodes) } ?? false }
        bindings.append(ShortcutBinding(id: Self.newID(), action: action, kind: .modifier, modifier: key))
        save()
        onInputChange()
    }

    /// Registers every key binding as a global hotkey. Call once at launch.
    func registerKeys() {
        for binding in bindings where binding.kind == .key { register(binding) }
    }

    func addKey(for action: TalkAction) {
        let binding = ShortcutBinding(id: Self.newID(), action: action, kind: .key)
        bindings.append(binding)
        register(binding)
        save()
    }

    func addMouse(for action: TalkAction) {
        recordingMouse = .new(action)
        onInputChange()
    }

    func changeMouse(_ id: String) {
        recordingMouse = .change(id)
        onInputChange()
    }

    func stopRecording() {
        recordingMouse = nil
        onInputChange()
    }

    /// The mouse button pressed while recording.
    func recorded(button: Int) {
        guard let recording = recordingMouse else { return }
        recordingMouse = nil
        // A button does one thing, so take it off anything else first.
        bindings.removeAll { $0.kind == .mouse && $0.mouseButton == button && !isChanging($0, recording) }
        switch recording {
        case let .new(action):
            bindings.append(ShortcutBinding(id: Self.newID(), action: action, kind: .mouse, mouseButton: button))
        case let .change(id):
            if let index = bindings.firstIndex(where: { $0.id == id }) { bindings[index].mouseButton = button }
        }
        save()
        onInputChange()
    }

    func remove(_ binding: ShortcutBinding) {
        if binding.kind == .key {
            KeyboardShortcuts.removeHandler(for: binding.name)
            KeyboardShortcuts.setShortcut(nil, for: binding.name)
            registered.remove(binding.id)
        }
        bindings.removeAll { $0.id == binding.id }
        save()
        revision += 1
        onInputChange()
    }

    /// A key was recorded: the same keys can't do two things, so clear them anywhere else.
    func keyChanged(_ binding: ShortcutBinding, to shortcut: KeyboardShortcuts.Shortcut?) {
        if let shortcut {
            for other in bindings where other.kind == .key && other.id != binding.id {
                if KeyboardShortcuts.getShortcut(for: other.name) == shortcut {
                    KeyboardShortcuts.setShortcut(nil, for: other.name)
                }
            }
        }
        revision += 1
    }

    /// "⌃⌥M" or "the back button", for the first binding of an action that's set.
    func description(of action: TalkAction) -> String? {
        _ = revision
        for binding in bindings(for: action) {
            switch binding.kind {
            case .key:
                if let shortcut = KeyboardShortcuts.getShortcut(for: binding.name) { return shortcut.description }
            case .mouse:
                if let button = binding.mouseButton { return "the " + Self.name(ofMouseButton: button).lowercased() }
            case .modifier:
                if let key = binding.modifierKey { return key.shortName }
            }
        }
        return nil
    }

    nonisolated static func name(ofMouseButton button: Int) -> String {
        switch button {
        case 2: "Middle button"
        case 3: "Back button"
        case 4: "Forward button"
        default: "Mouse button \(button + 1)"
        }
    }

    private func isChanging(_ binding: ShortcutBinding, _ recording: MouseRecording) -> Bool {
        recording == .change(binding.id)
    }

    private func register(_ binding: ShortcutBinding) {
        guard !registered.contains(binding.id) else { return }
        registered.insert(binding.id)
        let action = binding.action
        KeyboardShortcuts.onKeyDown(for: binding.name) { [weak self] in
            MainActor.assumeIsolated { self?.onPress(action, true) }
        }
        KeyboardShortcuts.onKeyUp(for: binding.name) { [weak self] in
            MainActor.assumeIsolated { self?.onPress(action, false) }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(bindings) { defaults.set(data, forKey: Self.key) }
    }

    private static func newID() -> String {
        "shortcut-" + UUID().uuidString.prefix(8).lowercased()
    }
}
