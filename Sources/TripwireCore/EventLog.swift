import Foundation

/// One line per window result. Counts, seconds and the matched domain only (D11, D18).
public struct EventLog {
    public let file: URL

    public init(stateDir: URL) {
        file = stateDir.appendingPathComponent("events.log")
    }

    public func append(_ verdict: Rule.Verdict, site: String, paused: Double = 0, blocked: Bool? = nil, at date: Date = Date()) {
        let time = ISO8601DateFormatter().string(from: date)
        let line: String
        let pausedField = " paused=\(Int(paused))s"
        switch verdict {
        case .watching: return
        case let .pass(keys, scrolls):
            line = "\(time) pass keys=\(keys) scrolls=\(scrolls)\(pausedField) site=\(site)\n"
        case let .trip(keys, scrolls):
            let suffix = blocked.map { $0 ? " block=started" : " block=FAILED" } ?? ""
            line = "\(time) trip keys=\(keys) scrolls=\(scrolls)\(pausedField) site=\(site)\(suffix)\n"
        case let .abandon(keys, scrolls, onSite):
            line = "\(time) abandon keys=\(keys) scrolls=\(scrolls) onsite=\(onSite)s\(pausedField) site=\(site)\n"
        }
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: file)
        }
    }

    /// Lines written today (local time), for `tripwire status`.
    public func today() -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let start = Calendar.current.startOfDay(for: Date())
        let parser = ISO8601DateFormatter()
        return text.split(separator: "\n").map(String.init).filter { line in
            guard let stamp = line.split(separator: " ").first,
                  let date = parser.date(from: String(stamp)) else { return false }
            return date >= start
        }
    }

    /// Today's results, for `tripwire status` and the menu.
    public struct Counts: Equatable {
        public var trips = 0, passes = 0, abandons = 0
        public init(trips: Int = 0, passes: Int = 0, abandons: Int = 0) {
            self.trips = trips; self.passes = passes; self.abandons = abandons
        }
        public var summary: String {
            var parts = ["\(trips) \(trips == 1 ? "trip" : "trips")", "\(passes) \(passes == 1 ? "pass" : "passes")"]
            if abandons > 0 { parts.append("\(abandons) left early") }
            return parts.joined(separator: " · ")
        }
    }

    public static func counts(_ lines: [String]) -> Counts {
        let count = { (kind: String) in lines.filter { $0.contains(" \(kind) ") }.count }
        return Counts(trips: count("trip"), passes: count("pass"), abandons: count("abandon"))
    }
}
