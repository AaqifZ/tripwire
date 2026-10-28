/// One accounting decision after a browser observation.
public enum SessionAccounting {
    public static func apply(rule: inout Rule, seconds: Double, known: Bool, protected: Bool,
                             onWatchedSite: Bool, keys: Int, scrolls: Int, composing: Bool) -> Rule.Verdict {
        if protected {
            // A blocked browser error page is not another 90-minute obligation.
            rule.reset()
            return .watching
        }
        guard known else {
            rule.hold(seconds: seconds)
            return .watching
        }
        return rule.tick(seconds: seconds, onWatchedSite: onWatchedSite,
                         keys: keys, scrolls: scrolls, composing: composing)
    }
}
