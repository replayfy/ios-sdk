import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Tracks UIViews that the customer has marked as privacy-sensitive
/// via ``Replay/addPrivacyView(_:)``. Consulted by:
///
///   - ``TapTracker`` — taps on/inside a marked view get
///     `isSensitive: true` with uiValue/uiId/uiClass blanked.
///   - ``ViewTreeSerializer`` — nodes inside a marked subtree get
///     `occluded: true` with text + ariaLabel + imageRef blanked.
///   - ``BitmapCapture`` — paints a noise pattern over marked view
///     bounds so the captured PNG never carries the pixel content.
///
/// Weak refs throughout — never retains the customer's views. Views
/// removed from the hierarchy + deallocated drop out of the registry
/// automatically.
///
/// Singleton because the public ``Replay.addPrivacyView`` API is
/// static (matches UXCam + the Android SDK pattern). One registry
/// per process.
final class PrivacyRegistry {

    static let shared = PrivacyRegistry()

    #if canImport(UIKit)
    /// NSHashTable.weakObjects gives us a Set semantics with weak
    /// membership — `contains` is O(1), entries auto-evict on
    /// dealloc. UIView is reference-counted so the weak semantics
    /// are guaranteed.
    private let table = NSHashTable<UIView>.weakObjects()
    private let lock = NSLock()
    #endif

    // -----------------------------------------------------------------
    //  Bulk-privacy flags (UXCam parity)
    // -----------------------------------------------------------------
    //
    // UXCam ships three opt-in switches that occlude broad classes of
    // views without per-view registration:
    //
    //   occludeAllTextFields  → every UITextField / UITextView is
    //                           treated as sensitive (input controls)
    //   occludeAllTextViews   → every UILabel is treated as sensitive
    //                           (anything that DISPLAYS read-only text)
    //   occludeAllScreen      → whole captured snapshot is painted over
    //                           with the diagonal-stripe overlay
    //
    // Flags are checked in isSensitive() + BitmapCapture's overlay
    // pass; setting them mid-session takes effect on the NEXT snapshot.
    // `@objc` so the bridge class in ReplayObjC can flip them too.

    var occludeAllTextFields: Bool = false
    var occludeAllTextViews: Bool = false
    var occludeAllScreen: Bool = false

    // -----------------------------------------------------------------
    //  Pending one-shot rects (RN / Flutter bridges)
    // -----------------------------------------------------------------
    //
    // Cross-platform bridges (React Native + Flutter) don't have
    // native UIView refs we can add(). The bridge calculates rects
    // on the JS / Dart side (RN measureInWindow,
    // Flutter RenderBox.localToGlobal) and hands raw root-relative
    // rects here for the NEXT snapshot.
    //
    // One-shot semantics: BitmapCapture drains on every snapshot.
    // Bridges set rects every frame before capture; calling
    // setPendingFrameRects again without a snapshot in between
    // REPLACES (does not append to) the prior set.

    private let pendingRectsLock = NSLock()
    private var pendingFrameRects: [CGRect] = []

    /// Bridge entry point — set the rects to paint on the next
    /// snapshot. Replaces any prior pending set.
    func setPendingFrameRects(_ rects: [CGRect]) {
        pendingRectsLock.withLock { pendingFrameRects = rects }
    }

    /// Snapshot + clear atomically so we never paint the same rect
    /// twice. Called by BitmapCapture once per capture.
    func consumePendingFrameRects() -> [CGRect] {
        return pendingRectsLock.withLock {
            let snapshot = pendingFrameRects
            pendingFrameRects = []
            return snapshot
        }
    }

    private init() {}

    #if canImport(UIKit)
    /// Mark a view as sensitive. Idempotent — adding the same view
    /// twice is a no-op.
    func add(_ view: UIView) {
        lock.withLock { table.add(view) }
    }

    /// Remove a previously-marked view. Safe to call even if the
    /// view was never added.
    func remove(_ view: UIView) {
        lock.withLock { table.remove(view) }
    }

