import AppKit
import TripwireCore

let usage = """
tripwire: one job, make doomscrolling hard.

  tripwire run            Watch and block (the LaunchAgent runs this).
  tripwire run --test     30 s window (gray at 20 s), logs a trip but does not block.
  tripwire status         Block state and today's results.
  tripwire snapshot DIR   Draw the menu bar item with sample states to PNG files (for docs).
"""

let stateDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tripwire")
try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
let log = EventLog(stateDir: stateDir)
let blockMinutes = 90
let tickSeconds = 1.0  // 1 s so the menu bar countdown moves one second at a time (D14)

func say(_ text: String) {
    FileHandle.standardError.write(Data("\(ISO8601DateFormatter().string(from: Date())) \(text)\n".utf8))
}

func run(test: Bool) -> Never {
    guard InputCounter.start() else {
        say("Input Monitoring access missing. Grant it in System Settings > Privacy & Security > Input Monitoring.")
        exit(1)
    }
    var rule = Rule(config: test ? .init(windowSeconds: 30, warnSeconds: 20) : .init())
    var lastSite = ""
    var onSite: String?
    var wasWriting = false
    var tickCount = 0
    // Known block end. Polled from SelfControl every 30 s, so a block started elsewhere shows too.
    var blockEnd = Blocker.endDate()
    var detection = Detection()
    var blindBrowser: String?
    var blindSince: Date?
    var today = EventLog.counts(log.today())
    Detection.mark(blind: false, stateDir: stateDir)
    Grayscale.recover()
    // Never leave the screen gray when launchd stops tripwire.
    signal(SIGTERM, SIG_IGN)
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    term.setEventHandler { Grayscale.set(false); exit(0) }
    term.resume()
    Heartbeat.beat(stateDir: stateDir)
    say("tripwire running\(test ? " (test mode: 30 s window, no block)" : "")\(Grayscale.isAvailable ? "" : ", grayscale warning unavailable")")

    let timer = Timer(timeInterval: tickSeconds, repeats: true) { _ in
        tickCount += 1
        if tickCount % Int(30 / tickSeconds) == 0 { blockEnd = Blocker.endDate(); today = EventLog.counts(log.today()) }
        if tickCount % Heartbeat.everySeconds == 0 { Heartbeat.beat(stateDir: stateDir) }
        let read = ActiveTab.read()
        let browser = ActiveTab.browserName
        if detection.tick(seconds: tickSeconds, read: read, browser: browser) {
            if detection.isBlind { blindBrowser = browser }
            blindSince = detection.isBlind ? Date().addingTimeInterval(-Detection.blindAfterSeconds) : nil
            say(detection.isBlind ? "BLIND: cannot read the \(browser ?? "browser") tab for \(Int(Detection.blindAfterSeconds)) s" : "can read the tab again")
            Detection.mark(blind: detection.isBlind, stateDir: stateDir)
        }
        let url: String? = if case let .url(u) = read { u } else { nil }
        let site = url.flatMap(Sites.match)
        let counts = InputCounter.drain()
        if site != onSite {
            say(site.map { "on \($0)" } ?? "off watched sites (front: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"))")
            onSite = site
        }
        if let site { lastSite = site }
        let verdict = rule.tick(seconds: tickSeconds, onWatchedSite: site != nil,
                                keys: counts.keys, scrolls: counts.scrolls,
                                composing: url.map(Sites.isComposer) ?? false)
        if rule.isWriting != wasWriting { say(rule.isWriting ? "writing: clock paused" : "stopped writing"); wasWriting = rule.isWriting }
        // Gray only while on the site in a window about to trip. Leave or type and color returns.
        Grayscale.set(site != nil && rule.isWarning)
        switch verdict {
        case .watching:
            break
        case .pass, .abandon:
            log.append(verdict, site: lastSite, paused: rule.lastPausedSeconds)
            today = EventLog.counts(log.today())
        case .trip:
            if test {
                log.append(verdict, site: lastSite, paused: rule.lastPausedSeconds)
                say("TRIP (test mode, no block)")
            } else {
                let started = Blocker.start(minutes: blockMinutes, stateDir: stateDir)
                blockEnd = Blocker.endDate()
                log.append(verdict, site: lastSite, paused: rule.lastPausedSeconds, blocked: started)
                say(started ? "TRIP: \(blockMinutes) min block started" : "TRIP: block FAILED to start")
            }
            today = EventLog.counts(log.today())
        }
        MenuBar.show(.init(blockEnd: blockEnd, site: lastSite.isEmpty ? nil : lastSite,
                           secondsLeft: rule.secondsLeft, safe: rule.isSafe, writing: rule.isWriting,
                           blockMinutes: test ? nil : blockMinutes,
                           blindSince: blindSince,
                           blindBrowser: blindBrowser, watchingBrowser: detection.lastBrowser, today: today))
    }
    // Common modes: the clock keeps running while the menu bar menu is open.
    RunLoop.main.add(timer, forMode: .common)
    // An accessory app: no Dock icon, but allowed a menu bar item.
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.run()
    exit(0)
}

func status() {
    print(Heartbeat.describe(age: Heartbeat.age(stateDir: stateDir)))
    print(Detection.describe(blindSince: Detection.blindSince(stateDir: stateDir)))
    if let end = Blocker.endDate() {
        let left = Int(end.timeIntervalSinceNow / 60) + 1
        print("BLOCKED until \(end.formatted(date: .omitted, time: .shortened)) (\(left) min left)")
    } else {
        print("no block: sites are open")
    }
    let lines = log.today()
    let c = EventLog.counts(lines)
    print("today: \(c.trips) trips, \(c.passes) passes, \(c.abandons) left early")
    lines.suffix(5).forEach { print("  \($0)") }
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "run": run(test: args.contains("--test"))
case "status": status()
case "snapshot": Snapshot.run(dir: args.count > 1 ? args[1] : ".")
default: print(usage)
}
