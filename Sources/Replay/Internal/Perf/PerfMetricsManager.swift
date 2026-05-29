import Foundation

/// Coordinator for the four perf collectors that ship in v1:
///
///   • ``ColdStartTracker`` — one-shot on first foreground
///   • ``FrameRateMonitor`` — frame_drop_pct + frozen_frame_count
///   • ``MemoryPoller`` — memory_rss_mb every 30s
///   • ``ThermalMonitor`` — thermal_state on change + baseline at start
///
/// Each collector calls our `emitMetric` closure with
/// `(metric, value, unit, rating?)`. We wrap into the standard
/// ``PerformanceEventData`` shape and forward to ReplayCore for
/// inclusion in the next batch.
///
/// Deferred until follow-up commits:
///   • `tap_response_ms` — needs hook from TapTracker into next
///     CADisplayLink tick to measure tap→paint latency
///   • `first_network_ttfb_ms` — needs the network capture path
///     (URLProtocol swizzle) which doesn't exist yet
///   • `battery_drain_pct_per_min` — needs UIDevice.isBatteryMonitoringEnabled = true,
///     opt-in because customers may not want it on
///   • `time_to_first_meaningful_render_ms` — needs UIViewController
///     viewDidAppear swizzle + a "meaningful render" heuristic
final class PerfMetricsManager {

    private let onMetric: (PerformanceEventData) -> Void

    private let coldStart: ColdStartTracker
    private let frames: FrameRateMonitor
    private let memory: MemoryPoller
    private let thermal: ThermalMonitor
    private let hang: HangWatchdog
    #if canImport(UIKit)
    private let battery: BatteryMonitor
    #endif

    init(onMetric: @escaping (PerformanceEventData) -> Void) {
        self.onMetric = onMetric
        // Hold a single emit closure that all collectors share —
        // each builds the PerformanceEventData from its (metric,
        // value, unit, rating) tuple. Keeps each collector
        // ignorant of the wire schema.
        self.coldStart = ColdStartTracker()
        self.frames = FrameRateMonitor { metric, value, unit, rating in
            onMetric(PerformanceEventData(
                kind: "perf", metric: metric, value: value, unit: unit, rating: rating
            ))
        }
        self.memory = MemoryPoller { metric, value, unit, rating in
            onMetric(PerformanceEventData(
                kind: "perf", metric: metric, value: value, unit: unit, rating: rating
            ))
        }
        self.thermal = ThermalMonitor { metric, value, unit, rating in
            onMetric(PerformanceEventData(
                kind: "perf", metric: metric, value: value, unit: unit, rating: rating
            ))
        }
        self.hang = HangWatchdog { frozenMs in
            // Severity buckets match the Android SDK so the
            // dashboard can render both platforms with the same
            // colour-coded thresholds:
            //   ≥ 10 s → poor      (severe freeze, user likely
            //                       force-quit)
            //   5–10 s → needs-improvement (noticeable but
            //                              recoverable)
            let rating = frozenMs >= 10_000 ? "poor" : "needs-improvement"
            // PerformanceEventData.details is intentionally nil on
            // iOS: walking the main thread's stack from a background
            // thread requires mach `thread_suspend` + `thread_get_state`
            // which is unsafe across iOS versions. The dashboard will
            // render the hang chip without a stack on iOS sessions; a
            // future MetricKit MXHangDiagnostic subscriber can fill
            // this in asynchronously (with the 24 h-delay caveat
            // documented on HangWatchdog).
            onMetric(PerformanceEventData(
                kind: "perf",
                metric: "anr_ms",
                value: Double(frozenMs),
                unit: "ms",
                rating: rating,
                details: nil
            ))
        }
        #if canImport(UIKit)
        self.battery = BatteryMonitor { metric, value, unit, rating in
            onMetric(PerformanceEventData(
                kind: "perf", metric: metric, value: value, unit: unit, rating: rating
            ))
        }
        #endif
    }

    /// Start every collector. Called from ``ReplayCore/start``
    /// after the session runtime is set up.
    func start() {
        frames.start()
        memory.start()
        thermal.start()
        hang.start()
        #if canImport(UIKit)
        battery.start()
        #endif
        // Cold start fires once on first foreground; ReplayCore
        // calls reportFirstForeground from its lifecycle hook so
        // we measure cold-launch → user-sees-app time, not just
        // dyld → didFinishLaunching.
    }

    /// Stop every collector. Called on session end + Replay.stop.
    func stop() {
        frames.stop()
        memory.stop()
        thermal.stop()
        hang.stop()
        #if canImport(UIKit)
        battery.stop()
        #endif
    }

    /// Emit the cold-start metric exactly once per process. Idempotent
    /// — repeated calls after the first are no-ops.
    func reportFirstForeground() {
        guard let ms = coldStart.recordFirstForeground() else { return }
        onMetric(PerformanceEventData(
            kind: "perf",
            metric: "cold_start_ms",
            value: ms,
            unit: "ms",
            rating: ColdStartTracker.rating(for: ms)
        ))
    }
}
