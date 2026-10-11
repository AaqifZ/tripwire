import Foundation
import TripwireCore

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print("\(ok ? "PASS" : "FAIL")  \(name)")
    if !ok { failures += 1 }
}

/// Feeds `seconds` of 2 s ticks and returns the last non-watching verdict.
func feed(_ rule: inout Rule, seconds: Double, onSite: Bool, keysPerTick: Int = 0, scrollsPerTick: Int = 0, composing: Bool = false) -> Rule.Verdict {
    var last = Rule.Verdict.watching
    for _ in 0..<Int(seconds / 2) {
        let v = rule.tick(seconds: 2, onWatchedSite: onSite, keys: keysPerTick, scrolls: scrollsPerTick, composing: composing)
        if v != .watching { last = v }
    }
    return last
}

/// The D6/D12/D14 checks below test thresholds alone, with writing (D17) off.
let noWriting = Rule.Config(writingKeys: .max)

// Rule
do {
    var r = Rule(config: noWriting)
    check(feed(&r, seconds: 300, onSite: true, scrollsPerTick: 3) == .trip(keys: 0, scrolls: 450),
          "5 min scrolling with no keys trips")

    r = Rule(config: noWriting)
    check(feed(&r, seconds: 300, onSite: true, keysPerTick: 1) == .pass(keys: 150, scrolls: 0),
          "5 min while typing passes")

    r = Rule(config: noWriting)
    _ = feed(&r, seconds: 2, onSite: true, keysPerTick: 29)
    check(feed(&r, seconds: 298, onSite: true) == .trip(keys: 29, scrolls: 0), "29 keys is under the line: trips")

    r = Rule(config: noWriting)
    _ = feed(&r, seconds: 2, onSite: true, keysPerTick: 30)
    check(feed(&r, seconds: 298, onSite: true) == .pass(keys: 30, scrolls: 0), "30 keys is on the line: passes")

    r = Rule(config: noWriting)
    check(feed(&r, seconds: 3600, onSite: false, keysPerTick: 5) == .watching, "time off watched sites never trips")

    r = Rule(config: noWriting)
    _ = feed(&r, seconds: 200, onSite: true)
    _ = feed(&r, seconds: 100, onSite: false)
    check(r.onSiteSeconds == 200, "a short break keeps the window")
    _ = feed(&r, seconds: 200, onSite: false)
    check(r.onSiteSeconds == 0, "5 min away resets the window")

    r = Rule(config: noWriting)
    _ = feed(&r, seconds: 2, onSite: false, keysPerTick: 100)
    check(feed(&r, seconds: 300, onSite: true) == .trip(keys: 0, scrolls: 0), "keys typed off-site do not count")

    r = Rule(config: noWriting)
    _ = feed(&r, seconds: 300, onSite: true)
    check(r.onSiteSeconds == 0 && r.keys == 0, "a new window starts after a verdict")
}

// Warning (D12)
do {
    var r = Rule(config: noWriting)
    _ = feed(&r, seconds: 238, onSite: true)
    check(!r.isWarning, "no warning before 4 min")
    _ = feed(&r, seconds: 2, onSite: true)
    check(r.isWarning, "warning at 4 min with few keys")
    _ = feed(&r, seconds: 2, onSite: true, keysPerTick: 30)
    check(!r.isWarning, "typing 30 keys ends the warning at once")
    check(feed(&r, seconds: 58, onSite: true) == .pass(keys: 30, scrolls: 0), "and the window then passes")

    r = Rule(config: noWriting)
    _ = feed(&r, seconds: 300, onSite: true)
    check(!r.isWarning, "no warning after a verdict")
}

// Countdown (D14)
do {
    var r = Rule(config: noWriting)
    check(r.secondsLeft == nil, "no countdown before a watched site")
    _ = feed(&r, seconds: 2, onSite: true)
    check(r.secondsLeft == 298, "countdown starts on the first tick on site")
    _ = feed(&r, seconds: 58, onSite: true)
    check(r.secondsLeft == 240, "countdown falls with time on site")
    _ = feed(&r, seconds: 60, onSite: false)
    check(r.secondsLeft == 240, "countdown pauses while away")
    check(!r.isSafe, "not safe with no keys")
    _ = feed(&r, seconds: 2, onSite: true, keysPerTick: 30)
    check(r.isSafe, "safe after 30 keys")
    _ = feed(&r, seconds: 238, onSite: true)
    check(r.secondsLeft == nil, "countdown ends with the verdict")

    r = Rule(config: noWriting)
    _ = feed(&r, seconds: 2, onSite: true)
    _ = feed(&r, seconds: 300, onSite: false)
    check(r.secondsLeft == nil, "5 min away clears the countdown")
}

