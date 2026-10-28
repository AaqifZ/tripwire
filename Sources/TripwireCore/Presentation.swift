import Foundation

/// Shared presentation for the live menu, snapshots, and regression checks.
public enum Presentation {
    public static let siteNames = "X, LinkedIn, Reddit, Instagram"

    public struct State {
        public var blockEnd: Date?
        public var site: String?
        public var secondsLeft: Double?
        public var safe = false
        public var writing = false
        public var blockMinutes: Int?
        public var blindSince: Date?
        public var blindBrowser: String?
        public var watchingBrowser: String?
        public var today = EventLog.Counts()
        public var enforcementFailure: String?
        public var activityFailure: String?
        public var onSite = true

        public init(blockEnd: Date? = nil, site: String? = nil, secondsLeft: Double? = nil,
                    safe: Bool = false, writing: Bool = false, blockMinutes: Int? = nil,
                    blindSince: Date? = nil, blindBrowser: String? = nil, watchingBrowser: String? = nil,
                    today: EventLog.Counts = .init(), enforcementFailure: String? = nil,
                    activityFailure: String? = nil, onSite: Bool = true) {
            self.blockEnd = blockEnd; self.site = site; self.secondsLeft = secondsLeft
            self.safe = safe; self.writing = writing; self.blockMinutes = blockMinutes
            self.blindSince = blindSince; self.blindBrowser = blindBrowser
            self.watchingBrowser = watchingBrowser; self.today = today
            self.enforcementFailure = enforcementFailure; self.activityFailure = activityFailure
            self.onSite = onSite
        }
    }

    public struct Look {
        public var symbol = "hourglass", title = ""
        public var headline: String?, detail: String?, health: String?
        public var today = ""
    }

    public static func look(_ s: State, now: Date = Date()) -> Look {
        let time = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
        var l = Look()
        // Health takes precedence over a paused countdown or an unverified block.
        if let failure = s.enforcementFailure {
            l.symbol = "exclamationmark.triangle"
            l.headline = "Block not verified"
            l.detail = failure
        } else if let failure = s.activityFailure {
            l.symbol = "exclamationmark.triangle"
            l.headline = "Activity detection unavailable"
            l.detail = failure
        } else if let since = s.blindSince {
            l.symbol = "exclamationmark.triangle"
            l.headline = "Can't read \(s.blindBrowser ?? "the browser")'s tab since \(time(since))"
            l.detail = "Tripwire cannot verify activity. Run: tripwire status"
        } else if let end = s.blockEnd, end > now {
            let minutes = Int(ceil(end.timeIntervalSince(now) / 60))
            l.symbol = "lock.fill"
            l.title = minutes >= 60 ? " \(minutes / 60)h \(minutes % 60)m" : " \(minutes)m"
            (l.headline, l.detail) = ("Blocked until \(time(end))", siteNames)
        } else if let left = s.secondsLeft {
            let seconds = Int(ceil(left))
            let clock = String(format: "%d:%02d", seconds / 60, seconds % 60)
            let site = s.site ?? "Watched site"
            l.symbol = s.safe || s.writing ? "pencil" : "hourglass"
            l.title = " " + clock
            if !s.onSite {
                l.headline = "\(site) · clock paused while away"
            } else if s.writing {
                l.headline = "\(site) · clock paused while you write"
            } else if s.safe {
                l.headline = "\(site) · this window will pass"
            } else {
                l.headline = "\(site) · block in \(clock)"
                l.detail = s.blockMinutes.map { "Then: all 4 sites blocked for \($0) min" }
                    ?? "Then: a trip is logged (test mode, no block)"
            }
        }
        if s.enforcementFailure == nil && s.activityFailure == nil && s.blindSince == nil {
            l.health = s.watchingBrowser.map { "Watching \($0)" } ?? "Watching \(siteNames)"
        }
        l.today = "Today: " + s.today.summary
        return l
    }
}
