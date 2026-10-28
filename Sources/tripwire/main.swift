import AppKit
import Darwin
import TripwireCore

let usage = """
tripwire: one job, make doomscrolling hard.

  tripwire run            Watch and block (the LaunchAgent runs this).
  tripwire run --test     30 s window, logs trips without blocking.
  tripwire status         Health, verified block state, and today's results.
  tripwire probe [SECONDS] Observe activity without a block or gray screen.
  tripwire snapshot DIR   Draw sample menu states to PNG files.
  tripwire --version      Print the build version.
"""

let stateDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tripwire")
umask(0o077)
try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDir.path)
let log = EventLog(stateDir: stateDir)
let blockMinutes = 90

func say(_ text: String) {
    FileHandle.standardError.write(Data("\(ISO8601DateFormatter().string(from: Date())) \(text)\n".utf8))
}

func verifiedEnd(_ snapshot: BlockSnapshot, now: Date = Date()) -> Date? {
    guard case let .active(block) = snapshot,
          block.covers(requiredDomains: Sites.blocklist, until: now) else { return nil }
    return block.endDate
}

func run(test: Bool) -> Never {
    // Keep the descriptor open for the process lifetime. A crash releases the lock.
    let lockFD = open(stateDir.appendingPathComponent("daemon.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
        say("Another tripwire daemon is running, or the daemon lock is unavailable.")
        exit(1)
    }
    guard InputCounter.start() else {
        say("Input Monitoring access missing. Grant it in System Settings > Privacy & Security > Input Monitoring.")
        exit(1)
    }
    var rule = Rule(config: test ? .init(windowSeconds: 30, warnSeconds: 20) : .init())
    var enforcement = Enforcement.load(stateDir: stateDir)
    var blockSnapshot = BlockSnapshot.failed("SelfControl has not been checked yet")
    var blockerBusy = false
    let blockerQueue = DispatchQueue(label: "tripwire.blocker", qos: .utility)
    let monitor = ActivityMonitor()
    var detection = Detection()
    var lastSite = ""
    var currentSite: String?
    var lastBrowser: String?
    var blindSince: Date?
    var activityFailure: String? = "Activity has not been sampled yet"
    var lastAttribution: String?
    var lastSampleAt = ProcessInfo.processInfo.systemUptime
    var lastPollAt = -Double.infinity
    var lastHealthAt = -Double.infinity
    var today = EventLog.counts(log.today())

    func enforcementMessage() -> String? {
        guard !test else { return nil }
        if let failure = enforcement.persistenceFailure { return failure }
        if let pending = enforcement.pending {
            let wait = max(0, Int(ceil(pending.nextAttemptAt.timeIntervalSinceNow)))
            return enforcement.isAttemptInFlight ? "Checking SelfControl; the trip remains pending"
                : "\(pending.lastFailure ?? "A trip is pending"). Retry in \(wait) s"
        }
        switch blockSnapshot {
        case .unavailable: return "SelfControl is unavailable; trips cannot be enforced"
        case let .failed(reason): return reason
        case let .active(block) where verifiedEnd(blockSnapshot) == nil:
            return block.endDate > Date() ? "A different SelfControl block is active" : nil
        default: return nil
        }
    }

    func show() {
        MenuBar.show(.init(blockEnd: verifiedEnd(blockSnapshot), site: lastSite.isEmpty ? nil : lastSite,
                           secondsLeft: rule.secondsLeft, safe: rule.isSafe, writing: rule.isWriting,
                           blockMinutes: test ? nil : blockMinutes, blindSince: blindSince,
                           blindBrowser: lastBrowser, watchingBrowser: detection.lastBrowser, today: today,
                           enforcementFailure: enforcementMessage(), activityFailure: activityFailure,
                           onSite: currentSite != nil))
    }

    func saveHealth() {
        RuntimeHealth(pid: getpid(), testMode: test, activity: activityFailure ?? (detection.isBlind ? "BLIND" : "ok"),
                      enforcement: enforcementMessage() ?? "ok",
                      attribution: lastAttribution).save(stateDir: stateDir)
        Heartbeat.beat(stateDir: stateDir)
    }

    func serviceBlocker(now: Date, uptime: Double) {
        guard !blockerBusy else { return }
        let until = test ? nil : enforcement.beginAttempt(at: now, duration: Double(blockMinutes * 60), stateDir: stateDir)
        guard until != nil || uptime - lastPollAt >= 30 else { return }
        blockerBusy = true
        lastPollAt = uptime
        blockerQueue.async {
            let snapshot = until.map { Blocker.ensure(until: $0, stateDir: stateDir) } ?? Blocker.snapshot()
            DispatchQueue.main.async {
                blockerBusy = false
                blockSnapshot = snapshot
                if until != nil {
                    switch enforcement.finishAttempt(snapshot, at: Date(), stateDir: stateDir) {
                    case let .satisfied(end): say("Block verified until \(ISO8601DateFormatter().string(from: end))")
                    case let .retryScheduled(reason): say("Block pending: \(reason)")
                    case .idle: break
                    }
                }
                saveHealth()
                show()
            }
        }
    }

    Detection.mark(blind: false, stateDir: stateDir)
    Grayscale.recover()
    signal(SIGTERM, SIG_IGN)
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    term.setEventHandler { Grayscale.set(false); exit(0) }
    term.resume()
    say("tripwire \(BuildInfo.version) running\(test ? " (test mode: no block)" : "")")
    NSApplication.shared.setActivationPolicy(.accessory)
    show()
    saveHealth()

    let timer = Timer(timeInterval: 1, repeats: true) { _ in
        let uptime = ProcessInfo.processInfo.systemUptime
        if uptime - lastSampleAt > 5 {
            activityFailure = "Browser sampling is stalled; input has not been verified"
            Grayscale.set(false)
        }
        serviceBlocker(now: Date(), uptime: uptime)
        if uptime - lastHealthAt >= 10 {
            lastHealthAt = uptime
            today = EventLog.counts(log.today())
            saveHealth()
        }
        monitor.requestSample { sample in
            lastSampleAt = ProcessInfo.processInfo.systemUptime
            if let attribution = sample.attribution?.summary { lastAttribution = attribution }
            lastBrowser = sample.browser ?? lastBrowser
            let elapsed = sample.elapsed.isFinite && sample.elapsed >= 0 && sample.elapsed <= 10 ? sample.elapsed : 0
            if detection.tick(seconds: elapsed, read: sample.read, browser: sample.browser) {
                blindSince = detection.isBlind ? Date().addingTimeInterval(-Detection.blindAfterSeconds) : nil
                Detection.mark(blind: detection.isBlind, stateDir: stateDir)
                say(detection.isBlind ? "BLIND: browser tab reads failed" : "Browser tab detection recovered")
            }
            if sample.timedOut {
                activityFailure = "Browser observation exceeded 2 s; countdown held"
            } else if !sample.inputHealthy {
                activityFailure = sample.droppedEvents > 0 ? "Input buffer overflow; creation credit withheld" : "Input Monitoring is unavailable"
            } else if case .failed = sample.read {
                activityFailure = "Cannot identify the browser window or tab"
                // Unknown activity preserves the window without guessing site use.
            } else {
                activityFailure = nil
            }
            if case .failed = sample.read {} else { currentSite = sample.site }
            if let site = sample.site { lastSite = site }
            let failedRead: Bool = { if case .failed = sample.read { return true }; return false }()
            let known = !failedRead && sample.inputHealthy
            let protected = verifiedEnd(blockSnapshot) != nil
            let verdict = SessionAccounting.apply(rule: &rule, seconds: elapsed, known: known, protected: protected,
                                                  onWatchedSite: sample.site != nil, keys: sample.keys,
                                                  scrolls: sample.scrolls, composing: sample.composing)
            currentSite = known ? sample.site : nil
            Grayscale.set(known && !protected && currentSite != nil && rule.isWarning)
            switch verdict {
            case .watching: break
            case .pass, .abandon:
                log.append(verdict, site: lastSite, paused: rule.lastPausedSeconds)
                today = EventLog.counts(log.today())
            case .trip:
                log.append(verdict, site: lastSite, paused: rule.lastPausedSeconds)
                if test { say("TRIP (test mode, no block)") }
                else {
                    enforcement.registerTrip(at: Date(), duration: Double(blockMinutes * 60), stateDir: stateDir)
                    say("TRIP: enforcement pending verification")
                    serviceBlocker(now: Date(), uptime: ProcessInfo.processInfo.systemUptime)
                }
                today = EventLog.counts(log.today())
            }
            if sample.attribution != nil { saveHealth() }
            show()
        }
        show()
    }
    RunLoop.main.add(timer, forMode: .common)
    NSApplication.shared.run()
    exit(0)
}

func status() {
    print("tripwire \(BuildInfo.version)")
    let age = Heartbeat.age(stateDir: stateDir)
    print(Heartbeat.describe(age: age))
    if let runtime = RuntimeHealth.load(stateDir: stateDir), let age, age <= Heartbeat.staleSeconds {
        print("installed: \(runtime.version), pid \(runtime.pid), \(runtime.testMode ? "TEST MODE (no blocks)" : "real mode")")
        print("activity: \(runtime.activity)")
        if let attribution = runtime.attribution { print("last scroll attribution: \(attribution)") }
        print("enforcement: \(runtime.enforcement)")
    }
    print(Detection.describe(blindSince: Detection.blindSince(stateDir: stateDir)))
    print(Blocker.canStartUnattended()
          ? "unattended blocks: yes"
          : "unattended blocks: NO. A trip cannot block. Run: sudo scripts/root-setup.sh install")
    let snapshot = Blocker.snapshot()
    if let end = verifiedEnd(snapshot) {
        print("VERIFIED BLOCK until \(end.formatted(date: .omitted, time: .shortened))")
    } else {
        switch snapshot {
        case .inactive: print("no block: sites are open")
        case .unavailable: print("blocker: UNAVAILABLE")
        case let .failed(reason): print("blocker: UNKNOWN (\(reason))")
        case .active: print("blocker: a different or insufficient SelfControl block is active")
        }
    }
    let pending = Enforcement.load(stateDir: stateDir)
    if let request = pending.pending { print("pending trip: \(request.attempts) attempts; \(request.lastFailure ?? "awaiting verification")") }
    if let failure = pending.persistenceFailure { print("enforcement state: \(failure)") }
    let lines = log.today()
    print("today: \(EventLog.counts(lines).summary)")
    lines.suffix(5).forEach { print("  \($0)") }
}

/// Read-only diagnostic. No grayscale changes, verdicts, or SelfControl commands.
func probe(seconds: Double) -> Never {
    guard InputCounter.start() else { print("Input Monitoring permission is missing"); exit(1) }
    let monitor = ActivityMonitor()
    let end = ProcessInfo.processInfo.systemUptime + seconds
    let timer = Timer(timeInterval: 1, repeats: true) { _ in
        if ProcessInfo.processInfo.systemUptime >= end { exit(0) }
        monitor.requestSample { sample in
            let health: String = { if case .failed = sample.read { return "unknown" }; return "ok" }()
            let attribution = sample.attribution.map { " \($0.summary)" } ?? ""
            print("activity site=\(sample.site ?? "none") keys=\(sample.keys) scrolls=\(sample.scrolls) health=\(health) source=\(sample.source.rawValue) window=\(sample.windowID ?? 0) elapsed=\(String(format: "%.2f", sample.elapsed))\(attribution)")
            fflush(stdout)
        }
    }
    RunLoop.main.add(timer, forMode: .common)
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.run()
    exit(0)
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "run" where args.count == 1 || args == ["run", "--test"]: run(test: args.contains("--test"))
case "status" where args.count == 1: status()
case "probe" where args.count <= 2:
    guard let seconds = args.count == 2 ? Double(args[1]) : 15, seconds.isFinite, seconds >= 1, seconds <= 300 else {
        print("probe duration must be between 1 and 300 seconds"); exit(2)
    }
    probe(seconds: seconds)
case "snapshot" where args.count == 2: Snapshot.run(dir: args[1])
case "--version" where args.count == 1: print(BuildInfo.version)
case "--help", nil: print(usage)
default: print(usage); exit(2)
}
