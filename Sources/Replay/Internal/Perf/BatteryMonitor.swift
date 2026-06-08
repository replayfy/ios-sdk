import Foundation
#if canImport(UIKit)
import UIKit

/// Battery telemetry — emits three perf metrics that show how the
/// host app's session relates to the device's power state:
///
///   • `battery_level_pct`  — 0..100, current charge level. Emitted
///                            on every level-change notification +
///                            once at start.
///   • `battery_state`      — encoded ChargeState (0=unknown, 1=
///                            unplugged, 2=charging, 3=full).
///                            Emitted on state-change + at start.
///   • `battery_drain_pct_per_min` — rolling drain rate computed by
///                            sampling level over a 60s window.
///                            Only emitted while UNPLUGGED (charging
///                            sessions would yield negative drain).
///                            Captures the "session ran the battery
///                            down" insight that's the headline
///                            mobile-vitals metric for travel/games/
///                            background-location apps.
///
/// Implementation:
///   - `UIDevice.current.isBatteryMonitoringEnabled = true` opts in.
///     Apple's docs warn that this drains battery slightly while on,
///     but the cost is negligible on iOS 12+ (Apple optimised the
///     level-change pump in iOS 13).
///   - Subscribe to `batteryLevelDidChangeNotification` +
///     `batteryStateDidChangeNotification`. Both fire on the main
///     queue.
///   - Periodic 60s sample drives `battery_drain_pct_per_min`. We
///     could subscribe-only without polling, but the level change
///     notification doesn't fire on a fixed cadence — Apple coalesces
///     levels into 5% buckets. The poll guarantees at least one
///     sample per minute regardless of charging state.
///
/// the reference mobile SDK ships battery monitoring on iOS but NOT on Android — this
/// closes the gap.
final class BatteryMonitor {

    private let emit: (_ metric: String, _ value: Double, _ unit: String, _ rating: String?) -> Void

    /// Drain-rate sampling interval. 60s matches the cadence the
    /// dashboard's mobile-vitals chart uses for the x-axis bucket.
    private let drainSampleIntervalMs: Int64 = 60_000

    /// `Float.nan` sentinel — Swift's `nil` would force the level
    /// state through an Optional<Float> on every callback which
    /// reads worse than a sentinel.
    private var lastLevelPct: Float = .nan
    private var lastSampleAtMs: Int64 = 0

    private var running: Bool = false
    private var pollTimer: DispatchSourceTimer?

    init(emit: @escaping (String, Double, String, String?) -> Void) {
        self.emit = emit
    }

    func start() {
        if running { return }
        running = true
        // Opting in here rather than at SDK boot keeps the cost
        // (negligible but non-zero) out of customer apps that
        // disable performance capture via remote config.
        UIDevice.current.isBatteryMonitoringEnabled = true

        let nc = NotificationCenter.default
        nc.addObserver(
            self,
            selector: #selector(handleLevelChange),
            name: UIDevice.batteryLevelDidChangeNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(handleStateChange),
            name: UIDevice.batteryStateDidChangeNotification,
            object: nil
        )

        // Baseline emit so the dashboard sees the starting battery
        // state even if the device doesn't fire a notification
        // during this session (long enough on a fully-charged or
        // fully-discharged device).
        emitLevelAndState(isBaseline: true)
        startDrainSampleTimer()
    }

    func stop() {
        if !running { return }
        running = false
        NotificationCenter.default.removeObserver(self)
        pollTimer?.cancel()
        pollTimer = nil
        UIDevice.current.isBatteryMonitoringEnabled = false
        lastLevelPct = .nan
        lastSampleAtMs = 0
    }

    // MARK: - Notification handlers

    @objc private func handleLevelChange() {
        emitLevelAndState(isBaseline: false)
    }

    @objc private func handleStateChange() {
        emitLevelAndState(isBaseline: false)
    }

