import Foundation

/// The minimum identity retained for one input event. URLs and window titles are never stored.
public struct ActivityTarget: Hashable, Sendable {
    public let windowID: UInt32?
    public let processID: Int32?

    public init(windowID: UInt32?, processID: Int32?) {
        self.windowID = windowID
        self.processID = processID
    }
}

public struct ActivityEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case typing, scroll }
    public enum TargetSource: String, Equatable, Sendable {
        case eventWindow
        case pointerHitTest
        case processOnly
        case unknown
    }

    public let kind: Kind
    public let target: ActivityTarget
    public let timestamp: Double
    public let pointer: ActivityPoint?
    public let targetSource: TargetSource

    public init(kind: Kind, target: ActivityTarget, timestamp: Double,
                pointer: ActivityPoint? = nil, targetSource: TargetSource = .unknown) {
        self.kind = kind
        self.target = target
        self.timestamp = timestamp
        self.pointer = pointer
        self.targetSource = targetSource
    }

    public func retargeted(_ target: ActivityTarget, source: TargetSource) -> ActivityEvent {
        ActivityEvent(kind: kind, target: target, timestamp: timestamp,
                      pointer: pointer, targetSource: source)
    }
}

public struct ActivityPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A window rectangle in the shared top-left-origin screen coordinate space.
public struct ActivityBounds: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public func approximatelyEquals(_ other: ActivityBounds, tolerance: Double = 3) -> Bool {
        abs(x - other.x) <= tolerance
            && abs(y - other.y) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }

    public func contains(_ point: ActivityPoint) -> Bool {
        point.x >= x && point.x < x + width && point.y >= y && point.y < y + height
    }
}

public struct ActivityWindow: Equatable, Sendable {
    public let target: ActivityTarget
    public let bounds: ActivityBounds

    public init(target: ActivityTarget, bounds: ActivityBounds) {
        self.target = target
        self.bounds = bounds
    }
}

/// A browser observation is all-or-nothing. Slow partial reads cannot silently
/// discard input and then advance the rule as a healthy zero-key interval.
public enum ActivitySampleBudget {
    public static let seconds: Double = 2

    public static func isComplete(startedAt: Double, completedAt: Double,
                                  limit: Double = seconds) -> Bool {
        startedAt.isFinite && completedAt.isFinite && limit > 0
            && completedAt >= startedAt && completedAt - startedAt <= limit
    }
}

/// Pure matching used between WindowServer windows and browser-script windows.
public enum ActivityWindowMatcher {
    /// Returns the only matching index. Missing and ambiguous bounds both return nil.
    public static func uniqueMatch(bounds: ActivityBounds, candidates: [ActivityBounds], tolerance: Double = 3) -> Int? {
        let matches = candidates.indices.filter { candidates[$0].approximatelyEquals(bounds, tolerance: tolerance) }
        return matches.count == 1 ? matches[0] : nil
    }

    /// WindowServer returns windows front-to-back. The first layer-0 rectangle
    /// containing the event point is the window that can receive that scroll.
    public static func hitTest(point: ActivityPoint, windows: [ActivityWindow]) -> ActivityWindow? {
        windows.first { $0.bounds.contains(point) }
    }

    /// Trust a raw event window only when it exists under the recorded pointer.
    /// With no raw ID, require the same frontmost target before and after the event.
    public static func resolveScroll(_ event: ActivityEvent,
                                     windows: [ActivityWindow],
                                     priorWindows: [ActivityWindow]? = nil) -> ActivityEvent {
        guard event.kind == .scroll, let pointer = event.pointer else { return event }
        if let rawID = event.target.windowID {
            guard let raw = windows.first(where: { $0.target.windowID == rawID }),
                  raw.bounds.contains(pointer) else {
                return event.retargeted(ActivityTarget(windowID: nil, processID: nil), source: .unknown)
            }
            return event.retargeted(raw.target, source: .eventWindow)
        }
        if let priorWindows,
           let priorHit = hitTest(point: pointer, windows: priorWindows),
           let hit = hitTest(point: pointer, windows: windows),
           priorHit.target == hit.target {
            return event.retargeted(hit.target, source: .pointerHitTest)
        }
        return event.retargeted(ActivityTarget(windowID: nil, processID: nil), source: .unknown)
    }
}

/// The in-memory result of resolving a window. It contains only a watched-domain match.
public enum ActivityResolution: Equatable, Sendable {
    case watched(site: String, composing: Bool)
    case unwatchedBrowser
    case nonBrowser
    case failed(browser: String?)
}

public struct ResolvedActivity: Equatable, Sendable {
    public let target: ActivityTarget?
    public let resolution: ActivityResolution

    public init(target: ActivityTarget?, resolution: ActivityResolution) {
        self.target = target
        self.resolution = resolution
    }
}

/// Selects the activity that owns one rule tick and attributes only its input.
public struct ActivitySelector: Sendable {
    public struct Selection: Equatable, Sendable {
        public enum Source: String, Equatable, Sendable { case front, hover, lease, none, failure }

