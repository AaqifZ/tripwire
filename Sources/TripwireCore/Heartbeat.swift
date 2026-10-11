import Foundation

/// Proof that the tick still runs (D15). launchd knows only that the process exists:
/// if the tick dies, launchd still shows tripwire as running.
public enum Heartbeat {
    /// The daemon beats every `everySeconds`. Older than `staleSeconds` means the tick is dead.
    public static let everySeconds = 10
    public static let staleSeconds: Double = 30

    public static func file(stateDir: URL) -> URL {
        stateDir.appendingPathComponent("heartbeat")
    }

    public static func beat(stateDir: URL) {
        let url = file(stateDir: stateDir)
        if (try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)) == nil {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
    }

    /// Seconds since the last beat, or nil if tripwire never beat.
    public static func age(stateDir: URL, now: Date = Date()) -> Double? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: file(stateDir: stateDir).path)
        return (attrs?[.modificationDate] as? Date).map { now.timeIntervalSince($0) }
    }

    /// One line for `tripwire status`.
    public static func describe(age: Double?) -> String {
        guard let age else { return "daemon: NOT RUNNING (no heartbeat yet)" }
        if age <= staleSeconds { return "daemon: ticking (last beat \(Int(age)) s ago)" }
        let ago = age < 120 ? "\(Int(age)) s" : "\(Int(age / 60)) min"
        return "daemon: STOPPED or FROZEN (last beat \(ago) ago). Reinstall with scripts/install.sh, then read ~/.tripwire/tripwire.err."
    }
}