    private func emitLevelAndState(isBaseline: Bool) {
        let device = UIDevice.current
        let rawLevel = device.batteryLevel
        // batteryLevel returns -1 when monitoring is disabled OR the
        // device hasn't read the value yet (rare race during first
        // notification). Skip — we'll get a real value on the next
        // callback.
        guard rawLevel >= 0 else { return }
        let pct = Double(rawLevel * 100)

        emit("battery_level_pct", pct, "pct", rateLevel(rawLevel))
        emit(
            "battery_state",
            Double(encodeState(device.batteryState)),
            "state",
            nil
        )

        // Seed the drain-sample baseline on first read so the next
        // periodic tick can compute a real delta.
        if isBaseline || lastLevelPct.isNaN {
            lastLevelPct = rawLevel * 100
            lastSampleAtMs = SessionRuntime.nowMs()
        }
    }

    // MARK: - Drain-rate sampling

    /// `DispatchSourceTimer` on a utility queue. Re-arms every
    /// drainSampleIntervalMs ms and reads the current level. Compared
    /// against [lastLevelPct] for the drain delta.
    private func startDrainSampleTimer() {
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .utility)
        )
        timer.schedule(
            deadline: .now() + .milliseconds(Int(drainSampleIntervalMs)),
            repeating: .milliseconds(Int(drainSampleIntervalMs)),
            leeway: .seconds(5)
        )
        timer.setEventHandler { [weak self] in
            self?.takeDrainSample()
        }
        timer.resume()
        pollTimer = timer
    }

    private func takeDrainSample() {
        let device = UIDevice.current
        let rawLevel = device.batteryLevel
        guard rawLevel >= 0 else { return }
        let nowMs = SessionRuntime.nowMs()
        let nowPct = Double(rawLevel * 100)

        defer {
            // Always rotate the baseline AFTER computing — even when
            // we skip emission (charging branch), we want the next
            // tick to compare against the most-recent value.
            lastLevelPct = Float(nowPct)
            lastSampleAtMs = nowMs
        }

        // Skip the very first tick when we have no prior sample.
        if lastLevelPct.isNaN || lastSampleAtMs == 0 { return }

        // Drain rate only makes sense while UNPLUGGED. Charging /
        // full sessions would yield negative or zero delta, polluting
        // the dashboard's percentile chart.
        guard device.batteryState == .unplugged else { return }

        let elapsedMin = Double(nowMs - lastSampleAtMs) / 60_000.0
        if elapsedMin <= 0 { return }
        let deltaPct = Double(lastLevelPct) - nowPct
        // Below 0.5%/min is normal idle drain; we ship it anyway so
        // the dashboard can show a baseline. Big spikes (≥3%/min)
        // get rated "poor".
        let rating: String?
        switch deltaPct / elapsedMin {
        case 3.0...:           rating = "poor"
        case 1.5..<3.0:        rating = "needs-improvement"
        case 0..<1.5:          rating = "good"
        default:               rating = nil  // Negative (level went up — backfill from charger after unplug); omit rating.
        }
        emit(
            "battery_drain_pct_per_min",
            deltaPct / elapsedMin,
            "pct",
            rating
        )
    }

    // MARK: - Helpers

    /// Encode UIDevice.BatteryState as an integer the dashboard can
    /// chart over time. Same scheme the iOS docs use internally:
    ///   0 = unknown, 1 = unplugged, 2 = charging, 3 = full.
    private func encodeState(_ state: UIDevice.BatteryState) -> Int {
        switch state {
        case .unknown:    return 0
        case .unplugged:  return 1
        case .charging:   return 2
        case .full:       return 3
        @unknown default: return 0
        }
    }

    /// Rating buckets for the LEVEL itself (not the drain). Drives
    /// the colour swatch on the dashboard's session perf chart:
    ///   ≥40%  → "good"
    ///   15–40% → "needs-improvement"
    ///   <15%  → "poor"
    /// Threshold inspired by iOS's own "Low Battery" 20% banner +
    /// "Critical" 10% notification.
    private func rateLevel(_ rawLevel: Float) -> String? {
        let pct = rawLevel * 100
        switch pct {
        case 40...100:  return "good"
        case 15..<40:   return "needs-improvement"
        case 0..<15:    return "poor"
        default:        return nil
        }
    }
}
#endif
