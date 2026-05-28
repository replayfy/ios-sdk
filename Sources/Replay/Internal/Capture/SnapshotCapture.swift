import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Schedules + executes view-tree snapshots, emitting
/// ``NativeSnapshotEventData`` payloads to ReplayCore.
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
    func captureNow(trigger: String) {
        if Thread.isMainThread {
            doCapture(trigger: trigger)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.doCapture(trigger: trigger)
            }
        }
    }

    /// Schedule a snapshot to fire on the next idle window. Cancels
    /// previously-scheduled idle captures so only the latest trigger
    /// fires.
    func scheduleIdle() {
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
        let payload = NativeSnapshotEventData(
            recorder: "native",
            width: Int(window.bounds.width * scale),
            height: Int(window.bounds.height * scale),
            pixelRatio: Double(scale),
            trigger: trigger,
            root: tree
        )
        lastLock.withLock { _lastSnapshotAt = now }
        emit(payload)
        #endif
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