        public let activity: ResolvedActivity
        public let keys: Int
        public let scrolls: Int
        public let source: Source

        public init(activity: ResolvedActivity, keys: Int, scrolls: Int, source: Source) {
            self.activity = activity
            self.keys = keys
            self.scrolls = scrolls
            self.source = source
        }
    }

    private struct Lease: Sendable {
        let activity: ResolvedActivity
        let expiresAt: Double
    }

    public let leaseSeconds: Double
    public let maxEventAge: Double
    private var lease: Lease?

    public init(leaseSeconds: Double = 2, maxEventAge: Double = 4) {
        self.leaseSeconds = leaseSeconds
        self.maxEventAge = maxEventAge
    }

    public func leasedTarget(at now: Double) -> ActivityTarget? {
        guard let lease, lease.expiresAt >= now else { return nil }
        return lease.activity.target
    }

    /// A watched scroll under the pointer wins over an unrelated front app.
    /// Otherwise a watched front browser wins, followed by a short scroll lease.
    public mutating func select(
        now: Double,
        front: ResolvedActivity,
        events: [ActivityEvent],
        resolvedTargets: [ActivityTarget: ActivityResolution],
        priorResolvedTargets: [ActivityTarget: ActivityResolution] = [:],
        priorObservationStartedAt: Double? = nil,
        priorFrontTarget: ActivityTarget? = nil
    ) -> Selection {
        // After the first observation, its drain time is the trust boundary.
        // This keeps a valid event through a bounded slow read without accepting
        // input that was already waiting before the prior observation began.
        let eventCutoff = priorObservationStartedAt ?? now - maxEventAge
        let freshEvents = events.filter { $0.timestamp > eventCutoff && $0.timestamp <= now }
        let latestScroll = freshEvents.reversed().first { $0.kind == .scroll }
        let scrollActivity = latestScroll.map { event in
            ResolvedActivity(target: event.target,
                             resolution: resolvedTargets[event.target] ?? .failed(browser: nil))
        }

        let selected: ResolvedActivity
        let source: Selection.Source
        if let scrollActivity, case .watched = scrollActivity.resolution {
            selected = scrollActivity
            source = .hover
            lease = Lease(activity: scrollActivity, expiresAt: now + leaseSeconds)
        } else if let scrollActivity {
            // Any proven scroll belongs to its receiving window, even when another
            // browser remains frontmost. It also ends the prior browser-window lease.
            lease = nil
            selected = scrollActivity
            source = scrollActivity.resolution.isFailure ? .failure : .hover
        } else if case .watched = front.resolution {
            selected = front
            source = .front
            lease = nil
        } else if let current = lease, current.expiresAt >= now {
            if let resolution = current.activity.target.flatMap({ resolvedTargets[$0] }) {
                if case .watched = resolution {
                    let refreshed = ResolvedActivity(target: current.activity.target, resolution: resolution)
                    lease = Lease(activity: refreshed, expiresAt: current.expiresAt)
                    selected = refreshed
                    source = .lease
                } else if resolution.isFailure {
                    lease = nil
                    selected = ResolvedActivity(target: current.activity.target, resolution: resolution)
                    source = .failure
                } else {
                    lease = nil
                    selected = front
                    source = .front
                }
            } else {
                selected = current.activity
                source = .lease
            }
        } else {
            lease = nil
            selected = front
            source = .none
        }

        guard case .watched = selected.resolution, let selectedTarget = selected.target else {
            return Selection(activity: selected, keys: 0, scrolls: 0, source: source)
        }

        var keys = 0
        var scrolls = 0
        for event in freshEvents {
            switch event.kind {
            case .typing:
                let exactWindow = belongs(event.target, to: selectedTarget)
                let stableFrontPID = event.target.windowID == nil
                    && event.target.processID != nil && event.target.processID == selectedTarget.processID
                    && front.target == selectedTarget && priorFrontTarget == selectedTarget
                if (exactWindow || stableFrontPID),
                   let priorObservationStartedAt, event.timestamp > priorObservationStartedAt,
                   priorResolvedTargets[selectedTarget] == selected.resolution,
                   resolvedTargets[selectedTarget] == selected.resolution { keys += 1 }
            case .scroll:
                if belongs(event.target, to: selectedTarget) { scrolls += 1 }
            }
        }
        return Selection(activity: selected, keys: keys, scrolls: scrolls, source: source)
    }

    /// Only an exact WindowServer identity can earn input credit.
    private func belongs(_ event: ActivityTarget, to selected: ActivityTarget) -> Bool {
        guard let eventWindow = event.windowID, let selectedWindow = selected.windowID,
              eventWindow == selectedWindow else { return false }
        if let eventPID = event.processID, let selectedPID = selected.processID {
            return eventPID == selectedPID
        }
        return true
    }
}

private extension ActivityResolution {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
