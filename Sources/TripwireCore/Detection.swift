import Foundation

/// Proof that tripwire can see the tab (D20). The heartbeat (D15) proves the tick runs.
/// The tick can run while the tab read fails, for example with no Automation access.
public struct Detection {
    /// What one tab read gave.
    public enum Read: Equatable {
        case notBrowser      // a non-browser app is in front: nothing to read
        case noWindow        // a browser is in front with no window open
        case url(String)     // the read worked
        case failed          // a browser with a window is in front, and the read gave nothing
    }

    /// Failed reads for this long, in a row, mean tripwire is blind.
    public static let blindAfterSeconds: Double = 60

    public private(set) var failedSeconds: Double = 0
    /// The browser of the last good read, for the menu ("Watching Brave").
    public private(set) var lastBrowser: String?

    public init() {}

    public var isBlind: Bool { failedSeconds >= Self.blindAfterSeconds }

    /// Returns true when `isBlind` changed.
    public mutating func tick(seconds: Double, read: Read, browser: String?) -> Bool {
        let was = isBlind
        switch read {
        case .failed: failedSeconds += seconds
        case .url: failedSeconds = 0; lastBrowser = browser
        case .notBrowser, .noWindow: break // no evidence either way: keep the count
        }
        return isBlind != was
    }

    // The daemon writes the start of blindness here, so `tripwire status` can show it.

    public static func file(stateDir: URL) -> URL {
        stateDir.appendingPathComponent("blind")
    }

    public static func mark(blind: Bool, stateDir: URL, now: Date = Date()) {
        let url = file(stateDir: stateDir)
        if blind {
            let since = now.addingTimeInterval(-blindAfterSeconds)
            try? Data(ISO8601DateFormatter().string(from: since).utf8).write(to: url)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// When blindness started, or nil when tripwire can see.
    public static func blindSince(stateDir: URL) -> Date? {
        guard let text = try? String(contentsOf: file(stateDir: stateDir), encoding: .utf8) else { return nil }
        return ISO8601DateFormatter().date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// One line for `tripwire status`.
    public static func describe(blindSince: Date?) -> String {
        guard let since = blindSince else { return "detection: ok" }
        return "detection: BLIND since \(since.formatted(date: .omitted, time: .shortened)) (cannot read the browser tab). Check the Automation permission for tripwire."
    }
}
