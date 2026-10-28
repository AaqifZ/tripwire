import AppKit
import ScriptingBridge
import TripwireCore

/// Reads a browser tab from one proven process and window.
/// All calls run on ActivityMonitor's serial utility queue.
enum ActiveTab {
    struct ApplicationContext: Sendable {
        let processID: pid_t
        let bundleIdentifier: String?
        let name: String?
    }

    struct Result {
        let read: Detection.Read
        let target: ActivityTarget?
        let browser: String?

        var resolution: ActivityResolution {
            switch read {
            case let .url(url):
                guard let site = Sites.match(url: url) else { return .unwatchedBrowser }
                return .watched(site: site, composing: Sites.isComposer(url: url))
            case .notBrowser, .noWindow:
                return .nonBrowser
            case .failed:
                return .failed(browser: browser)
            }
        }
    }

    private struct ScriptWindow {
        let object: SBObject
        let bounds: ActivityBounds
    }

    private final class Connection {
        let app: SBApplication
        let errors = ErrorFlag()

        init?(processID: pid_t) {
            guard let app = SBApplication(processIdentifier: processID) else { return nil }
            self.app = app
            app.delegate = errors
            // ScriptingBridge uses 1/60 s ticks. One second is the hard upper bound.
            app.timeout = 60
        }
    }

    private static let tabKey: [String: String] = [
        "com.brave.Browser": "activeTab",
        "com.google.Chrome": "activeTab",
        "company.thebrowser.Browser": "activeTab",
        "com.apple.Safari": "currentTab",
    ]

    private static var connections: [pid_t: Connection] = [:]
    private static let windowLimit = 64

