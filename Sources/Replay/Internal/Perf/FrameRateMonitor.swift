import Foundation
#if canImport(UIKit)
import UIKit
import QuartzCore
#endif

/// Tracks UI frame timing via ``CADisplayLink``. Produces two
/// metrics:
///
///   - `frame_drop_pct` — rolling 10s ratio of dropped to expected
///     frames. Compared against the screen's `targetFramesPerSecond`
///     (60 on most devices, 120 on ProMotion). Emitted every 10s
///     when non-zero.
///   - `frozen_frame_count` — total frames in the session with
///     interval > 700ms. Per-frame check, totalled in memory,
///     shipped on each emit.
///
/// CADisplayLink fires synchronously on the main thread once per
/// vsync. We do the bare minimum work in the callback (a counter
/// bump + delta math) — never call out to the network or do
/// allocations.
///
/// Mirrors what Android does via Choreographer.FrameCallback.
final class FrameRateMonitor {

    /// Called when there's something to report. May fire concurrently
    /// for both metrics in one tick.
    private let emit: (_ metric: String, _ value: Double, _ unit: String, _ rating: String?) -> Void

    #if canImport(UIKit)
    private var displayLink: CADisplayLink?
    #endif

    private var lastFrameTime: CFTimeInterval = 0
    private var droppedThisWindow: Int = 0
    private var expectedThisWindow: Int = 0
    private var lastEmitAt: CFTimeInterval = 0
    private var frozenTotal: Int = 0
    private var lastFrozenEmit: Int = 0

    /// How long we accumulate before emitting `frame_drop_pct`.
    /// Matches the matrix doc's 10s window.
    private let emitIntervalSec: CFTimeInterval = 10

    init(emit: @escaping (String, Double, String, String?) -> Void) {
        self.emit = emit
    }

    func start() {
        #if canImport(UIKit)
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(onFrame(_:)))
        // .common mode so we still get callbacks during scrolling
        // (when the runloop is in UITrackingRunLoopMode).
        link.add(to: .main, forMode: .common)
        displayLink = link
        #endif
    }

    func stop() {
        #if canImport(UIKit)
        displayLink?.invalidate()
        displayLink = nil
        #endif
        lastFrameTime = 0
        droppedThisWindow = 0
        expectedThisWindow = 0
    }

    #if canImport(UIKit)
    @objc private func onFrame(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { lastFrameTime = now }

        // First tick — nothing to compare against.
        guard lastFrameTime > 0 else {
            lastEmitAt = now
            return
        }

        let actualInterval = now - lastFrameTime
        // Screen's expected frame interval. ProMotion devices report
        // 0.008 (120Hz); standard 0.0167 (60Hz). preferredFrameRateRange
        // exists in iOS 15+ — we use targetTimestamp - timestamp as
        // the safer cross-version source.
        let expectedInterval = max(0.001, link.targetTimestamp - link.timestamp)

        // A "dropped" frame in user-perceived terms: any interval
        // > 1.5× expected. The screen missed at least one vsync.
        if actualInterval > expectedInterval * 1.5 {
            // Count how many vsyncs we missed — actualInterval /
            // expectedInterval ≈ how many frame slots elapsed.
            let missed = Int((actualInterval / expectedInterval).rounded(.down)) - 1
            droppedThisWindow += max(1, missed)
        }
        expectedThisWindow += 1

        // Frozen frame — single frame interval > 700ms. Matches
        // Google's "frozen frame" definition for Android Vitals.
        if actualInterval > 0.7 {
            frozenTotal += 1
        }

        // Periodic emit. Only ship when there's something to report
        // — silent windows save bandwidth.
        let sinceEmit = now - lastEmitAt
        if sinceEmit >= emitIntervalSec {
            emitWindow()
            lastEmitAt = now
            droppedThisWindow = 0
            expectedThisWindow = 0
        }
    }

    private func emitWindow() {
        if expectedThisWindow > 0 && droppedThisWindow > 0 {
            let pct = Double(droppedThisWindow) / Double(expectedThisWindow)
            emit("frame_drop_pct", pct, "pct", rateFrameDrop(pct))
        }
        // Frozen frames: emit delta since last report so the backend
        // counter increments. Skip if no change.
        let delta = frozenTotal - lastFrozenEmit
        if delta > 0 {
            emit("frozen_frame_count", Double(delta), "count", rateFrozen(frozenTotal))
            lastFrozenEmit = frozenTotal
        }
    }
    #endif

    /// Thresholds from mobile-vitals-matrix.md.
    private func rateFrameDrop(_ pct: Double) -> String {
        if pct < 0.05 { return "good" }
        if pct < 0.15 { return "needs-improvement" }
        return "poor"
    }

    private func rateFrozen(_ total: Int) -> String {
        if total == 0 { return "good" }
        if total < 3 { return "needs-improvement" }
        return "poor"
    }
}
