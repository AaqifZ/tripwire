import TripwireCore

func runActivityChecks() {
    let slack = ActivityTarget(windowID: 10, processID: 100)
    let x = ActivityTarget(windowID: 20, processID: 200)
    let xSecondWindow = ActivityTarget(windowID: 21, processID: 200)
    let frontSlack = ResolvedActivity(target: slack, resolution: .nonBrowser)
    let frontX = ResolvedActivity(target: x, resolution: .watched(site: "x.com", composing: false))

    let exact = ActivityWindowMatcher.uniqueMatch(
        bounds: .init(x: 5, y: 8, width: 500, height: 700),
        candidates: [.init(x: 5, y: 8, width: 500, height: 700), .init(x: 700, y: 8, width: 500, height: 700)]
    )
    check(exact == 0, "activity: exact bounds select one browser window")
    let ambiguous = ActivityWindowMatcher.uniqueMatch(
        bounds: .init(x: 5, y: 8, width: 500, height: 700),
        candidates: [.init(x: 5, y: 8, width: 500, height: 700), .init(x: 6, y: 8, width: 500, height: 700)]
    )
    check(ambiguous == nil, "activity: ambiguous browser bounds fail closed")

    let windowInventory = [
        ActivityWindow(target: slack, bounds: .init(x: 600, y: 0, width: 600, height: 800)),
        ActivityWindow(target: x, bounds: .init(x: 0, y: 0, width: 600, height: 800)),
    ]
    let missingRawWindow = ActivityEvent(kind: .scroll,
                                         target: .init(windowID: nil, processID: 100),
                                         timestamp: 9, pointer: .init(x: 200, y: 300),
                                         targetSource: .processOnly)
    let pointerResolved = ActivityWindowMatcher.resolveScroll(
        missingRawWindow, windows: windowInventory, priorWindows: windowInventory
    )
    check(pointerResolved.target == x && pointerResolved.targetSource == .pointerHitTest,
          "activity: pointer hit-test recovers background X when the event window is missing")
    let staleRawWindow = ActivityEvent(kind: .scroll, target: slack, timestamp: 9,
                                       pointer: .init(x: 200, y: 300), targetSource: .eventWindow)
    let staleResolved = ActivityWindowMatcher.resolveScroll(staleRawWindow, windows: windowInventory)
    check(staleResolved.target == ActivityTarget(windowID: nil, processID: nil)
              && staleResolved.targetSource == .unknown,
          "activity: a conflicting event window fails closed instead of blaming exposed X")
    let validRawWindow = ActivityEvent(kind: .scroll, target: x, timestamp: 9,
                                       pointer: .init(x: 200, y: 300), targetSource: .eventWindow)
    check(ActivityWindowMatcher.resolveScroll(validRawWindow, windows: windowInventory).targetSource == .eventWindow,
          "activity: a valid event window remains authoritative")
    let overlapping = [
        ActivityWindow(target: slack, bounds: .init(x: 0, y: 0, width: 500, height: 500)),
        ActivityWindow(target: x, bounds: .init(x: 0, y: 0, width: 500, height: 500)),
    ]
    check(ActivityWindowMatcher.hitTest(point: .init(x: 50, y: 50), windows: overlapping)?.target == slack,
          "activity: pointer hit-test respects front-to-back window order")
    let negativeScreen = [
        ActivityWindow(target: x, bounds: .init(x: -1_200, y: -200, width: 900, height: 800)),
    ]
    check(ActivityWindowMatcher.hitTest(point: .init(x: -600, y: 100), windows: negativeScreen)?.target == x,
          "activity: pointer hit-test supports displays with negative coordinates")
    let changedInventory = [
        ActivityWindow(target: x, bounds: .init(x: 0, y: 0, width: 600, height: 800)),
    ]
    let priorOccluded = [
        ActivityWindow(target: slack, bounds: .init(x: 0, y: 0, width: 600, height: 800)),
        ActivityWindow(target: x, bounds: .init(x: 0, y: 0, width: 600, height: 800)),
    ]
    let movedBetweenSamples = ActivityWindowMatcher.resolveScroll(
        missingRawWindow, windows: changedInventory, priorWindows: priorOccluded
    )
    check(movedBetweenSamples.target == ActivityTarget(windowID: nil, processID: nil)
              && movedBetweenSamples.targetSource == .unknown,
          "activity: a no-ID event fails closed when the top window changed")
    let noHit = ActivityWindowMatcher.resolveScroll(
        .init(kind: .scroll, target: x, timestamp: 9,
              pointer: .init(x: 2_000, y: 2_000), targetSource: .eventWindow),
        windows: windowInventory
    )
    check(noHit.target == ActivityTarget(windowID: nil, processID: nil)
              && noHit.targetSource == .unknown,
          "activity: a rejected raw target with no pointer hit clears unproven identity")

    var selector = ActivitySelector(leaseSeconds: 2)
    var selected = selector.select(
        now: 10,
        front: frontSlack,
        events: [
            .init(kind: .typing, target: slack, timestamp: 9.8),
            pointerResolved,
        ],
        resolvedTargets: [x: .watched(site: "x.com", composing: false)]
    )
    check(selected.activity == ResolvedActivity(target: x, resolution: .watched(site: "x.com", composing: false)),
          "activity: background X scroll wins while Slack is front")
    check(selected.keys == 0 && selected.scrolls == 1,
          "activity: Slack typing never earns credit on background X")

    selected = selector.select(now: 11.5, front: frontSlack, events: [], resolvedTargets: [:])
    check(selected.activity.target == x, "activity: a short hover-scroll lease bridges event gaps")
    selected = selector.select(now: 12.1, front: frontSlack, events: [], resolvedTargets: [:])
    check(selected.activity == frontSlack, "activity: a stale hover-scroll lease expires")

    selector = ActivitySelector(leaseSeconds: 2)
    _ = selector.select(now: 20, front: frontSlack,
                        events: [.init(kind: .scroll, target: x, timestamp: 20)],
                        resolvedTargets: [x: .watched(site: "x.com", composing: false)])
    selected = selector.select(now: 20.5, front: frontSlack,
                               events: [.init(kind: .scroll, target: slack, timestamp: 20.5)],
                               resolvedTargets: [slack: .nonBrowser])
    check(selected.activity == frontSlack, "activity: scrolling Slack ends the background X lease")

    selector = ActivitySelector()
    selected = selector.select(now: 25, front: frontX,
                               events: [.init(kind: .scroll, target: slack, timestamp: 25)],
                               resolvedTargets: [slack: .nonBrowser])
    check(selected.activity == ResolvedActivity(target: slack, resolution: .nonBrowser),
          "activity: a background Slack scroll does not count against frontmost X")

    selector = ActivitySelector()
    selected = selector.select(
        now: 30.5,
        front: frontX,
        events: [.init(kind: .typing, target: .init(windowID: nil, processID: 200), timestamp: 30.25)],
        resolvedTargets: [x: .watched(site: "x.com", composing: false)],
        priorResolvedTargets: [x: .watched(site: "x.com", composing: false)],
        priorObservationStartedAt: 30,
        priorFrontTarget: x
    )
    check(selected.keys == 1, "activity: stable typing in the exact watched browser window counts")

    selector = ActivitySelector()
    selected = selector.select(
        now: 35,
        front: frontX,
        events: [
            .init(kind: .typing, target: .init(windowID: nil, processID: 200), timestamp: 34.8),
            .init(kind: .scroll, target: x, timestamp: 34.9),
        ],
        resolvedTargets: [x: .watched(site: "x.com", composing: false)],
        priorResolvedTargets: [x: .watched(site: "x.com", composing: false)],
        priorObservationStartedAt: 34,
        priorFrontTarget: x
    )
    check(selected.keys == 1 && selected.scrolls == 1,
          "activity: typing and scrolling in the same stable front X window both count")

    selector = ActivitySelector()
    selected = selector.select(
        now: 40,
        front: ResolvedActivity(target: xSecondWindow, resolution: .watched(site: "x.com", composing: false)),
        events: [
            .init(kind: .scroll, target: x, timestamp: 39.9),
            .init(kind: .typing, target: xSecondWindow, timestamp: 40),
        ],
        resolvedTargets: [x: .watched(site: "x.com", composing: false),
                          xSecondWindow: .watched(site: "x.com", composing: false)],
        priorResolvedTargets: [xSecondWindow: .watched(site: "x.com", composing: false)],
        priorObservationStartedAt: 39
    )
    check(selected.activity.target == x && selected.keys == 0,
          "activity: typing in another window of the same browser does not credit hovered X")

    selector = ActivitySelector()
    selected = selector.select(
        now: 50,
        front: frontSlack,
        events: [.init(kind: .scroll, target: x, timestamp: 50)],
        resolvedTargets: [:]
    )
    check(selected.activity.resolution == .failed(browser: nil),
          "activity: an unresolved scroll target fails visibly")

    selector = ActivitySelector(leaseSeconds: 2)
    _ = selector.select(
        now: 60,
        front: frontSlack,
        events: [.init(kind: .scroll, target: x, timestamp: 60)],
        resolvedTargets: [x: .watched(site: "x.com", composing: true)]
    )
    selected = selector.select(now: 61, front: frontSlack, events: [],
                               resolvedTargets: [x: .watched(site: "x.com", composing: false)])
    check(selected.activity.resolution == .watched(site: "x.com", composing: false),
          "activity: a leased browser window refreshes its composer state")

    selector = ActivitySelector(maxEventAge: 2)
    selected = selector.select(
        now: 70,
        front: frontSlack,
        events: [.init(kind: .scroll, target: x, timestamp: 60)],
        resolvedTargets: [x: .watched(site: "x.com", composing: false)]
    )
    check(selected.activity == frontSlack && selected.scrolls == 0,
          "activity: stale input cannot be credited after a delayed tab read")

    selector = ActivitySelector()
    selected = selector.select(
        now: 80,
        front: frontX,
        events: [.init(kind: .typing, target: .init(windowID: nil, processID: 200), timestamp: 79.8)],
        resolvedTargets: [x: .watched(site: "x.com", composing: false)],
        priorResolvedTargets: [x: .unwatchedBrowser],
        priorObservationStartedAt: 79,
        priorFrontTarget: x
    )
    check(selected.keys == 0, "activity: a tab switch into X cannot inherit prior typing")
    selected = selector.select(
        now: 81,
        front: frontX,
        events: [.init(kind: .typing, target: .init(windowID: nil, processID: 200), timestamp: 80.8)],
        resolvedTargets: [x: .watched(site: "x.com", composing: false)],
        priorResolvedTargets: [x: .watched(site: "x.com", composing: false)],
        priorObservationStartedAt: 80,
        priorFrontTarget: x
    )
    check(selected.keys == 1, "activity: typing counts after the exact tab stays watched")

    selector = ActivitySelector()
    selected = selector.select(
        now: 90,
        front: frontX,
        events: [.init(kind: .typing, target: .init(windowID: nil, processID: 200), timestamp: 89.8)],
        resolvedTargets: [x: .watched(site: "x.com", composing: false)]
    )
    check(selected.keys == 0, "activity: the first browser sample withholds uncertain typing")

    check(!ActivitySampleBudget.isComplete(startedAt: 100, completedAt: 102.01),
          "activity: a slow successful browser read is an incomplete sample")
    selector = ActivitySelector(maxEventAge: 2)
    selected = selector.select(
        now: 102.5,
        front: frontSlack,
        events: [.init(kind: .scroll, target: x, timestamp: 100.5)],
        resolvedTargets: [x: .watched(site: "x.com", composing: false)],
        priorResolvedTargets: [x: .watched(site: "x.com", composing: false)],
        priorObservationStartedAt: 100
    )
    check(selected.activity.target == x && selected.scrolls == 1,
          "activity: input queued during the prior query survives the next delayed read")
    var heldRule = Rule(config: .init(writingKeys: .max))
    _ = heldRule.tick(seconds: 299, onWatchedSite: true, keys: 0, scrolls: 50)
    let heldVerdict = SessionAccounting.apply(rule: &heldRule, seconds: 3, known: false, protected: false,
                                              onWatchedSite: false, keys: 0, scrolls: 0, composing: false)
    check(heldVerdict == .watching && heldRule.onSiteSeconds == 299,
          "activity: an over-budget read causes neither an away reset nor a false trip")
}
