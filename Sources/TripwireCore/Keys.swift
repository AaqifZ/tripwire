/// Which keystrokes count as typing (D21).
///
/// Only the key's class is used: navigation or shortcut, or not. The character is never read.
public enum Keys {
    /// Space, tab, escape, arrows, page up/down, home, end. They move a feed; they do not write.
    static let navigation: Set<Int64> = [49, 48, 53, 123, 124, 125, 126, 116, 121, 115, 119]
    // Function, media, volume, and help keys do not create text.
    static let nonText: Set<Int64> = [64, 72, 73, 74, 79, 80, 90, 96, 97, 98, 99, 100, 101, 103, 105, 106, 107, 109, 111, 113, 114, 118, 120, 122]

    /// True when a key press is typing: not navigation, and not a cmd or ctrl shortcut.
    public static func isTyping(keyCode: Int64, command: Bool, control: Bool) -> Bool {
        !command && !control && !navigation.contains(keyCode) && !nonText.contains(keyCode)
    }
}
