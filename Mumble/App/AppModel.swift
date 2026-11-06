import AppKit
import Observation

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let permissions = Permissions()
    let shortcuts = ShortcutStore()
    let customWords = CustomWords()
    @ObservationIgnored private let input = InputListener()
    let controller: DictationController
    @ObservationIgnored private let muter = SystemSoundMuter()
    @ObservationIgnored private let transcriber = AppleTranscriber()
    @ObservationIgnored private var widget: WidgetController?
    @ObservationIgnored private let settingsWindow = AppWindow()
    @ObservationIgnored private let setupWindow = AppWindow()

    /// Unit tests are hosted in the app; keep them away from hotkeys and windows.
    static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private init() {
        controller = DictationController(
            transcriber: transcriber,
            microphone: Microphone(),
            inserter: TextInserter(system: AccessibilitySystem(), clipboard: SystemClipboard()),
            muter: muter,
            cleaner: AppleCleaner()
        )
    }

    func launch() {
        guard !Self.isTesting else { return }
        DockIcon.apply()
        // In case Mumble quit while it had the sound muted.
        muter.restore()
        controller.canUseMicrophone = { [permissions] in
            permissions.refresh()
            return permissions.microphone == .authorized
        }
        controller.onMicrophoneBlocked = { [weak self] in self?.showSetup() }
        controller.customWords = { [customWords] in customWords.words }
        let press: (TalkAction, Bool) -> Void = { [controller] action, down in
            switch (action, down) {
            case (.pushToTalk, true): controller.shortcutDown()
            case (.pushToTalk, false): controller.shortcutUp()
            case (.handsFree, true): controller.handsFreeDown()
            case (.handsFree, false): controller.handsFreeUp()
            }
        }
        shortcuts.onPress = press
        shortcuts.registerKeys()
        input.onPress = press
        input.onRecord = { [shortcuts] button in shortcuts.recorded(button: button) }
        input.onModifier = { [controller] action, down in
            switch (action, down) {
            case (.pushToTalk, true): controller.modifierDown()
            case (.pushToTalk, false): controller.modifierUp()
            case (.handsFree, true): break
            case (.handsFree, false): controller.handsFreeDown()
            }
        }
        input.onInterrupt = { [controller] in controller.interrupt() }
        shortcuts.onInputChange = { [shortcuts, input] in
            input.update(buttons: shortcuts.mouseButtons, modifiers: shortcuts.modifiers, recording: shortcuts.recordingMouse != nil)
        }
        shortcuts.onInputChange()
        input.start()
        widget = WidgetController(controller: controller)
        LoginItem.setUpOnFirstLaunch()
        Task { [transcriber] in
            do {
                try await transcriber.prepare()
            } catch {
                Log.speech.error("Speech model not ready: \(error.localizedDescription, privacy: .public)")
            }
        }
        if !permissions.allGranted { showSetup() }
    }

    /// "Hold ⌃⌥M to talk", for the menu and setup text.
    var triggerHint: String {
        if let push = shortcuts.description(of: .pushToTalk) { return "Hold \(push) to talk" }
        if let handsFree = shortcuts.description(of: .handsFree) { return "Press \(handsFree) to talk" }
        return "Set a shortcut in Settings"
    }

    func showSetup() {
        setupWindow.show(title: "Set Up Mumble") {
            SetupView(app: self) { [setupWindow] in setupWindow.close() }
        }
    }

    func showSettings() {
        settingsWindow.show(title: "Mumble Settings") {
            SettingsView(permissions: permissions, shortcuts: shortcuts, customWords: customWords, controller: controller)
        }
    }
}
