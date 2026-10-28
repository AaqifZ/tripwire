import Foundation

public enum BuildInfo {
    public static let version = "0.2.1"
}

/// Local health metadata. Contains no input events, URLs, or page content.
public struct RuntimeHealth: Codable {
    public var version: String
    public var pid: Int32
    public var testMode: Bool
    public var updatedAt: Date
    public var activity: String
    public var enforcement: String
    public var attribution: String?

    public init(pid: Int32, testMode: Bool, activity: String, enforcement: String,
                attribution: String? = nil, now: Date = Date()) {
        version = BuildInfo.version; self.pid = pid; self.testMode = testMode
        updatedAt = now; self.activity = activity; self.enforcement = enforcement
        self.attribution = attribution
    }

    public func save(stateDir: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: stateDir.appendingPathComponent("runtime.json"), options: .atomic)
    }

    public static func load(stateDir: URL) -> RuntimeHealth? {
        guard let data = try? Data(contentsOf: stateDir.appendingPathComponent("runtime.json")) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}