// Writing (D17)
do {
    var r = Rule()
    _ = feed(&r, seconds: 60, onSite: true)
    _ = feed(&r, seconds: 150, onSite: true, keysPerTick: 2)
    // Detection needs 20 keys in the window first: at 1 key/s that is about 20 s of clock.
    check(r.isWriting && r.onSiteSeconds < 85, "writing pauses the clock")
    let paused = r.onSiteSeconds
    _ = feed(&r, seconds: 30, onSite: true)
    check(!r.isWriting, "30 s without keys ends writing")
    check(r.onSiteSeconds > paused, "the clock runs again after writing")

    r = Rule()
    _ = feed(&r, seconds: 30, onSite: false, keysPerTick: 3)
    _ = feed(&r, seconds: 2, onSite: true)
    check(r.isWriting && r.onSiteSeconds == 0, "typing in another app (a draft) pauses the clock on return")

    r = Rule()
    _ = feed(&r, seconds: 120, onSite: true, composing: true)
    check(r.onSiteSeconds == 0, "an open composer pauses the clock")

    r = Rule()
    check(feed(&r, seconds: 300, onSite: true, keysPerTick: 1, scrollsPerTick: 3) == .pass(keys: 150, scrolls: 450),
          "slow keys (under 20 in 30 s) do not pause: the window still ends with a pass")

    r = Rule()
    _ = feed(&r, seconds: 240, onSite: true)
    check(r.isWarning, "gray at 4 min with no keys")
    _ = feed(&r, seconds: 2, onSite: true, composing: true)
    check(!r.isWarning, "opening a composer ends the gray at once")
}

// Pause cap and typing keys (D21)
do {
    var r = Rule()
    check(feed(&r, seconds: 480, onSite: true, composing: true) == .trip(keys: 0, scrolls: 0),
          "an idle composer pauses 3 min at most, then trips")
    check(r.lastPausedSeconds == 180, "the pause stops at the cap")

    r = Rule()
    _ = feed(&r, seconds: 240, onSite: true, keysPerTick: 2)
    check(!r.isWriting, "writing past the cap no longer pauses")
    check(feed(&r, seconds: 300, onSite: true, keysPerTick: 2) != .watching, "steady writing ends the window, with a pass")

    r = Rule()
    _ = feed(&r, seconds: 150, onSite: true, composing: true)
    _ = feed(&r, seconds: 300, onSite: false)
    _ = feed(&r, seconds: 2, onSite: true, composing: true)
    check(r.isWriting, "a new window gets a new pause allowance")

    check(Keys.isTyping(keyCode: 0, command: false, control: false), "a letter is typing")
    check(Keys.isTyping(keyCode: 36, command: false, control: false), "return is typing")
    check(!Keys.isTyping(keyCode: 49, command: false, control: false), "space is not typing (it scrolls)")
    check(!Keys.isTyping(keyCode: 125, command: false, control: false), "down arrow is not typing")
    check(!Keys.isTyping(keyCode: 121, command: false, control: false), "page down is not typing")
    check(!Keys.isTyping(keyCode: 9, command: true, control: false), "cmd+v is not typing")
    check(!Keys.isTyping(keyCode: 48, command: false, control: true), "ctrl+tab is not typing")
}

// Windows that end with no verdict (D18)
do {
    var r = Rule(config: noWriting)
    _ = feed(&r, seconds: 200, onSite: true, keysPerTick: 1, scrollsPerTick: 3)
    check(feed(&r, seconds: 300, onSite: false) == .abandon(keys: 100, scrolls: 300, onSiteSeconds: 200),
          "5 min away closes the window as abandoned, with its counts")
    check(r.lastPausedSeconds == 0, "no writing: nothing paused")

    r = Rule(config: noWriting)
    check(feed(&r, seconds: 600, onSite: false) == .watching, "no time on site: no abandoned line")

    r = Rule()
    _ = feed(&r, seconds: 120, onSite: true, composing: true)
    check(feed(&r, seconds: 300, onSite: false) == .abandon(keys: 0, scrolls: 0, onSiteSeconds: 0),
          "a window spent all in a composer is still logged when abandoned")
    check(r.lastPausedSeconds == 120, "and its paused time is kept for the log")

    r = Rule()
    _ = feed(&r, seconds: 60, onSite: true, composing: true)
    check(r.pausedSeconds == 60, "composer time counts as paused")
    check(feed(&r, seconds: 300, onSite: true) == .trip(keys: 0, scrolls: 0), "the clock runs on after the composer")
    check(r.lastPausedSeconds == 60 && r.pausedSeconds == 0, "a verdict keeps the paused time and starts again at 0")

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tripwire-selftest-\(UUID())")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let log = EventLog(stateDir: dir)
    log.append(.abandon(keys: 4, scrolls: 812, onSiteSeconds: 170), site: "x.com", paused: 30)
    log.append(.pass(keys: 48, scrolls: 1954), site: "x.com", paused: 480)
    let lines = log.today()
    check(lines.count == 2 && lines[0].hasSuffix(" abandon keys=4 scrolls=812 onsite=170s paused=30s site=x.com"),
          "abandoned line has counts, on-site and paused seconds")
    check(lines.count == 2 && lines[1].hasSuffix(" pass keys=48 scrolls=1954 paused=480s site=x.com"),
          "pass line has paused seconds")
    try? FileManager.default.removeItem(at: dir)
}

