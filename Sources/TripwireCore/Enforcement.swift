import Foundation

/// The durable lifecycle between a rule trip and a verified SelfControl block.
/// A trip remains pending across failures and process restarts.
public struct Enforcement {
    public struct Pending: Codable, Equatable {
        public var requiredUntil: Date
        public var attempts: Int
        public var nextAttemptAt: Date
        public var lastFailure: String?

        public init(requiredUntil: Date, attempts: Int = 0, nextAttemptAt: Date,
                    lastFailure: String? = nil) {
            self.requiredUntil = requiredUntil
            self.attempts = attempts
            self.nextAttemptAt = nextAttemptAt
            self.lastFailure = lastFailure
        }
    }

    public enum Outcome: Equatable {
        case idle
        case retryScheduled(String)
        case satisfied(until: Date)
    }

    public private(set) var pending: Pending?
    public private(set) var isAttemptInFlight = false
    public private(set) var persistenceFailure: String?

    public init(pending: Pending? = nil) { self.pending = pending }

    public static func file(stateDir: URL) -> URL {
        stateDir.appendingPathComponent("enforcement.json")
    }

    public static func load(stateDir: URL) -> Enforcement {
        let url = file(stateDir: stateDir)
        guard FileManager.default.fileExists(atPath: url.path) else { return Enforcement() }
        do {
            let data = try Data(contentsOf: url)
            let state = try decoder.decode(PersistentState.self, from: data)
            return Enforcement(pending: state.pending)
        } catch {
            var enforcement = Enforcement()
            enforcement.persistenceFailure = "Could not restore pending enforcement: \(error.localizedDescription)"
            return enforcement
        }
    }

    /// Opens one request only. More trips cannot slide a failed request forward.
    public mutating func registerTrip(at now: Date, duration: TimeInterval, stateDir: URL) {
        guard pending == nil else { return }
        pending = Pending(requiredUntil: Self.canonicalEnd(now.addingTimeInterval(duration)), nextAttemptAt: now)
        persist(stateDir: stateDir)
    }

    /// Claims the next attempt. If the original required period already elapsed,
    /// rebase it once for this new attempt. It then stays fixed through retries.
    public mutating func beginAttempt(at now: Date, duration: TimeInterval, stateDir: URL) -> Date? {
        guard !isAttemptInFlight, var request = pending, now >= request.nextAttemptAt else { return nil }
        if request.requiredUntil <= now {
            request.requiredUntil = Self.canonicalEnd(now.addingTimeInterval(duration))
            pending = request
            persist(stateDir: stateDir)
        }
        isAttemptInFlight = true
        return request.requiredUntil
    }

    /// Accepts only the effective policy as proof. Exit status and an existing
    /// unrelated block both leave the request pending.
    public mutating func finishAttempt(_ snapshot: BlockSnapshot, at now: Date, stateDir: URL) -> Outcome {
        isAttemptInFlight = false
        guard var request = pending else { return .idle }
        if case let .active(block) = snapshot,
           block.covers(requiredDomains: Sites.blocklist, until: request.requiredUntil) {
            pending = nil
            persist(stateDir: stateDir)
            return .satisfied(until: block.endDate)
        }

        request.attempts += 1
        let failure = Self.describe(snapshot, requiredUntil: request.requiredUntil)
        request.lastFailure = failure
        request.nextAttemptAt = now.addingTimeInterval(Self.backoff(after: request.attempts))
        pending = request
        persist(stateDir: stateDir)
        return .retryScheduled(failure)
    }

    private static func backoff(after attempts: Int) -> TimeInterval {
        let exponent = min(max(0, attempts - 1), 4)
        return min(60, 5 * pow(2, Double(exponent)))
    }

    /// SelfControl's documented CLI examples and secured settings use whole
    /// seconds. Round up so a verified block cannot appear microscopically short.
    private static func canonicalEnd(_ date: Date) -> Date {
        Date(timeIntervalSince1970: ceil(date.timeIntervalSince1970))
    }

    private static func describe(_ snapshot: BlockSnapshot, requiredUntil: Date) -> String {
        switch snapshot {
        case .unavailable:
            return "SelfControl is unavailable"
        case let .failed(reason):
            return reason
        case .inactive:
            return "SelfControl did not report an active block"
        case let .active(block):
            if block.isAllowlist { return "A different SelfControl allowlist is active" }
            let actual = Set(block.domains.map { $0.lowercased() })
            let missing = Sites.blocklist.filter { !actual.contains($0.lowercased()) }
            if !missing.isEmpty { return "The active SelfControl block does not cover \(missing.joined(separator: ", "))" }
            return "The active SelfControl block ends before the required time"
        }
    }

    private mutating func persist(stateDir: URL) {
        do {
            let data = try Self.encoder.encode(PersistentState(pending: pending))
            try data.write(to: Self.file(stateDir: stateDir), options: [.atomic])
            persistenceFailure = nil
        } catch {
            persistenceFailure = "Could not save pending enforcement: \(error.localizedDescription)"
        }
    }

    private struct PersistentState: Codable { var pending: Pending? }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
