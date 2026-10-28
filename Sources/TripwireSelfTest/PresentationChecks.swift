import Foundation
import TripwireCore

func runPresentationChecks() {
    let now = Date(timeIntervalSince1970: 1000)
    let blind = Presentation.look(.init(site: "x.com", secondsLeft: 180, blindSince: now), now: now)
    check(blind.symbol == "exclamationmark.triangle" && blind.title.isEmpty,
          "blindness takes precedence over an open countdown")
    check(blind.health == nil, "blind menu does not claim to be watching")
    let failed = Presentation.look(.init(blockEnd: now.addingTimeInterval(500),
                                        enforcementFailure: "Retry pending"), now: now)
    check(failed.headline == "Block not verified", "enforcement failure takes precedence over a block display")
    let unknown = Presentation.look(.init(secondsLeft: 120, activityFailure: "Ambiguous window"), now: now)
    check(unknown.headline == "Activity detection unavailable", "ambiguous activity cannot hide behind countdown")
    let away = Presentation.look(.init(site: "x.com", secondsLeft: 120, onSite: false), now: now)
    check(away.headline?.contains("paused while away") == true, "away menu explains the paused clock")
    let blocked = Presentation.look(.init(blockEnd: now.addingTimeInterval(5399)), now: now)
    check(blocked.symbol == "lock.fill" && blocked.title == " 1h 30m", "verified block shows rounded remaining time")
    var clock = TickClock()
    check(clock.elapsed(at: 100) == 0, "first clock observation charges no unknown time")
    check(clock.elapsed(at: 102.5) == 2.5, "delayed callback counts measured elapsed time")
    check(clock.elapsed(at: 1000) == 0, "sleep gap does not count as browser use")
    check(clock.elapsed(at: 1001) == 1, "clock resumes after suspension")
    check(clock.elapsed(at: 999) == 0, "backward clock does not subtract site time")
    check(!Keys.isTyping(keyCode: 122, command: false, control: false), "function keys do not count as creation")
    check(!Keys.isTyping(keyCode: 72, command: false, control: false), "volume keys do not count as creation")
    var rule = Rule(config: .init(writingKeys: .max))
    _ = rule.tick(seconds: 290, onWatchedSite: true, keys: 0, scrolls: 10)
    var unknownVerdict = false
    for _ in 0..<600 {
        let result = SessionAccounting.apply(rule: &rule, seconds: 1, known: false, protected: false,
                                              onWatchedSite: false, keys: 100, scrolls: 10, composing: true)
        if result != .watching { unknownVerdict = true }
    }
    check(!unknownVerdict, "unknown interval produces no verdict")
    check(rule.onSiteSeconds == 290 && rule.keys == 0, "unknown interval preserves time without a reset or typing credit")
    let resumed = SessionAccounting.apply(rule: &rule, seconds: 10, known: true, protected: false,
                                           onWatchedSite: true, keys: 0, scrolls: 1, composing: false)
    check(resumed == .trip(keys: 0, scrolls: 11), "verified observation resumes preserved countdown")
    var extraTrip = false
    for _ in 0..<600 {
        let result = SessionAccounting.apply(rule: &rule, seconds: 1, known: true, protected: true,
                                              onWatchedSite: true, keys: 0, scrolls: 10, composing: false)
        if result != .watching { extraTrip = true }
    }
    check(!extraTrip && rule.onSiteSeconds == 0, "blocked error page does not create another enforcement obligation")
}
