/// The one rule. Pure: no clocks, no I/O. The daemon feeds it ticks.
///
/// Only time with a watched site in the front tab counts. After `windowSeconds`
/// of that time, fewer than `minKeys` keystrokes means doomscrolling.
public struct Rule {
    public struct Config {
        public var windowSeconds: Double
        public var minKeys: Int
        public var awayResetSeconds: Double
        public var warnSeconds: Double
        /// Writing (D17): at least `writingKeys` keys in the last `writingSeconds`, in any app.
        public var writingKeys: Int
        public var writingSeconds: Double
        /// Writing pauses the clock for this long at most, per window (D21).
        public var maxPausedSeconds: Double

        public init(windowSeconds: Double = 300, minKeys: Int = 30, awayResetSeconds: Double = 300, warnSeconds: Double = 240,
                    writingKeys: Int = 20, writingSeconds: Double = 30, maxPausedSeconds: Double = 180) {
            self.windowSeconds = windowSeconds
            self.minKeys = minKeys
            self.awayResetSeconds = awayResetSeconds
            self.warnSeconds = warnSeconds
            self.writingKeys = writingKeys
            self.writingSeconds = writingSeconds
            self.maxPausedSeconds = maxPausedSeconds
        }
    }

    public enum Verdict: Equatable {
        case watching
        case pass(keys: Int, scrolls: Int)
        case trip(keys: Int, scrolls: Int)
        /// The window reset with no verdict: you left before the clock ran out (D18).
        case abandon(keys: Int, scrolls: Int, onSiteSeconds: Int)
    }

    public let config: Config
    public private(set) var onSiteSeconds: Double = 0
    public private(set) var keys = 0
    public private(set) var scrolls = 0
    /// On-site seconds with the clock paused by writing (D17), in the open window.
    public private(set) var pausedSeconds: Double = 0
    /// `pausedSeconds` of the window that just closed, for its log line (D18).
    public private(set) var lastPausedSeconds: Double = 0
    private var awaySeconds: Double = 0
    /// Keys per tick over the last `writingSeconds`, on or off the site (D17).
    private var recent: [(seconds: Double, keys: Int)] = []
    private var composing = false

    /// Writing a post: typing fast anywhere, or a post composer open (D17).
    /// The clock pauses while this is true, up to `maxPausedSeconds` per window (D21).
    public var isWriting: Bool {
        (composing || recent.reduce(0) { $0 + $1.keys } >= config.writingKeys)
            && pausedSeconds < config.maxPausedSeconds
    }

    /// The last minute of a window that is on course to trip (D12).
    /// Typing up to `minKeys` ends it at once. Never while writing.
    public var isWarning: Bool {
        onSiteSeconds >= config.warnSeconds && keys < config.minKeys && !isWriting
    }

    /// On-site seconds left before the verdict, or nil when no window is open (D14).
    /// The clock pauses while you are away and keeps the time left.
    public var secondsLeft: Double? {
        onSiteSeconds > 0 ? max(0, config.windowSeconds - onSiteSeconds) : nil
    }

    /// Enough keys typed: this window will pass.
    public var isSafe: Bool { keys >= config.minKeys }

    public init(config: Config = Config()) {
        self.config = config
    }

    /// One tick. `keys` and `scrolls` are the counts since the previous tick.
    /// `composing` is true when the front tab is a post composer.
    public mutating func tick(seconds: Double, onWatchedSite: Bool, keys newKeys: Int, scrolls newScrolls: Int,
                              composing: Bool = false) -> Verdict {
        recent.append((seconds, newKeys))
        while recent.reduce(0, { $0 + $1.seconds }) > config.writingSeconds { recent.removeFirst() }
        self.composing = composing
        guard onWatchedSite else {
            awaySeconds += seconds
            guard awaySeconds >= config.awayResetSeconds else { return .watching }
            let open = onSiteSeconds > 0 || pausedSeconds > 0
            let verdict = Verdict.abandon(keys: keys, scrolls: scrolls, onSiteSeconds: Int(onSiteSeconds))
            reset()
            return open ? verdict : .watching
        }
        awaySeconds = 0
        keys += newKeys
        scrolls += newScrolls
        // Writing pauses the clock (D17). A window already open stays open.
        if isWriting { pausedSeconds += seconds; return .watching }
        onSiteSeconds += seconds
        guard onSiteSeconds >= config.windowSeconds else { return .watching }

        let verdict: Verdict = keys < config.minKeys
            ? .trip(keys: keys, scrolls: scrolls)
            : .pass(keys: keys, scrolls: scrolls)
        reset()
        return verdict
    }

    public mutating func reset() {
        lastPausedSeconds = pausedSeconds
        pausedSeconds = 0
        onSiteSeconds = 0
        keys = 0
        scrolls = 0
        awaySeconds = 0
    }
}
