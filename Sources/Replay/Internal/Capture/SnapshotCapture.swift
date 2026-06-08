import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Schedules + executes view-tree snapshots, emitting
/// ``NativeSnapshotEventData`` payloads to LegacyCore.
///
/// Trigger policies (from docs/native-snapshot-format.md):
///   • `screen_appeared` — `Replay.tagScreenName` + key-window
///     activation. Runs immediately so the tree we capture matches
///     what the user sees.
///   • `idle` — debounced 500ms after the last tap. Catches
///     post-interaction state (modal opened, list scrolled).
///   • `tap` — currently unused (idle covers it).
///   • `manual` — `Replay.captureSnapshot()` (future API).
///
/// Coalescing: a generation counter ensures the most-recent trigger
/// supersedes older pending captures. `minIntervalMs` (200ms)
/// prevents thrashing on devices that fire window/scene transitions
/// twice in quick succession.
///
/// All capture work runs on the main thread because UIView access
/// is main-thread-only on iOS. JSON serialization happens later in
/// BatchSender on a URLSession background queue.
///
/// Mirrors Android `SnapshotCapture.kt` so dashboard playback
/// treats output from both platforms identically.
final class SnapshotCapture {

    private let emit: (NativeSnapshotEventData) -> Void

    /// Generation counter — incremented on every trigger. Pending
    /// debounced captures bail out if generation has advanced past
    /// their scheduled gen.
    private var generation: Int = 0
    private let generationLock = NSLock()

    /// Debounce delay for idle-triggered snapshots. Matches the
    /// 500ms documented in the spec.
    private let idleDebounce: TimeInterval = 0.5

    /// Minimum gap between snapshots regardless of trigger — avoids
    /// thrashing on rapid back-to-back triggers.
    private let minInterval: TimeInterval = 0.2

    private var _lastSnapshotAt: Date?
    private let lastLock = NSLock()

    init(emit: @escaping (NativeSnapshotEventData) -> Void) {
        self.emit = emit
    }

    /// Snapshot the current screen NOW. Caller specifies the trigger
    /// for the player's render heuristic.
    ///
    /// ALWAYS deferred to the next main runloop tick — even when
    /// already on main. Why: customers call `Replay.tagScreenName`
    /// from `viewDidLoad` / `init`, before the view tree has been
    /// added to the screen + the first layout pass has flushed.
    /// Running drawHierarchy synchronously at that moment captures
    /// a black/empty frame (the view exists logically but its layer
    /// hasn't been composited yet). A `DispatchQueue.main.async`
    /// hop yields back to the runloop, lets pending layout +
    /// CADisplayLink flushes complete, then the capture sees the
    /// rendered hierarchy.
    /// Runtime gate that LegacyCore flips when the customer calls
    /// `pauseRecording()` / `Replay.optOutOfSchematicRecordings(true)`.
    /// Defaults to true (recording). When false: every entry point
    /// — captureNow, scheduleIdle, screen-resume callback — early-
    /// exits without touching the view tree or the bitmap pipeline.
    /// Independent of the SDK's overall opt-out state (which
    /// short-circuits at the pushLocked level).
    var enabled: Bool = true

    /// industry-standard periodic capture cadence (in seconds).
    ///
    /// the reference mobile SDK reverse-engineered: their default capture rate is ~2 FPS
    /// (every 0.5 s) during an active session. Without a continuous
    /// loop, a session that doesn't change screens produces one
    /// snapshot total and the player feels like a static image. With
    /// it, the player gets a continuous-feeling timeline of frames
    /// matching the user's perception of "video". Floor is clamped
    /// to 0.2 s inside ``startPeriodic`` to keep the main thread
    /// responsive.
    var periodicInterval: TimeInterval = 0.5
    private var periodicTimer: DispatchSourceTimer?
    private let periodicLock = NSLock()

