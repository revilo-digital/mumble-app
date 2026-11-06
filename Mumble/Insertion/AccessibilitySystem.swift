import AppKit
import ApplicationServices

/// An Accessibility element for a focused text box.
final class AXField: FocusedField {
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
    }

    var isSecure: Bool {
        AccessibilitySystem.string(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole
    }

    func isSame(as other: any FocusedField) -> Bool {
        guard let other = other as? AXField else { return false }
        return CFEqual(element, other.element)
    }
}

@MainActor
final class AccessibilitySystem: SystemUI {
    func frontmostPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    func isRunning(_ pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return !app.isTerminated
    }

    func focusedField(in pid: pid_t) -> (any FocusedField)? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        // Electron apps (Slack, Cursor) only expose their text boxes once asked to.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXField(value as! AXUIElement)
    }

    func isAlive(_ field: any FocusedField) -> Bool {
        guard let field = field as? AXField else { return false }
        var role: CFTypeRef?
        return AXUIElementCopyAttributeValue(field.element, kAXRoleAttribute as CFString, &role) == .success
    }

    func insertDirectly(_ text: String, into field: any FocusedField) async -> Bool {
        guard let element = (field as? AXField)?.element else { return false }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue,
              // Without the current value there's no way to check it worked, and pasting as well could double it.
              let before = Self.string(element, kAXValueAttribute) else { return false }

        let insertion = Spacing.prefix(after: Self.character(before: Self.selectedRange(element), in: before), inserting: text) + text
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, insertion as CFString) == .success else {
            return false
        }
        // Some apps say yes and ignore it (common in browsers and Electron), and some update a moment later.
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(30)) }
            if let after = Self.string(element, kAXValueAttribute), after != before, after.contains(text) {
                Log.insertion.notice("Inserted with Accessibility")
                return true
            }
        }
        Log.insertion.notice("Accessibility insert didn't land")
        return false
    }

    func sendPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    nonisolated static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    /// The character just before the cursor. Accessibility ranges count UTF-16 units.
    private static func character(before range: CFRange?, in text: String) -> Character? {
        guard let range, range.location > 0 else { return nil }
        let string = text as NSString
        guard range.location <= string.length else { return nil }
        let composed = string.rangeOfComposedCharacterSequence(at: range.location - 1)
        return string.substring(with: composed).first
    }
}

@MainActor
final class SystemClipboard: Clipboard {
    private let pasteboard = NSPasteboard.general

    var changeCount: Int { pasteboard.changeCount }

    func snapshot() -> ClipboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            var data: [String: Data] = [:]
            for type in item.types {
                data[type.rawValue] = item.data(forType: type)
            }
            return data
        }
        return ClipboardSnapshot(items: items)
    }

    func restore(_ snapshot: ClipboardSnapshot) {
        pasteboard.clearContents()
        let items = snapshot.items.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    func setText(_ text: String, transient: Bool) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if transient {
            // See nspasteboard.org: clipboard managers skip these.
            item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        }
        pasteboard.writeObjects([item])
    }
}
