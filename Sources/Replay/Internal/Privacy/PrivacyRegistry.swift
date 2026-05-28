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