    /// Start the continuous capture loop. Idempotent — re-starting
    /// cancels the previous timer first. Called by LegacyCore when
    /// a session starts (and again after foreground transitions).
    func startPeriodic() {
        periodicLock.withLock {
            periodicTimer?.cancel()
            let interval = max(periodicInterval, 0.2)
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
            timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in
                guard let self = self, self.enabled else { return }
                // Skip the dispatch hop if a more-recent trigger
                // already fired — minInterval gates double-fires.
                let recent: Bool = self.lastLock.withLock {
                    guard let last = self._lastSnapshotAt else { return false }
                    return Date().timeIntervalSince(last) < interval
                }
                if recent { return }
                self.doCapture(trigger: "periodic")
            }
            periodicTimer = timer
            timer.resume()
        }
    }

    /// Stop the continuous capture loop. Called by LegacyCore on
    /// session stop / pause / background. Idempotent.
    func stopPeriodic() {
        periodicLock.withLock {
            periodicTimer?.cancel()
            periodicTimer = nil
        }
    }

    func captureNow(trigger: String) {
        if !enabled { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.enabled else { return }
            self.doCapture(trigger: trigger)
        }
    }

    /// Schedule a snapshot to fire on the next idle window. Cancels
    /// previously-scheduled idle captures so only the latest trigger
    /// fires.
    func scheduleIdle() {
        if !enabled { return }
        let myGen = generationLock.withLock {
            generation += 1
            return generation
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + idleDebounce) { [weak self] in
            guard let self else { return }
            // Bail if a newer trigger superseded us.
            let currentGen = self.generationLock.withLock { self.generation }
            if currentGen != myGen { return }
            self.doCapture(trigger: "idle")
        }
    }

    /// Cancel any pending idle capture without firing.
    func cancelPending() {
        generationLock.withLock { generation += 1 }
    }

    // MARK: -

    private func doCapture(trigger: String) {
        let now = Date()
        let shouldThrottle: Bool = lastLock.withLock {
            guard let last = _lastSnapshotAt else { return false }
            return now.timeIntervalSince(last) < minInterval
        }
        if shouldThrottle { return }

        #if canImport(UIKit)
        guard let window = primaryWindow() else { return }
        guard window.bounds.width > 0, window.bounds.height > 0 else { return }
        guard let tree = ViewTreeSerializer.serialize(window) else { return }

        let scale = window.screen.scale
        let width = Int(window.bounds.width * scale)
        let height = Int(window.bounds.height * scale)

        lastLock.withLock { _lastSnapshotAt = now }

        // Tree-only emit. The legacy full-screen-bitmap branch (encode
        // + hash + asset/thumbnail upload) was retired with the
        // /v1/replay/assets + /v1/replay/thumbnail endpoints; the
        // current SDK streams pixels over the binary /v1/mobile protocol
        // via ReplayCore, not through this path.
        emit(buildPayload(tree: tree, width: width, height: height, scale: scale, trigger: trigger))
        #endif
    }

    /// Assemble the view-tree snapshot event payload.
    private func buildPayload(
        tree: NativeViewNode,
        width: Int,
        height: Int,
        scale: CGFloat,
        trigger: String
    ) -> NativeSnapshotEventData {
        return NativeSnapshotEventData(
            recorder: "native",
            width: width,
            height: height,
            pixelRatio: Double(scale),
            trigger: trigger,
            root: tree
        )
    }

    #if canImport(UIKit)
    /// Pick the "primary" UIWindow to snapshot — typically the key
    /// window. Walks connectedScenes (iOS 13+) since
    /// UIApplication.keyWindow is deprecated.
    ///
    /// Heuristic: prefer the foreground-active window scene; within
    /// that, prefer the key window; fall back to the first visible
    /// window.
    private func primaryWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        let preferred = scenes.first ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        guard let scene = preferred else { return nil }
        if let key = scene.windows.first(where: { $0.isKeyWindow }) { return key }
        return scene.windows.first(where: { !$0.isHidden })
    }
    #endif
}
