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
    //  Per-class occlusion (UXCam applyOcclusion / removeOcclusion)
    // -----------------------------------------------------------------
    //
    // Customers can register arbitrary UIView subclasses; every
    // instance on screen gets the stripe overlay. Goes beyond the
    // bulk UITextField / UILabel flags — useful for custom widgets
    // (e.g. CreditCardInputView, MedicalRecordCard) that should be
    // default-occluded across every screen they appear on.

    #if canImport(UIKit)
    private let occludedClassesLock = NSLock()
    /// Set of UIView (sub-)class types registered for occlusion.
    /// Swift metatypes are AnyObject-bridgeable; we hash by
    /// `ObjectIdentifier(type)` so adds are O(1).
    private var occludedClassIds: Set<ObjectIdentifier> = []
    /// Parallel list of the actual UIView.Type values — used to
    /// run `view.isKind(of:)` since ObjectIdentifier loses the
    /// concrete type. Kept in sync with `occludedClassIds`.
    private var occludedClasses: [UIView.Type] = []

    /// Register a UIView subclass for occlusion. Idempotent —
    /// adding the same class twice is a no-op.
    func applyOcclusion(_ cls: UIView.Type) {
        occludedClassesLock.withLock {
            let id = ObjectIdentifier(cls)
            if occludedClassIds.insert(id).inserted {
                occludedClasses.append(cls)
            }
        }
    }

    /// Unregister a previously-added class. Safe to call for
    /// classes that were never added.
    func removeOcclusion(_ cls: UIView.Type) {
        occludedClassesLock.withLock {
            let id = ObjectIdentifier(cls)
            if occludedClassIds.remove(id) != nil {
                occludedClasses.removeAll { ObjectIdentifier($0) == id }
            }
        }
    }

    /// Whether [view] is an instance of any registered class.
    /// Hot path — early-out on the empty set is the common case
    /// (most apps never call applyOcclusion).
    func matchesOccludedClass(_ view: UIView) -> Bool {
        if occludedClasses.isEmpty { return false }
        return occludedClassesLock.withLock {
            for cls in occludedClasses {
                if view.isKind(of: cls) { return true }
            }
            return false
        }
    }
    #endif

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
        // Per-class occlusion (applyOcclusion). Cheap when no
        // classes registered (early-out on empty set).
        if matchesOccludedClass(view) {
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
    /// privacy flag, a registered occluded class, OR is a secure text
    /// entry field. Used by BitmapCapture to paint stripe overlays
    /// over the matching regions in the captured PNG.
    ///
    /// Always walks — secure fields (``UITextField/isSecureTextEntry``)
    /// are masked unconditionally (see [walkBulk]), so we can't early-
    /// return even when no bulk flag / class is set.
    func bulkBounds(within root: UIView) -> [CGRect] {
        let wantFields = occludeAllTextFields
        let wantLabels = occludeAllTextViews
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
                      (wantLabels && view is UILabel) ||
                      // Per-class occlusion (applyOcclusion). Cheap
                      // when no classes registered (empty-set early-
                      // out lives inside matchesOccludedClass).
                      matchesOccludedClass(view) ||
                      // Secure text entry is ALWAYS masked, regardless of
                      // any flag — the reference masks iOS secure fields by
                      // default, and our web SDK forces password masking on.
                      ((view as? UITextField)?.isSecureTextEntry == true)
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

    /// Resolve the full set of sensitive rects for the current key
    /// window, in window coordinates. This is the seam the mobile
    /// frames screenshotter masks against — it walks the live view
    /// tree and merges every privacy source:
    ///
    ///   - explicitly-marked views + their descendants (``sensitiveBounds``)
    ///   - bulk class matches (occludeAll* / applyOcclusion) AND every
    ///     secure text-entry field, always (``bulkBounds``)
    ///   - one-shot bridge rects (React Native / Flutter)
    ///
    /// `occludeSensitiveScreen` short-circuits to a single window-sized
    /// rect so no pixel survives. Must be called on the main thread
    /// (it touches UIKit) — the screenshotter's capture runs there.
    func windowPrivacyBounds() -> [CGRect] {
        guard let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow })
            ?? UIApplication.shared.windows.first
        else { return [] }
        if occludeAllScreen {
            // Drain pending bridge rects even on the full-screen path so
            // they don't carry into a later non-full-screen frame.
            _ = consumePendingFrameRects()
            return [window.bounds]
        }
        return sensitiveBounds(within: window) +
               bulkBounds(within: window) +
               consumePendingFrameRects()
    }

    /// Wipe the registry. Used on opt-out / SDK stop.
    func clear() {
        lock.withLock { table.removeAllObjects() }
    }
    #endif
}
