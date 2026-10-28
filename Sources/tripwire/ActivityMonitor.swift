import AppKit
import CoreGraphics
import TripwireCore

/// Joins target-aware input with the exact browser window that received it.
/// Browser automation stays off the main run loop.
final class ActivityMonitor {
    struct AttributionDiagnostic {
        let source: ActivityEvent.TargetSource
        let rawWindowID: UInt32?
        let resolvedWindowID: UInt32?
        let resolvedProcessID: Int32?

        var summary: String {
            "target=\(source.rawValue) raw=\(rawWindowID ?? 0) window=\(resolvedWindowID ?? 0) pid=\(resolvedProcessID ?? 0)"
        }
    }

    struct Sample {
        let elapsed: Double
        let read: Detection.Read
        let browser: String?
        let site: String?
        let composing: Bool
        let keys: Int
        let scrolls: Int
        let inputHealthy: Bool
        let droppedEvents: Int
        let source: ActivitySelector.Selection.Source
        let windowID: UInt32?
        let timedOut: Bool
        let attribution: AttributionDiagnostic?
    }

    private let queue = DispatchQueue(label: "tripwire.activity", qos: .utility)
    private var selector = ActivitySelector()
    private var inFlight = false
    private var clock = TickClock()
    private var lastWatchedBrowser: String?
    private var priorResolvedTargets: [ActivityTarget: ActivityResolution] = [:]
    private var priorObservationStartedAt: Double?
    private var priorFrontTarget: ActivityTarget?
    private var priorWindowInventory: [ActivityWindow]?

    /// Starts one sample if no browser read is active. Completion always runs on main.
    @discardableResult
    func requestSample(_ completion: @escaping (Sample) -> Void) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !inFlight else { return false }
        inFlight = true

        let startedAt = ProcessInfo.processInfo.systemUptime
        let batch = InputCounter.drainBatch()
        let frontContext = ActiveTab.frontContext()
        queue.async { [self] in
            let deadline = startedAt + ActivitySampleBudget.seconds
            let inventory = Self.windowInventory()
            let front = ActiveTab.readFront(frontContext, inventory: inventory, deadline: deadline)

            let attributedEvents = batch.events.map {
                ActivityWindowMatcher.resolveScroll($0, windows: inventory,
                                                    priorWindows: priorWindowInventory)
            }
            priorWindowInventory = inventory
            let rawScroll = batch.events.reversed().first(where: { $0.kind == .scroll })
            let attributedScroll = attributedEvents.reversed().first(where: { $0.kind == .scroll })
            let latestScrollTarget = attributedScroll?.target
            let targetToResolve = latestScrollTarget
                ?? selector.leasedTarget(at: ProcessInfo.processInfo.systemUptime)
            var targetResults: [ActivityTarget: ActiveTab.Result] = [:]
            if let target = targetToResolve {
                if target == front.target {
                    targetResults[target] = front
                } else {
                    targetResults[target] = ActiveTab.readWindow(target, inventory: inventory, deadline: deadline)
                }
            }

            let completedAt = ProcessInfo.processInfo.systemUptime
            let elapsed = clock.elapsed(at: completedAt)
            let completed = ActivitySampleBudget.isComplete(startedAt: startedAt, completedAt: completedAt)
            let inputHealthy = completed && batch.tapEnabled && batch.dropped == 0

            guard completed else {
                priorResolvedTargets = [:]
                priorObservationStartedAt = nil
                let sample = Sample(elapsed: elapsed, read: .failed, browser: front.browser,
                                    site: nil, composing: false, keys: 0, scrolls: 0,
                                    inputHealthy: false, droppedEvents: batch.dropped,
                                    source: .failure, windowID: nil, timedOut: true,
                                    attribution: Self.diagnostic(raw: rawScroll, resolved: attributedScroll))
                DispatchQueue.main.async { [self] in
                    inFlight = false
                    completion(sample)
                }
                return
            }

            let frontActivity = ResolvedActivity(target: front.target, resolution: front.resolution)
            var resolutions = targetResults.mapValues(\.resolution)
            if let frontTarget = front.target { resolutions[frontTarget] = front.resolution }
            let selected = selector.select(now: completedAt, front: frontActivity,
                                           events: attributedEvents, resolvedTargets: resolutions,
                                           priorResolvedTargets: priorResolvedTargets,
                                           priorObservationStartedAt: priorObservationStartedAt,
                                           priorFrontTarget: priorFrontTarget)
            if inputHealthy {
                priorResolvedTargets = resolutions
                priorObservationStartedAt = startedAt
                priorFrontTarget = front.target
            } else {
                priorResolvedTargets = [:]
                priorObservationStartedAt = nil
                priorFrontTarget = nil
            }
            let selectedResult = selected.activity.target.flatMap { targetResults[$0] }
                ?? (selected.activity.target == front.target ? front : nil)

            let fields = Self.fields(for: selected.activity.resolution)
            let browser = selectedResult?.browser ?? fields.browser ?? lastWatchedBrowser
            if case .watched = selected.activity.resolution, let browser { lastWatchedBrowser = browser }
            let sample = Sample(
                elapsed: elapsed,
                read: selectedResult?.read ?? fields.read,
                browser: browser,
                site: fields.site,
                composing: fields.composing,
                keys: inputHealthy ? selected.keys : 0,
                scrolls: inputHealthy ? selected.scrolls : 0,
                inputHealthy: inputHealthy,
                droppedEvents: batch.dropped,
                source: selected.source,
                windowID: selected.activity.target?.windowID,
                timedOut: false,
                attribution: Self.diagnostic(raw: rawScroll, resolved: attributedScroll)
            )
            DispatchQueue.main.async { [self] in
                inFlight = false
                completion(sample)
            }
        }
        return true
    }

    private static func fields(for resolution: ActivityResolution)
        -> (read: Detection.Read, browser: String?, site: String?, composing: Bool) {
        switch resolution {
        case let .watched(site, composing):
            // A lease stores the matched domain only, never the full URL.
            return (.url("https://\(site)"), nil, site, composing)
        case .unwatchedBrowser:
            return (.url("https://unwatched.invalid"), nil, nil, false)
        case .nonBrowser:
            return (.notBrowser, nil, nil, false)
        case let .failed(browser):
            return (.failed, browser, nil, false)
        }
    }

    private static func diagnostic(raw: ActivityEvent?, resolved: ActivityEvent?) -> AttributionDiagnostic? {
        guard let resolved else { return nil }
        return AttributionDiagnostic(source: resolved.targetSource,
                                     rawWindowID: raw?.target.windowID,
                                     resolvedWindowID: resolved.target.windowID,
                                     resolvedProcessID: resolved.target.processID)
    }

    private static func windowInventory() -> [ActivityWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [NSDictionary] else {
            return []
        }
        return raw.prefix(512).compactMap { item in
            guard let number = item[kCGWindowNumber] as? NSNumber,
                  let owner = item[kCGWindowOwnerPID] as? NSNumber,
                  let rawBounds = item[kCGWindowBounds] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
                  number.uint64Value <= UInt64(UInt32.max) else { return nil }
            return ActivityWindow(
                target: .init(windowID: number.uint32Value, processID: owner.int32Value),
                bounds: .init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
            )
        }
    }
}