    static func frontContext() -> ApplicationContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return .init(processID: app.processIdentifier, bundleIdentifier: app.bundleIdentifier,
                     name: displayName(app.localizedName))
    }

    static func context(processID: pid_t) -> ApplicationContext? {
        guard let app = NSRunningApplication(processIdentifier: processID) else { return nil }
        return .init(processID: processID, bundleIdentifier: app.bundleIdentifier,
                     name: displayName(app.localizedName))
    }

    static func isSupported(_ context: ApplicationContext?) -> Bool {
        guard let id = context?.bundleIdentifier else { return false }
        return tabKey[id] != nil
    }

    /// Reads the front script window and proves its WindowServer identity when possible.
    static func readFront(_ context: ApplicationContext?, inventory: [ActivityWindow], deadline: Double) -> Result {
        guard let context, let id = context.bundleIdentifier, let key = tabKey[id] else {
            return Result(read: .notBrowser, target: nil, browser: nil)
        }
        guard let connection = connection(processID: context.processID),
              let windows = scriptWindows(connection, deadline: deadline) else {
            return Result(read: .failed, target: nil, browser: context.name)
        }
        guard let first = windows.first else {
            return Result(read: .noWindow, target: nil, browser: context.name)
        }
        guard let target = uniqueTarget(for: first.bounds, processID: context.processID, inventory: inventory) else {
            return Result(read: .failed, target: nil, browser: context.name)
        }
        return read(first.object, key: key, connection: connection, target: target,
                    browser: context.name, deadline: deadline)
    }

    /// Reads the exact browser window beneath one input event. It never falls back to a first window.
    static func readWindow(_ target: ActivityTarget, inventory: [ActivityWindow], deadline: Double) -> Result {
        let fallbackContext = target.processID.flatMap(context)
        guard let windowID = target.windowID,
              let window = inventory.first(where: { $0.target.windowID == windowID }) else {
            if target.windowID != nil || target.processID == nil || isSupported(fallbackContext) {
                return Result(read: .failed, target: target, browser: fallbackContext?.name)
            }
            return Result(read: .notBrowser, target: target, browser: nil)
        }
        guard let processID = window.target.processID,
              let context = context(processID: processID) else {
            return Result(read: .failed, target: target, browser: fallbackContext?.name)
        }
        guard let id = context.bundleIdentifier, let key = tabKey[id] else {
            return Result(read: .notBrowser, target: target, browser: nil)
        }
        guard let connection = connection(processID: processID),
              let windows = scriptWindows(connection, deadline: deadline),
              let index = ActivityWindowMatcher.uniqueMatch(bounds: window.bounds, candidates: windows.map(\.bounds)) else {
            return Result(read: .failed, target: target, browser: context.name)
        }
        return read(windows[index].object, key: key, connection: connection,
                    target: window.target, browser: context.name, deadline: deadline)
    }

    private static func connection(processID: pid_t) -> Connection? {
        if let existing = connections[processID] { return existing }
        connections = connections.filter { NSRunningApplication(processIdentifier: $0.key) != nil }
        guard let created = Connection(processID: processID) else { return nil }
        connections[processID] = created
        return created
    }

    private static func scriptWindows(_ connection: Connection, deadline: Double) -> [ScriptWindow]? {
        guard prepare(connection, deadline: deadline) else { return nil }
        connection.errors.failed = false
        guard let elements = connection.app.value(forKey: "windows") as? SBElementArray,
              !connection.errors.failed, prepare(connection, deadline: deadline) else { return nil }
        let count = elements.count
        guard !connection.errors.failed, within(deadline), count <= windowLimit else { return nil }
        var result: [ScriptWindow] = []
        for index in 0..<count {
            guard prepare(connection, deadline: deadline) else { return nil }
            guard let object = elements.object(at: index) as? SBObject else { continue }
            guard prepare(connection, deadline: deadline) else { return nil }
            guard let bounds = bounds(object.value(forKey: "bounds")) else {
                if connection.errors.failed || !within(deadline) { return nil }
                continue
            }
            result.append(ScriptWindow(object: object, bounds: bounds))
        }
        return connection.errors.failed ? nil : result
    }

    private static func read(_ window: SBObject, key: String, connection: Connection,
                             target: ActivityTarget?, browser: String?, deadline: Double) -> Result {
        guard prepare(connection, deadline: deadline) else {
            return Result(read: .failed, target: target, browser: browser)
        }
        connection.errors.failed = false
        guard let tab = window.value(forKey: key) as? SBObject,
              !connection.errors.failed, prepare(connection, deadline: deadline) else {
            return Result(read: .failed, target: target, browser: browser)
        }
        let url = tab.value(forKey: "URL") as? String
        guard within(deadline), !connection.errors.failed, let url, !url.isEmpty else {
            return Result(read: .failed, target: target, browser: browser)
        }
        return Result(read: .url(url), target: target, browser: browser)
    }

    private static func uniqueTarget(for bounds: ActivityBounds, processID: pid_t,
                                     inventory: [ActivityWindow]) -> ActivityTarget? {
        let candidates = inventory.filter { $0.target.processID == processID }
        guard let index = ActivityWindowMatcher.uniqueMatch(bounds: bounds, candidates: candidates.map(\.bounds)) else {
            return nil
        }
        return candidates[index].target
    }

    /// Chromium exposes {left, top, right, bottom}; Safari can bridge an NSRect.
    private static func bounds(_ value: Any?) -> ActivityBounds? {
        if let numbers = value as? [NSNumber], numbers.count == 4 {
            let left = numbers[0].doubleValue
            let top = numbers[1].doubleValue
            return .init(x: left, y: top, width: numbers[2].doubleValue - left,
                         height: numbers[3].doubleValue - top)
        }
        if let value = value as? NSValue {
            let rect = value.rectValue
            return .init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
        }
        return nil
    }

    private static func displayName(_ name: String?) -> String? {
        name?.replacingOccurrences(of: " Browser", with: "")
    }

    private static func prepare(_ connection: Connection, deadline: Double) -> Bool {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return false }
        connection.app.timeout = max(1, min(60, Int(ceil(remaining * 60))))
        return true
    }

    private static func within(_ deadline: Double) -> Bool {
        ProcessInfo.processInfo.systemUptime <= deadline
    }

    private final class ErrorFlag: NSObject, SBApplicationDelegate {
        var failed = false
        func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: Error) -> Any? {
            failed = true
            return nil
        }
    }
}