    /// Whether the view itself OR any superview is in the registry.
    /// Walks the chain — catches the common case where the customer
    /// marks a container (e.g. a UIStackView for the payment-method
    /// row) and expects every descendant to inherit the mark.
    func isSensitive(_ view: UIView) -> Bool {
        // Whole-screen overlay → every view is sensitive. Cheap
        // short-circuit before the per-view checks.
        if occludeAllScreen { return true }
        // Bulk class-based occlusion. UITextField + UITextView are
        // input controls; UILabel is read-only display text. The
        // wantText* flags target each set independently to match
        // UXCam's API surface (customers can hide JUST the inputs
        // without redacting labels + buttons).
        if occludeAllTextFields,
           view is UITextField || view is UITextView {
            return true
        }
        if occludeAllTextViews, view is UILabel {
            return true
        }
        return lock.withLock {
            if table.contains(view) { return true }
            var current: UIView? = view.superview
            while let v = current {
                if table.contains(v) { return true }
                current = v.superview
            }
            return false
        }
    }

    /// Walk [root]'s view tree and return frames (in root coords) of
    /// every UIView whose class matches a currently-enabled bulk-
    /// privacy flag. Used by BitmapCapture to paint stripe overlays
    /// over the matching regions in the captured PNG.
    ///
    /// Empty when neither bulk flag is set → zero overhead for
    /// customers not using bulk privacy.
    func bulkBounds(within root: UIView) -> [CGRect] {
        let wantFields = occludeAllTextFields
        let wantLabels = occludeAllTextViews
        guard wantFields || wantLabels else { return [] }
        var out: [CGRect] = []
        walkBulk(root, root: root, wantFields: wantFields, wantLabels: wantLabels, out: &out)
        return out
    }

    private func walkBulk(
        _ view: UIView,
        root: UIView,
        wantFields: Bool,
        wantLabels: Bool,
        out: inout [CGRect]
    ) {
        guard !view.isHidden, view.alpha > 0.01,
              view.bounds.width > 0, view.bounds.height > 0
        else { return }
        let matches = (wantFields && (view is UITextField || view is UITextView)) ||
                      (wantLabels && view is UILabel)
        if matches {
            out.append(view.convert(view.bounds, to: root))
            // Don't recurse — text widgets don't contain other
            // text widgets meaningfully.
            return
        }
        for sub in view.subviews {
            walkBulk(sub, root: root, wantFields: wantFields, wantLabels: wantLabels, out: &out)
        }
    }

    /**
     * Whether [view]'s screen-relative frame overlaps any registered
     * privacy marker. Used for SwiftUI integration where the marker
     * UIView (placed via `.background(UIViewRepresentable…)` or
     * `.overlay(…)`) is a sibling of the SwiftUI content's hosting
     * view rather than an ancestor — so ``isSensitive(_:)``'s
     * superview walk wouldn't catch it.
     *
     * Falls back to false when the view has no window (off-screen,
     * not yet laid out, etc.).
     */
    func isSensitiveByBounds(_ view: UIView) -> Bool {
        guard let window = view.window else { return false }
        let viewFrame = view.convert(view.bounds, to: window)
        return lock.withLock {
            for marker in table.allObjects {
                guard !marker.isHidden && marker.alpha > 0.01 else { continue }
                guard marker.window === window else { continue }
                let markerFrame = marker.convert(marker.bounds, to: window)
                if markerFrame.intersects(viewFrame) { return true }
            }
            return false
        }
    }

    /// Combined check — ancestor walk first (cheaper, catches the
    /// UIKit case where the customer marks a UIView directly), then
    /// bounds intersection (catches the SwiftUI case where the
    /// marker sits as a sibling under a hosting view).
    func isSensitiveCombined(_ view: UIView) -> Bool {
        if isSensitive(view) { return true }
        return isSensitiveByBounds(view)
    }

    /// Enumerate currently-tracked views inside `root` (typically
    /// the snapshot's primary window). Used by ``BitmapCapture`` to
    /// know where to paint the overlay. Skips views whose bounds
    /// don't intersect the root.
    func sensitiveBounds(within root: UIView) -> [CGRect] {
        return lock.withLock {
            var rects: [CGRect] = []
            for view in table.allObjects {
                guard view.window === root.window || view.isDescendant(of: root) else { continue }
                guard !view.isHidden && view.alpha > 0.01 else { continue }
                guard view.bounds.width > 0 && view.bounds.height > 0 else { continue }
                let frame = view.convert(view.bounds, to: root)
                rects.append(frame)
            }
            return rects
        }
    }

    /// Wipe the registry. Used on opt-out / SDK stop.
    func clear() {
        lock.withLock { table.removeAllObjects() }
    }
    #endif
}
