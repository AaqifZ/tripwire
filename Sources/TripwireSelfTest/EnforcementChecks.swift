import Foundation
import TripwireCore

func runEnforcementChecks() {
    let settings = """
    2026-10-26 12:00:00.000 selfcontrol-cli[12:34] debug noise
    2026-10-26 12:00:00.001 selfcontrol-cli[12:34] {
        ActiveBlockAsWhitelist = 0;
        ActiveBlocklist =     (
            "x.com",
            "twitter.com",
            "linkedin.com",
            "reddit.com",
            "instagram.com",
            "www.x.com",
            "www.twitter.com",
            "www.linkedin.com",
            "www.reddit.com",
            "www.instagram.com",
            "mobile.twitter.com",
            "mobile.x.com",
            "old.reddit.com",
            "new.reddit.com"
        );
        BlockEndDate = "2026-10-26 14:00:00 +0000";
        BlockIsRunning = 1;
    }
    """
    let required = makeDate("2026-10-26 13:59:59 +0000")!
    if case let .active(block) = Blocker.parseSettings(settings) {
        check(block.covers(requiredDomains: Sites.blocklist, until: required),
              "SelfControl settings parser verifies all required domains and expiry")
        check(!ActiveBlock(endDate: block.endDate, domains: ["x.com"], isAllowlist: false)
            .covers(requiredDomains: Sites.blocklist, until: required),
              "an unrelated partial block does not satisfy enforcement")
        check(!ActiveBlock(endDate: block.endDate, domains: Sites.blocklist, isAllowlist: true)
            .covers(requiredDomains: Sites.blocklist, until: required),
              "an allowlist is not guessed to satisfy enforcement")
        check(!block.covers(requiredDomains: Sites.blocklist,
                            until: block.endDate.addingTimeInterval(1)),
              "a short block does not satisfy enforcement")
    } else {
        check(false, "SelfControl settings parser verifies all required domains and expiry")
    }
    check(Blocker.parseSettings("noise BlockIsRunning = 0;") == .inactive,
          "inactive SelfControl settings are explicit")
    if case .failed = Blocker.parseSettings("noise") {
        check(true, "malformed SelfControl settings fail closed")
    } else {
        check(false, "malformed SelfControl settings fail closed")
    }

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tripwire-enforcement-\(UUID())")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let fakeCLI = dir.appendingPathComponent("selfcontrol-fixture")
    let fixtureState = dir.appendingPathComponent("fixture-active")
    let fixtureCalls = dir.appendingPathComponent("fixture-starts")
    let fixture = fakeSelfControl(state: fixtureState.path, calls: fixtureCalls.path, exitAfterStart: 0)
    try? Data(fixture.utf8).write(to: fakeCLI, options: .atomic)
    chmod(fakeCLI.path, 0o700)
    let fixtureRequired = makeDate("2026-10-26 13:59:59 +0000")!
    let allowSudo = dir.appendingPathComponent("sudo-allow")
    try? Data(fakeSudo(allow: true).utf8).write(to: allowSudo, options: .atomic)
    chmod(allowSudo.path, 0o700)
    let fakeRoot = dir.appendingPathComponent("tripwire-block-to-fixture")
    try? Data(rootBlockRunning(fakeCLI.path).utf8).write(to: fakeRoot, options: .atomic)
    chmod(fakeRoot.path, 0o700)
    // This fixture verifies policy and readback, not process scheduling speed.
    // Production allows 15 s. Timeout behavior has a dedicated test below.
    let fixtureTimeout: TimeInterval = 5
    let ensured = Blocker.ensure(until: fixtureRequired, stateDir: dir,
                                 cliPath: fakeCLI.path, sudoPath: allowSudo.path, rootBlockPath: fakeRoot.path, timeout: fixtureTimeout)
    if case let .active(block) = ensured {
        check(block.covers(requiredDomains: Sites.blocklist, until: fixtureRequired),
              "block start is followed by an effective-policy readback")
    } else {
        print("DETAIL fixture ensure: \(ensured)")
        check(false, "block start is followed by an effective-policy readback")
    }
    _ = Blocker.ensure(until: fixtureRequired, stateDir: dir,
                       cliPath: fakeCLI.path, sudoPath: allowSudo.path, rootBlockPath: fakeRoot.path, timeout: fixtureTimeout)
    let startCalls = (try? String(contentsOf: fixtureCalls, encoding: .utf8)) ?? ""
    check(startCalls == "start\n", "an active block is observed without a second start command")

    let racedCLI = dir.appendingPathComponent("selfcontrol-race-fixture")
    let racedState = dir.appendingPathComponent("race-active")
    let racedCalls = dir.appendingPathComponent("race-starts")
    let racedFixture = fakeSelfControl(state: racedState.path, calls: racedCalls.path, exitAfterStart: 78)
    try? Data(racedFixture.utf8).write(to: racedCLI, options: .atomic)
    chmod(racedCLI.path, 0o700)
    let racedRoot = dir.appendingPathComponent("tripwire-block-to-race")
    try? Data(rootBlockRunning(racedCLI.path).utf8).write(to: racedRoot, options: .atomic)
    chmod(racedRoot.path, 0o700)
    let raced = Blocker.ensure(until: fixtureRequired, stateDir: dir,
                               cliPath: racedCLI.path, sudoPath: allowSudo.path, rootBlockPath: racedRoot.path, timeout: fixtureTimeout)
    if case .active = raced {
        check(true, "a nonzero start still accepts verified effective state")
    } else {
        print("DETAIL raced ensure: \(raced)")
        check(false, "a nonzero start still accepts verified effective state")
    }

    // Unattended path: a permitted sudo rule routes the start through the
    // root script with only the end date, and the user-level CLI is never used.
    let rootBlock = dir.appendingPathComponent("tripwire-block-fixture")
    let rootState = dir.appendingPathComponent("root-active")
    let rootCalls = dir.appendingPathComponent("root-starts")
    try? Data(fakeRootBlock(state: rootState.path, calls: rootCalls.path).utf8).write(to: rootBlock, options: .atomic)
    chmod(rootBlock.path, 0o700)
    let userCLI = dir.appendingPathComponent("selfcontrol-user-fixture")
    let userCalls = dir.appendingPathComponent("user-starts")
    try? Data(fakeSelfControl(state: rootState.path, calls: userCalls.path, exitAfterStart: 0).utf8)
        .write(to: userCLI, options: .atomic)
    chmod(userCLI.path, 0o700)
    let rooted = Blocker.ensure(until: fixtureRequired, stateDir: dir, cliPath: userCLI.path,
                                sudoPath: allowSudo.path, rootBlockPath: rootBlock.path, timeout: fixtureTimeout)
    let rootStarts = (try? String(contentsOf: rootCalls, encoding: .utf8)) ?? ""
    let userStarts = (try? String(contentsOf: userCalls, encoding: .utf8)) ?? ""
    if case .active = rooted {
        check(rootStarts == "start 2026-10-26T13:59:59Z\n" && userStarts.isEmpty,
              "a permitted sudo rule starts the block as root with no dialog path")
    } else {
        print("DETAIL rooted ensure: \(rooted) root=\(rootStarts) user=\(userStarts)")
        check(false, "a permitted sudo rule starts the block as root with no dialog path")
    }

    let denySudo = dir.appendingPathComponent("sudo-deny")
    try? Data(fakeSudo(allow: false).utf8).write(to: denySudo, options: .atomic)
    chmod(denySudo.path, 0o700)
    let noRuleCalls = dir.appendingPathComponent("no-rule-starts")
    let noRuleCLI = dir.appendingPathComponent("selfcontrol-no-rule-fixture")
    try? Data(fakeSelfControl(state: dir.appendingPathComponent("no-rule-active").path, calls: noRuleCalls.path,
                              exitAfterStart: 0).utf8).write(to: noRuleCLI, options: .atomic)
    chmod(noRuleCLI.path, 0o700)
    let noRule = Blocker.ensure(until: fixtureRequired, stateDir: dir, cliPath: noRuleCLI.path,
                                sudoPath: denySudo.path, rootBlockPath: rootBlock.path, timeout: fixtureTimeout)
    let noRuleStarts = (try? String(contentsOf: noRuleCalls, encoding: .utf8)) ?? ""
    if case .failed = noRule, noRuleStarts.isEmpty {
        check(true, "a missing sudo rule fails visibly and never runs the dialog CLI")
    } else {
        print("DETAIL no-rule ensure: \(noRule) starts=\(noRuleStarts)")
        check(false, "a missing sudo rule fails visibly and never runs the dialog CLI")
    }
    check(Blocker.unattendedCommand(end: "2026-10-26T13:59:59Z", sudoPath: allowSudo.path,
                                    rootBlockPath: dir.appendingPathComponent("absent").path,
                                    timeout: fixtureTimeout) == nil,
          "a missing root script yields no unattended command")

    let now = Date(timeIntervalSince1970: 1_000.25)
    var enforcement = Enforcement()
    enforcement.registerTrip(at: now, duration: 60, stateDir: dir)
    check(enforcement.pending?.requiredUntil.timeIntervalSince1970 == 1_061,
          "fractional trip time rounds the required end up to a CLI-safe second")
    let firstRequired = enforcement.beginAttempt(at: now, duration: 60, stateDir: dir)
    check(firstRequired == enforcement.pending?.requiredUntil && enforcement.isAttemptInFlight,
          "a pending trip begins one enforcement attempt")
    let first = enforcement.finishAttempt(.failed("fixture failure"), at: now, stateDir: dir)
    check(first == .retryScheduled("fixture failure") && enforcement.pending?.attempts == 1,
          "a failed block remains pending with retry state")
    check(enforcement.beginAttempt(at: now.addingTimeInterval(4), duration: 60, stateDir: dir) == nil,
          "retry backoff prevents a tight helper loop")

    var restored = Enforcement.load(stateDir: dir)
    check(restored.pending == enforcement.pending && !restored.isAttemptInFlight,
          "a pending block request survives process restart")
    let retryAt = restored.pending!.nextAttemptAt
    _ = restored.beginAttempt(at: retryAt, duration: 60, stateDir: dir)
    let partial = ActiveBlock(endDate: restored.pending!.requiredUntil.addingTimeInterval(10),
                              domains: ["x.com"], isAllowlist: false)
    _ = restored.finishAttempt(.active(partial), at: retryAt, stateDir: dir)
    check(restored.pending != nil && restored.pending?.lastFailure?.contains("does not cover") == true,
          "an unrelated active block leaves the trip pending")

    let finalRetry = restored.pending!.nextAttemptAt
    let requiredEnd = restored.beginAttempt(at: finalRetry, duration: 60, stateDir: dir)!
    let full = ActiveBlock(endDate: requiredEnd, domains: Sites.blocklist, isAllowlist: false)
    check(restored.finishAttempt(.active(full), at: finalRetry, stateDir: dir) == .satisfied(until: requiredEnd),
          "only a verified full-duration block satisfies enforcement")
    check(restored.pending == nil && Enforcement.load(stateDir: dir).pending == nil,
          "satisfied enforcement clears durable pending state")

    var overdue = Enforcement()
    overdue.registerTrip(at: now, duration: 1, stateDir: dir)
    let late = now.addingTimeInterval(10)
    let rebased = overdue.beginAttempt(at: late, duration: 60, stateDir: dir)!
    check(rebased.timeIntervalSince1970 == ceil(late.addingTimeInterval(60).timeIntervalSince1970),
          "an expired pending request receives one fresh full block period")
    _ = overdue.finishAttempt(.inactive, at: late, stateDir: dir)
    let fixed = overdue.pending!.requiredUntil
    _ = overdue.beginAttempt(at: overdue.pending!.nextAttemptAt, duration: 60, stateDir: dir)
    check(overdue.pending?.requiredUntil == fixed,
          "ordinary retries do not slide the required block end")

    if FileManager.default.isExecutableFile(atPath: "/usr/bin/printf") {
        let result = ProcessRunner.run(executable: "/usr/bin/printf",
                                       arguments: ["%s", String(repeating: "x", count: 100)],
                                       timeout: 1, maxOutputBytes: 16)
        check(result == .outputLimitExceeded(output: String(repeating: "x", count: 16)),
              "process output is bounded")
    }
    if FileManager.default.isExecutableFile(atPath: "/usr/bin/yes") {
        let started = Date()
        let result = ProcessRunner.run(executable: "/usr/bin/yes", arguments: [],
                                       timeout: 2, maxOutputBytes: 1024)
        if case let .outputLimitExceeded(output) = result {
            check(output.utf8.count == 1024 && Date().timeIntervalSince(started) < 1.5,
                  "output flood stops at the byte limit")
        } else {
            check(false, "output flood stops at the byte limit")
        }
    }
    if FileManager.default.isExecutableFile(atPath: "/bin/sleep") {
        let started = Date()
        let result = ProcessRunner.run(executable: "/bin/sleep", arguments: ["2"], timeout: 0.05)
        if case .timedOut = result {
            check(Date().timeIntervalSince(started) < 1.5, "process timeout returns without waiting for normal exit")
        } else {
            check(false, "process timeout returns without waiting for normal exit")
        }
    }

    let script = dir.appendingPathComponent("inherited-output.sh")
    let source = "#!/bin/sh\n(sleep 2) &\nprintf done\n"
    try? Data(source.utf8).write(to: script, options: .atomic)
    chmod(script.path, 0o700)
    let inheritedStarted = Date()
    let inherited = ProcessRunner.run(executable: script.path, arguments: [], timeout: 1)
    check(inherited == .completed(exitCode: 0, output: "done", truncated: false)
          && Date().timeIntervalSince(inheritedStarted) < 1,
          "a descendant holding stdout open cannot hold the runner")
}