check(Sites.isComposer(url: "https://www.linkedin.com/sharing/compose"), "LinkedIn composer")
check(Sites.isComposer(url: "https://x.com/compose/post"), "X composer")
check(Sites.isComposer(url: "https://old.reddit.com/r/swift/submit") == false, "subreddit submit is not matched (prefix only)")
check(Sites.isComposer(url: "https://www.reddit.com/submit"), "Reddit submit")
check(!Sites.isComposer(url: "https://www.linkedin.com/feed/"), "LinkedIn feed is not a composer")
check(!Sites.isComposer(url: "https://example.com/sharing/compose"), "unwatched site is not a composer")

// Sites
check(Sites.match(url: "https://x.com/home") == "x.com", "x.com matches")
check(Sites.match(url: "https://www.linkedin.com/feed/") == "linkedin.com", "www subdomain matches")
check(Sites.match(url: "https://old.reddit.com/r/swift") == "reddit.com", "old.reddit matches")
check(Sites.match(url: "https://notx.com/") == nil, "notx.com does not match x.com")
check(Sites.match(url: "https://github.com/") == nil, "github does not match")
check(Sites.match(url: "https://www.youtube.com/") == nil, "youtube is out of scope")
check(Sites.match(url: "not a url") == nil, "garbage does not match")
check(Sites.blocklist.contains("www.instagram.com"), "blocklist has www variants")

// Heartbeat
check(Heartbeat.describe(age: nil).contains("NOT RUNNING"), "no heartbeat file: not running")
check(Heartbeat.describe(age: 9).contains("ticking"), "a fresh beat: ticking")
check(Heartbeat.describe(age: 31 * 60).contains("FROZEN"), "a 31 min old beat: frozen")
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tripwire-selftest-\(UUID())")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    check(Heartbeat.age(stateDir: dir) == nil, "no beat yet: age is nil")
    Heartbeat.beat(stateDir: dir)
    Heartbeat.beat(stateDir: dir)
    check((Heartbeat.age(stateDir: dir) ?? 99) < 5, "a beat makes the age fresh")
    try? FileManager.default.removeItem(at: dir)
}

// Today's counts (menu, status)
check(EventLog.Counts(trips: 0, passes: 2).summary == "0 trips · 2 passes", "summary: plurals, no left early at 0")
check(EventLog.Counts(trips: 1, passes: 1, abandons: 3).summary == "1 trip · 1 pass · 3 left early", "summary: singulars and left early")
check(EventLog.counts(["t pass keys=1", "t trip keys=0", "t abandon keys=0", "t pass keys=9"]) == EventLog.Counts(trips: 1, passes: 2, abandons: 1), "counts by kind")

// Detection (D20)
do {
    var d = Detection()
    _ = d.tick(seconds: 59, read: .failed, browser: "Brave")
    check(!d.isBlind, "59 s of failed reads: not blind yet")
    check(d.tick(seconds: 1, read: .failed, browser: "Brave") && d.isBlind, "60 s of failed reads: blind")
    _ = d.tick(seconds: 30, read: .notBrowser, browser: nil)
    check(d.isBlind, "a non-browser app in front does not clear blindness")
    check(d.tick(seconds: 1, read: .url("https://x.com/"), browser: "Brave") && !d.isBlind, "one good read clears blindness")
    check(d.lastBrowser == "Brave", "a good read records the browser")
    d = Detection()
    _ = d.tick(seconds: 600, read: .noWindow, browser: "Brave")
    check(!d.isBlind, "a browser with no window is not blind")
    check(Detection.describe(blindSince: nil) == "detection: ok", "no blind file: ok")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tripwire-selftest-\(UUID())")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    Detection.mark(blind: true, stateDir: dir)
    check(Detection.blindSince(stateDir: dir) != nil, "blind file is written")
    check(Detection.describe(blindSince: Detection.blindSince(stateDir: dir)).contains("BLIND"), "status shows BLIND")
    Detection.mark(blind: false, stateDir: dir)
    check(Detection.blindSince(stateDir: dir) == nil, "blind file is removed when clear")
    try? FileManager.default.removeItem(at: dir)
}

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
