/// Elapsed monotonic time between observations. Long gaps indicate sleep or suspension.
public struct TickClock {
    private var previous: Double?
    public init() {}

    public mutating func elapsed(at uptime: Double) -> Double {
        defer { previous = uptime }
        guard let previous else { return 0 }
        let elapsed = uptime - previous
        // Do not charge sleep, process suspension, or a clock discontinuity as site use.
        guard elapsed.isFinite, elapsed >= 0, elapsed <= 10 else { return 0 }
        return elapsed
    }
}
