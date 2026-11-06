import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    let permissions: Permissions
    let shortcuts: ShortcutStore
    let customWords: CustomWords
    let controller: DictationController
    @State private var openAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @AppStorage(SystemSoundMuter.settingKey) private var muteWhileTalking = true
    @AppStorage(DockIcon.settingKey) private var showInDock = true

    var body: some View {
        Form {
            ForEach(TalkAction.allCases) { action in
                ShortcutSection(action: action, shortcuts: shortcuts, mouseAllowed: permissions.accessibility)
            }
            CustomWordsSection(customWords: customWords, lastHeard: controller.lastHeard)
            Section {
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, enabled in
                        do {
                            try LoginItem.set(enabled)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            openAtLogin = LoginItem.isEnabled
                        }
                    }
                if let loginError {
                    Text(loginError).font(.callout).foregroundStyle(.red)
                }
                Toggle(isOn: $showInDock) {
                    Text("Show in Dock")
                    Text("Click it to open these settings. Mumble keeps running in the menu bar either way.")
                }
                .onChange(of: showInDock) { DockIcon.apply() }
                CleanupStatus()
                Toggle(isOn: $muteWhileTalking) {
                    Text("Mute other sound while talking")
                    Text("Music, videos and calls go quiet until you finish.")
                }
            } header: {
                Text("General")
            }
            Section {
                PermissionsView(permissions: permissions)
            } header: {
                Text("Permissions")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear { shortcuts.stopRecording() }
    }
}

/// One action's shortcuts and mouse buttons, with buttons to add more.
private struct ShortcutSection: View {
    let action: TalkAction
    let shortcuts: ShortcutStore
    let mouseAllowed: Bool

    private var modifierKeys: [ModifierKey] {
        shortcuts.modifiers.filter { $0.value == action }.map(\.key)
    }

    var body: some View {
        Section {
            if action == .handsFree {
                HStack {
                    Image(systemName: "hand.tap").foregroundStyle(.secondary)
                    Text("Double tap a push-to-talk shortcut or button")
                }
            }
            ForEach(shortcuts.bindings(for: action)) { binding in
                BindingRow(binding: binding, shortcuts: shortcuts)
            }
            if shortcuts.recordingMouse == .new(action) {
                RecordingRow(shortcuts: shortcuts)
            }
            HStack {
                Button("Add Shortcut") { shortcuts.addKey(for: action) }
                Button("Add Mouse Button") { shortcuts.addMouse(for: action) }
                    .disabled(!mouseAllowed || shortcuts.recordingMouse != nil)
                    .help(mouseAllowed ? "" : "Allow Accessibility below to use a mouse button")
                Menu("Add Modifier Key") {
                    ForEach(ModifierKey.allCases) { key in
                        if key == .rightControl { Divider() }
                        Button(key.title) { shortcuts.addModifier(key, for: action) }
                            .disabled(shortcuts.modifiers[key] == action)
                    }
                }
                .fixedSize()
                .disabled(!mouseAllowed)
                .help(mouseAllowed ? "Use fn, ⌃, ⌥, ⌘ or ⇧ on its own" : "Allow Accessibility below to use a modifier key")
                Spacer()
            }
            if modifierKeys.contains(where: \.waitsForHold) {
                Text(action == .pushToTalk
                    ? "Hold it a moment to start, or double tap it for hands-free. Shortcuts and capitals still work as normal."
                    : "Tap it on its own to start and stop. Shortcuts and capitals still work as normal.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if modifierKeys.contains(.fn), !GlobeKey.doesNothing {
                GlobeKeyHint()
            }
        } header: {
            Text(action.title)
        } footer: {
            Text(action.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct BindingRow: View {
    let binding: ShortcutBinding
    let shortcuts: ShortcutStore

    var body: some View {
        if shortcuts.recordingMouse == .change(binding.id) {
            RecordingRow(shortcuts: shortcuts)
        } else {
            HStack {
                switch binding.kind {
                case .key:
                    Label("Keys", systemImage: "keyboard").labelStyle(.iconOnly).foregroundStyle(.secondary)
                    KeyboardShortcuts.Recorder(for: binding.name) { shortcut in
                        shortcuts.keyChanged(binding, to: shortcut)
                    }
                case .mouse:
                    Label("Mouse", systemImage: "computermouse").labelStyle(.iconOnly).foregroundStyle(.secondary)
                    Text(binding.mouseButton.map(ShortcutStore.name(ofMouseButton:)) ?? "Not set")
                    Button("Change…") { shortcuts.changeMouse(binding.id) }
                        .disabled(shortcuts.recordingMouse != nil)
                case .modifier:
                    let key = binding.modifierKey ?? .fn
                    Label(key.title, systemImage: key == .fn ? "globe" : "command")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                    Text(key.title)
                }
                Spacer()
                Button {
                    shortcuts.remove(binding)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove")
            }
        }
    }
}

/// Waiting for a mouse button press.
private struct RecordingRow: View {
    let shortcuts: ShortcutStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Mouse", systemImage: "computermouse").labelStyle(.iconOnly).foregroundStyle(.secondary)
                Text("Press the mouse button…").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { shortcuts.stopRecording() }
            }
            Text("Middle, back, forward and extra buttons work. If nothing happens, set that button back to its normal action (Middle click, Back or Forward) in Logi Options+.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Names and terms spelled the user's way, with what they're misheard as.
private struct CustomWordsSection: View {
    let customWords: CustomWords
    let lastHeard: String?
    @State private var newWord = ""

    var body: some View {
        Section {
            ForEach(customWords.words) { word in
                CustomWordRow(word: word, customWords: customWords)
            }
            HStack {
                TextField("Add a word or name", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let lastHeard {
                Text("Last heard: “\(lastHeard)”")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Custom words")
        } footer: {
            Text("Spelled your way, even when said in pieces (“bright CRM” becomes BrightCRM). If one comes out as something else, add that under “Also heard as”.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func add() {
        if customWords.add(newWord) { newWord = "" }
    }
}

private struct CustomWordRow: View {
    let word: CustomWord
    let customWords: CustomWords
    @State private var heardAs: String

    init(word: CustomWord, customWords: CustomWords) {
        self.word = word
        self.customWords = customWords
        _heardAs = State(initialValue: word.heardAs.joined(separator: ", "))
    }

    var body: some View {
        HStack {
            Text(word.word)
                .frame(minWidth: 110, alignment: .leading)
            TextField("Also heard as", text: $heardAs, prompt: Text("Also heard as (optional)"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .onChange(of: heardAs) { _, text in customWords.setHeardAs(text, for: word) }
            Button {
                customWords.remove(word)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove")
        }
    }
}

/// Cleanup uses Apple Intelligence; say so if it's off.
private struct CleanupStatus: View {
    @State private var reason = AppleCleaner.unavailableReason

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Clean up text")
                Text(reason.map { "\($0) Until then, text goes in as you said it." }
                    ?? "Removes fillers, applies corrections and tidies punctuation, on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if reason != nil {
                Button("Open Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            reason = AppleCleaner.unavailableReason
        }
    }
}

/// macOS acts on the 🌐 key by itself (emoji, input source or dictation) unless it's set to Do Nothing.
enum GlobeKey {
    /// System Settings › Keyboard › "Press 🌐 key to": 0 is Do Nothing. Unset means the macOS default.
    static var doesNothing: Bool {
        (CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? Int) == 0
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct GlobeKeyHint: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("macOS also uses fn. In Keyboard settings, set “Press 🌐 key to” to Do Nothing.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Open Keyboard Settings…") { GlobeKey.openSettings() }
        }
    }
}
