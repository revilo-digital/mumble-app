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
    /// Seconds to wait for another app to answer an Accessibility call (macOS waits 6 by default). An app that's
    /// busy or hung would otherwise freeze Mumble with it; if it doesn't answer, the text is pasted or copied.
    static let messagingTimeout: Float = 1

    init() {
        // On the system-wide element, it's the timeout for every element.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Self.messagingTimeout)
    }

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
        // Chromium browsers ignore that, and only expose web pages to screen readers, which set this. They build
        // the page's tree a moment later, so the first dictation after the browser opens may still miss it.
        if Self.isChromium(pid) {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value)
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            Log.insertion.notice("No focused text box (Accessibility error \(error.rawValue, privacy: .public))")
            return nil
        }
        return AXField(value as! AXUIElement)
    }

    static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    private static func isChromium(_ pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier.map(chromiumBrowsers.contains) ?? false
    }

    func windowTitle(in pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        let title = Self.string(window as! AXUIElement, kAXTitleAttribute)
        return title?.isEmpty == false ? title : nil
    }

    func textBeforeCursor(in field: any FocusedField, limit: Int) -> String? {
        guard let element = (field as? AXField)?.element else { return nil }
        guard let cursor = Self.selectedRange(element) else {
            // Only the kind of box, never its text: to see which apps don't share the cursor position.
            let role = Self.string(element, kAXRoleAttribute) ?? "none"
            let hasValue = Self.string(element, kAXValueAttribute) != nil
            Log.insertion.notice("No cursor position from a \(role, privacy: .public) (has value: \(hasValue, privacy: .public))")
            return nil
        }
        // Ask for just the text before the cursor, so a long document isn't copied over.
        let start = max(0, cursor.location - limit)
        var range = CFRange(location: start, length: cursor.location - start)
        guard range.length > 0, let wanted = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, wanted, &value) == .success,
           let text = value as? String {
            return text.isEmpty ? nil : text
        }
        guard let whole = Self.string(element, kAXValueAttribute) as NSString?, cursor.location <= whole.length else {
            Log.insertion.notice("No text before the cursor from a \(Self.string(element, kAXRoleAttribute) ?? "none", privacy: .public)")
            return nil
        }
        let text = whole.substring(with: NSRange(location: start, length: cursor.location - start))
        return text.isEmpty ? nil : text
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
