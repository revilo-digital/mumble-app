import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// The first push-to-talk shortcut. Kept by name so earlier settings carry over.
    static let talk = Self("talk", initial: .init(.m, modifiers: [.control, .option]))
}
