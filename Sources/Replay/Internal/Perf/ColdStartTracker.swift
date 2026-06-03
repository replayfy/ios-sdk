import Foundation

/// Measures cold-start time — process start → first foreground.
///
/// True process-start time would come from `sysctl(kinfo_proc)`
/// reading `kp_proc.p_starttime`. That's tricky to get right across
/// arch/iOS versions, so we approximate with the moment
/// ``LegacyCore.start`` was called — almost always milliseconds
/// after didFinishLaunching, which itself is milliseconds after
/// dyld finishes. The over-approximation is bounded and consistent.
///
/// Emits ``PerformanceEventData`` ONCE per process (the first
/// foreground after start). Subsequent foregrounds don't re-emit —
/// "cold start" is by definition the cold one.
final class ColdStartTracker {

    private let processStart: Date
    private var emitted = false
    private let lock = NSLock()

    init(processStart: Date = Date()) {
        self.processStart = processStart
    }

    /// Returns the cold-start measurement on the FIRST call.
    /// Subsequent calls return nil — caller emits the
    /// PerformanceEventData only when this returns non-nil.
    func recordFirstForeground(at now: Date = Date()) -> Double? {
        return lock.withLock {
            if emitted { return nil }
            emitted = true
            let ms = now.timeIntervalSince(processStart) * 1000
            return ms
        }
    }

    /// Thresholds from mobile-vitals-matrix.md.
    static func rating(for ms: Double) -> String {
        if ms < 1500 { return "good" }
        if ms < 2500 { return "needs-improvement" }
        return "poor"
    }
}
