import AppKit
import CoreGraphics

/// Watches mouse buttons and modifier keys on their own (fn, ⌃ ⌥ ⌘ ⇧) with an event tap (which needs
/// Accessibility).
///
/// - Mouse buttons used for talking have their clicks taken, so Back doesn't also go back a page.
/// - Modifier keys are only watched, never taken, so shortcuts (⌘C, fn+Delete) keep working. A key,
///   another modifier or a click while one is held makes it a combination, which cancels it.
///
/// The tap runs on its own thread, so typing is never held up by the main thread.
@MainActor
final class InputListener {
    private let state = InputTapState()
    private var tap: CFMachPort?
    private var retry: Timer?

    var onPress: (TalkAction, Bool) -> Void = { _, _ in }
    var onRecord: (Int) -> Void = { _ in }
    /// ⌃ ⌥ ⌘ ⇧ on their own: down, or let go cleanly.
    var onModifier: (TalkAction, Bool) -> Void = { _, _ in }
    /// The modifier key turned out to be part of a key combination.
    var onInterrupt: () -> Void = {}

    func update(buttons: [Int: TalkAction], modifiers: [ModifierKey: TalkAction], recording: Bool) {
        state.configure(buttons: buttons, modifiers: modifiers, recording: recording)
    }

    func start() {
        guard tap == nil else { return }
        state.onPress = { [weak self] action, down in self?.onPress(action, down) }
        state.onRecord = { [weak self] button in self?.onRecord(button) }
        state.onModifier = { [weak self] action, down in self?.onModifier(action, down) }
        state.onInterrupt = { [weak self] in self?.onInterrupt() }
        if installTap() { return }
        // Accessibility isn't allowed yet; try again until it is.
        retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.installTap() else { return }
                self.retry?.invalidate()
                self.retry = nil
            }
        }
    }

    private func installTap() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let types: [CGEventType] = [.otherMouseDown, .otherMouseUp, .flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: inputTapCallback,
            userInfo: Unmanaged.passUnretained(state).toOpaque()
        ) else { return false }
        state.tap = tap
        self.tap = tap
        let port = UncheckedPort(tap)
        let thread = Thread {
            let source = CFMachPortCreateRunLoopSource(nil, port.value, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port.value, enable: true)
            CFRunLoopRun()
        }
        thread.name = "Mumble input"
        thread.qualityOfService = .userInteractive
        thread.start()
        Log.dictation.notice("Listening for mouse buttons and modifier keys")
        return true
    }
}

private struct UncheckedPort: @unchecked Sendable {
    let value: CFMachPort
    init(_ value: CFMachPort) { self.value = value }
}

/// Shared between the main thread (settings) and the tap's thread (events), behind a lock.
/// Callbacks are always sent to the main thread.
final class InputTapState: @unchecked Sendable {
    /// The device-dependent flag bit for each side of ⌃ ⌥ ⌘ ⇧ (from IOLLEvent.h), so left and right
    /// can be told apart. fn uses `.maskSecondaryFn`.
    static let sideBits: [Int: UInt64] = [
        59: 0x0001, 62: 0x2000, // control
        56: 0x0002, 60: 0x0004, // shift
        55: 0x0008, 54: 0x0010, // command
        58: 0x0020, 61: 0x0040, // option
    ]

    private struct Active {
        let key: ModifierKey
        let action: TalkAction
        var interrupted = false
    }

    private let lock = NSLock()
    private var buttons: [Int: TalkAction] = [:]
    private var modifiers: [ModifierKey: TalkAction] = [:]
    private var isRecording = false
    // Only touched on the tap's thread.
    private var held: Set<Int> = []
    private var active: Active?

    var tap: CFMachPort?
    var onPress: @MainActor (TalkAction, Bool) -> Void = { _, _ in }
    /// ⌃ ⌥ ⌘ ⇧ down, or let go without anything else pressed.
    var onModifier: @MainActor (TalkAction, Bool) -> Void = { _, _ in }
    var onRecord: @MainActor (Int) -> Void = { _ in }
    var onInterrupt: @MainActor () -> Void = {}

    func configure(buttons: [Int: TalkAction], modifiers: [ModifierKey: TalkAction], recording: Bool) {
        lock.withLock {
            self.buttons = buttons
            self.modifiers = modifiers
            isRecording = recording
        }
    }

    /// Returns true to take the click, so the app underneath doesn't see it.
    func handleMouse(button: Int, isDown: Bool) -> Bool {
        let (recording, action) = lock.withLock { (isRecording, buttons[button]) }
        if recording {
            if isDown { send { $0.onRecord(button) } }
            return true
        }
        guard let action else {
            if isDown { handleOtherInput() }
            return false
        }
        send { $0.onPress(action, isDown) }
        return true
    }

    /// A modifier went down or up. Never taken.
    func handleFlags(keyCode: Int, flags: UInt64) {
        let isFn = ModifierKey.fn.keyCodes.contains(keyCode)
        guard isFn || Self.sideBits[keyCode] != nil else {
            // Caps Lock and the like.
            handleOtherInput()
            return
        }
        // Worked out from the flags each time, so a missed key-up (say, while a password field hides
        // keys from event taps) can't leave a key stuck down.
        held = Set(Self.sideBits.compactMap { flags & $0.value != 0 ? $0.key : nil })
        if flags & CGEventFlags.maskSecondaryFn.rawValue != 0 { held.insert(isFn ? keyCode : 63) }
        let isDown = held.contains(keyCode)

        if let current = active {
            if current.key.keyCodes.contains(keyCode) {
                guard !isDown, held.isDisjoint(with: current.key.keyCodes) else { return }
                active = nil
                if !current.interrupted { sendKey(current, isDown: false) }
            } else if isDown {
                // Another modifier with it: a shortcut like ⌘⇧4.
                interrupt()
            }
            return
        }
        guard isDown else { return }
        let map = lock.withLock { modifiers }
        guard let (key, action) = map.first(where: { $0.key.keyCodes.contains(keyCode) }),
              held.subtracting(key.keyCodes).isEmpty else { return }
        let started = Active(key: key, action: action)
        active = started
        sendKey(started, isDown: true)
    }

    /// Any key or click while a modifier is held makes it a combination, not a dictation.
    func handleOtherInput() {
        if active != nil { interrupt() }
    }

    private func sendKey(_ key: Active, isDown: Bool) {
        let action = key.action
        if key.key.waitsForHold {
            send { $0.onModifier(action, isDown) }
        } else {
            send { $0.onPress(action, isDown) }
        }
    }

    private func interrupt() {
        guard active?.interrupted == false else { return }
        active?.interrupted = true
        send { $0.onInterrupt() }
    }

    private func send(_ work: @escaping @MainActor (InputTapState) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { work(self) }
        }
    }
}

private func inputTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let state = Unmanaged<InputTapState>.fromOpaque(userInfo).takeUnretainedValue()
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let tap = state.tap { CGEvent.tapEnable(tap: tap, enable: true) }
    case .otherMouseDown, .otherMouseUp:
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        if state.handleMouse(button: button, isDown: type == .otherMouseDown) { return nil }
    case .flagsChanged:
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        state.handleFlags(keyCode: keyCode, flags: event.flags.rawValue)
    case .keyDown, .leftMouseDown, .rightMouseDown:
        state.handleOtherInput()
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}
