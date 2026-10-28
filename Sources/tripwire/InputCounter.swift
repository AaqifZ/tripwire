import CoreGraphics
import Foundation
import TripwireCore

/// Counts keystrokes and scroll events through a listen-only event tap.
/// It reads the event type and, for keys, only whether the key is typing (D21).
/// Characters are never read or stored.
enum InputCounter {
    struct Batch {
        let events: [ActivityEvent]
        let dropped: Int
        let tapEnabled: Bool
    }

    /// One busy second can contain hundreds of trackpad events. Bound retained input so a
    /// stalled browser cannot grow memory without limit. Dropped events never earn a pass.
    private static let eventLimit = 4_096
    private static var events: [ActivityEvent] = []
    private static var dropped = 0
    private static let lock = NSLock()
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
                    if event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
                       !event.flags.contains(.maskSecondaryFn),
                       Keys.isTyping(keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                                     command: event.flags.contains(.maskCommand),
                                     control: event.flags.contains(.maskControl)) {
                        InputCounter.append(.init(
                            kind: .typing,
                            target: .init(
                                windowID: nil,
                                processID: InputCounter.processID(event.getIntegerValueField(.eventTargetUnixProcessID))
                            ),
                            timestamp: ProcessInfo.processInfo.systemUptime,
                            targetSource: .processOnly
                        ))
                    }
                case .scrollWheel:
                    let primary = event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
                    let fallback = event.getIntegerValueField(.mouseEventWindowUnderMousePointer)
                    let rawWindow = InputCounter.windowID(primary == 0 ? fallback : primary)
                    let location = event.location
                    InputCounter.append(.init(
                        kind: .scroll,
                        target: .init(
                            windowID: rawWindow,
                            processID: InputCounter.processID(event.getIntegerValueField(.eventTargetUnixProcessID))
                        ),
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        pointer: .init(x: location.x, y: location.y),
                        targetSource: rawWindow == nil ? .processOnly : .eventWindow
                    ))
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

    /// The target-aware events since the last accepted browser read.
    static func drainBatch() -> Batch {
        lock.lock()
        defer { lock.unlock() }
        let drained = events
        let droppedCount = dropped
        events.removeAll(keepingCapacity: true)
        dropped = 0
        return Batch(events: drained, dropped: droppedCount, tapEnabled: tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false)
    }

    private static func append(_ event: ActivityEvent) {
        lock.lock()
        defer { lock.unlock() }
        if events.count == eventLimit {
            // The sample will withhold all creation credit after overflow. Clear in O(1)
            // and retain the newest target only so the health report stays responsive.
            dropped += events.count
            events.removeAll(keepingCapacity: true)
        }
        events.append(event)
    }

    private static func windowID(_ raw: Int64) -> UInt32? {
        guard raw > 0, raw <= Int64(UInt32.max) else { return nil }
        return UInt32(raw)
    }

    private static func processID(_ raw: Int64) -> Int32? {
        guard raw > 0, raw <= Int64(Int32.max) else { return nil }
        return Int32(raw)
    }

}
