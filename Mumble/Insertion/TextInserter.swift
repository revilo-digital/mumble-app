import Foundation

/// The text box that was focused when the shortcut went down.
protocol FocusedField: AnyObject {
    var isSecure: Bool { get }
    func isSame(as other: any FocusedField) -> Bool
}

/// Where the dictation goes: the app in front and, if Accessibility can see it, its focused text box.
struct TextTarget {
    let pid: pid_t
    let field: (any FocusedField)?
}

enum InsertOutcome: Equatable {
    /// Put straight into the text box with Accessibility.
    case inserted
    /// Pasted with ⌘V, clipboard put back afterwards.
    case pasted
    /// Couldn't safely put it anywhere, so it's on the clipboard.
    case copied
}

/// What the inserter needs from macOS. The real one is `AccessibilitySystem`; tests use a fake.
@MainActor
protocol SystemUI: AnyObject {
    func frontmostPID() -> pid_t?
    func isRunning(_ pid: pid_t) -> Bool
    func focusedField(in pid: pid_t) -> (any FocusedField)?
    func isAlive(_ field: any FocusedField) -> Bool
    /// Inserts `text` at the cursor (replacing any selection) and checks it landed.
    func insertDirectly(_ text: String, into field: any FocusedField) async -> Bool
    func sendPaste()
}

@MainActor
protocol Clipboard: AnyObject {
    var changeCount: Int { get }
    func snapshot() -> ClipboardSnapshot
    func restore(_ snapshot: ClipboardSnapshot)
    /// `transient` marks it so clipboard managers don't keep it.
    func setText(_ text: String, transient: Bool)
}

/// Everything on the clipboard: each item's data by type.
struct ClipboardSnapshot: Equatable {
    var items: [[String: Data]]
}

@MainActor
final class TextInserter {
    private let system: any SystemUI
    private let clipboard: any Clipboard
    private let restoreDelay: Duration
    /// The clipboard restore after a paste, so tests can wait for it.
    private(set) var pendingRestore: Task<Void, Never>?

    init(system: any SystemUI, clipboard: any Clipboard, restoreDelay: Duration = .milliseconds(500)) {
        self.system = system
        self.clipboard = clipboard
        self.restoreDelay = restoreDelay
    }

    /// Called on shortcut down, so the text goes where the user started, even if they click elsewhere.
    func captureTarget() -> TextTarget? {
        guard let pid = system.frontmostPID() else { return nil }
        return TextTarget(pid: pid, field: system.focusedField(in: pid))
    }

    func insert(_ text: String, into target: TextTarget?) async -> InsertOutcome {
        guard let target, system.isRunning(target.pid), target.field?.isSecure != true else {
            return copy(text, reason: "no usable text box")
        }
        if let field = target.field, system.isAlive(field), await system.insertDirectly(text, into: field) {
            return .inserted
        }
        // ⌘V goes to whatever is focused now, so only paste if that's still the same box.
        guard isStillFocused(target) else {
            return copy(text, reason: "focus moved")
        }
        paste(text)
        return .pasted
    }

    private func isStillFocused(_ target: TextTarget) -> Bool {
        guard system.frontmostPID() == target.pid else { return false }
        guard let field = target.field else { return true }
        guard let current = system.focusedField(in: target.pid) else { return false }
        return current.isSame(as: field)
    }

    private func paste(_ text: String) {
        pendingRestore?.cancel()
        let saved = clipboard.snapshot()
        clipboard.setText(text, transient: true)
        let ours = clipboard.changeCount
        system.sendPaste()
        Log.insertion.notice("Pasted")
        // Apps read the clipboard a moment after ⌘V; put the old contents back once they have,
        // unless something else has been copied since.
        pendingRestore = Task { [clipboard, restoreDelay] in
            try? await Task.sleep(for: restoreDelay)
            guard !Task.isCancelled, clipboard.changeCount == ours else { return }
            clipboard.restore(saved)
        }
    }

    private func copy(_ text: String, reason: String) -> InsertOutcome {
        Log.insertion.notice("Copied instead of inserting: \(reason, privacy: .public)")
        clipboard.setText(text, transient: false)
        return .copied
    }
}

/// Whether to put a space before inserted text, based on the character before the cursor.
enum Spacing {
    static func prefix(after previous: Character?, inserting text: String) -> String {
        guard let previous, let first = text.first else { return "" }
        if previous.isWhitespace || previous.isNewline { return "" }
        if "([{\"'“‘/-–—@#".contains(previous) { return "" }
        if ".,!?;:)]}…%".contains(first) { return "" }
        return " "
    }
}
