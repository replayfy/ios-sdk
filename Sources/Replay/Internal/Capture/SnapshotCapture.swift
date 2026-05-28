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

    /// Wired by ``ReplayCore/start`` once config arrives. Nil → snapshot
    /// ships tree-only (no `root.imageRef`); player falls back to
    /// wireframe rendering.
    var assetUploader: AssetUploader?

    /// Reflects `ReplayConfig.captureSnapshotPixels`. False until
    /// config lands or remote config flips it off.
    var captureBitmaps: Bool = false

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
        let width = Int(window.bounds.width * scale)
        let height = Int(window.bounds.height * scale)

        // Bitmap capture is synchronous + must be on main thread —
        // do it BEFORE handing off to the background async so the
        // captured tree + pixels are from the SAME frame. A fast
        // scroll between tree-walk and bitmap would otherwise yield
        // misaligned nodes.
        let bitmap: UIImage? = captureBitmaps ? BitmapCapture.capture(window) : nil

        lastLock.withLock { _lastSnapshotAt = now }

        // No bitmap (capture disabled or failed) → emit immediately
        // with tree-only. Player falls back to wireframe rendering.
        guard let bitmap else {
            emit(buildPayload(tree: tree, width: width, height: height, scale: scale, trigger: trigger, imageRef: nil))
            return
        }

        // Hand off to a background Task for PNG encode + SHA-256 +
        // upload. The async work doesn't block the UI; the snapshot
        // event is emitted once the upload's URL comes back (or
        // immediately with imageRef=nil if the upload failed).
        let uploader = assetUploader
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            guard let asset = BitmapCapture.encodeAndHash(bitmap) else {
                self.emit(self.buildPayload(tree: tree, width: width, height: height, scale: scale, trigger: trigger, imageRef: nil))
                return
            }
            let imageRef: String? = await uploader?.uploadOrCached(asset)
            self.emit(self.buildPayload(tree: tree, width: width, height: height, scale: scale, trigger: trigger, imageRef: imageRef))
        }
        #endif
    }

    /// Stitch the bitmap URL into the root node + assemble the
    /// event payload. The root's `imageRef` lets the player render
    /// a pixel-accurate background; nested image nodes (per-leaf
    /// UIImageView captures) come in a follow-up commit.
    private func buildPayload(
        tree: NativeViewNode,
        width: Int,
        height: Int,
        scale: CGFloat,
        trigger: String,
        imageRef: String?
    ) -> NativeSnapshotEventData {
        let rootWithImage: NativeViewNode = imageRef.map { ref in
            NativeViewNode(
                id: tree.id,
                type: tree.type,
                className: tree.className,
                bounds: tree.bounds,
                text: tree.text,
                imageRef: ref,
                backgroundColor: tree.backgroundColor,
                opacity: tree.opacity,
                occluded: tree.occluded,
                ariaLabel: tree.ariaLabel,
                children: tree.children
            )
        } ?? tree

        return NativeSnapshotEventData(
            recorder: "native",
            width: width,
            height: height,
            pixelRatio: Double(scale),
            trigger: trigger,
            root: rootWithImage
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
