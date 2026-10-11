import CoreGraphics
import TripwireCore

/// Counts keystrokes and scroll events through a listen-only event tap.
/// It reads the event type and, for keys, only whether the key is typing (D21).
/// Characters are never read or stored.
enum InputCounter {
    private(set) static var keys = 0
    private(set) static var scrolls = 0
    private static var tap: CFMachPort?

    /// Returns false if Input Monitoring access is missing.
    static func start() -> Bool {
        if !CGPreflightListenEventAccess() {
            CGRequestListenEventAccess()
            return false
        }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.scrollWheel.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, _ in
                switch type {
                case .keyDown:
                    // D21: only typing counts. Navigation keys and shortcuts move a feed.
                    if Keys.isTyping(keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                                     command: event.flags.contains(.maskCommand),
                                     control: event.flags.contains(.maskControl)) {
                        InputCounter.keys += 1
                    }
                case .scrollWheel: InputCounter.scrolls += 1
                case .tapDisabledByTimeout, .tapDisabledByUserInput:
                    if let tap = InputCounter.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                default: break
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else { return false }
        tap = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    /// The counts since the last call.
    static func drain() -> (keys: Int, scrolls: Int) {
        defer { keys = 0; scrolls = 0 }
        return (keys, scrolls)
    }
}