private func makeDate(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    return formatter.date(from: value)
}

private func fakeSelfControl(state: String, calls: String, exitAfterStart: Int32) -> String {
    let state = state.replacingOccurrences(of: "'", with: "'\"'\"'")
    let calls = calls.replacingOccurrences(of: "'", with: "'\"'\"'")
    let domains = Sites.blocklist.map { "\"\($0)\"" }.joined(separator: ", ")
    return """
    #!/bin/sh
    state='\(state)'
    calls='\(calls)'
    case "$1" in
      print-settings)
        if [ -f "$state" ]; then
          printf '%s\\n' '{ ActiveBlockAsWhitelist = 0; ActiveBlocklist = (\(domains)); BlockEndDate = "2099-01-01 00:00:00 +0000"; BlockIsRunning = 1; }'
        else
          printf '%s\\n' '{ BlockIsRunning = 0; }'
        fi
        ;;
      start)
        printf 'start\\n' >> "$calls"
        : > "$state"
        exit \(exitAfterStart)
        ;;
      *) exit 64 ;;
    esac
    """
}

/// Mimics `sudo -n`: `-l` answers whether the rule permits the command,
/// otherwise the command runs. A denied rule exits 1 like real sudo.
private func fakeSudo(allow: Bool) -> String {
    """
    #!/bin/sh
    [ "$1" = "-n" ] || exit 1
    shift
    \(allow ? "" : "exit 1")
    if [ "$1" = "-l" ]; then exit 0; fi
    exec "$@"
    """
}

/// Mimics the installed root script: it takes only the end date.
private func fakeRootBlock(state: String, calls: String) -> String {
    let state = state.replacingOccurrences(of: "'", with: "'\"'\"'")
    let calls = calls.replacingOccurrences(of: "'", with: "'\"'\"'")
    return """
    #!/bin/sh
    [ $# -eq 1 ] || exit 64
    printf 'start %s\\n' "$1" >> '\(calls)'
    : > '\(state)'
    """
}

/// Stands in for the installed root script: passes the end date to a fake CLI.
private func rootBlockRunning(_ cli: String) -> String {
    let cli = cli.replacingOccurrences(of: "'", with: "'\"'\"'")
    return """
    #!/bin/sh
    [ $# -eq 1 ] || exit 64
    exec '\(cli)' start --enddate "$1"
    """
}
