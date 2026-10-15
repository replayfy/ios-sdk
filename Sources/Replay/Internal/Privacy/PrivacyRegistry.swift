import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(WebKit)
import WebKit
#endif

/// Tracks UIViews that the customer has marked as privacy-sensitive
/// via ``Replay/addPrivacyView(_:)``, plus the bulk / per-class flags and
/// the views the SDK masks on its own. Consulted by:
///
///   - ``MobileScreenshots`` — masks every sensitive region of each frame
///     (``windowPrivacyBounds(in:)``) so no pixel of it leaves the device.
///   - ``MobileTouchCapture`` / ``MobileInputCapture`` — taps on, and
///     observed inputs in, a masked view carry `"***"` instead of its
///     content (``isOccludedElement(_:)``).
///   - The legacy capture path (``TapTracker``, ``ViewTreeSerializer``,
///     ``BitmapCapture``'s stripe overlay), which the frames pipeline does
///     not use.
///
/// Weak refs throughout — never retains the customer's views. Views
/// removed from the hierarchy + deallocated drop out of the registry
/// automatically.
///
/// Singleton because the public ``Replay.addPrivacyView`` API is
/// static (matches the reference mobile SDK + the Android SDK pattern). One registry
/// per process.
final class PrivacyRegistry {

    static let shared = PrivacyRegistry()

    #if canImport(UIKit)
    /// NSHashTable.weakObjects gives us a Set semantics with weak
    /// membership — `contains` is O(1), entries auto-evict on
    /// dealloc. UIView is reference-counted so the weak semantics
    /// are guaranteed.
    private let table = NSHashTable<UIView>.weakObjects()
    /// Registered views whose gestures are not recorded either
    /// (`addPrivacyView(_:blockGestures: true)`, the SwiftUI
    /// `.replayOcclude()` default). Always a subset of `table`; guarded by
    /// the same lock.
    private let gestureBlockers = NSHashTable<UIView>.weakObjects()
    private let lock = NSLock()
    #endif

    // -----------------------------------------------------------------
    //  Bulk-privacy flags (the reference mobile SDK parity)
    // -----------------------------------------------------------------
    //
    // the reference mobile SDK ships three opt-in switches that occlude broad classes of
    // views without per-view registration:
    //
    //   occludeAllTextFields  → every UITextField / UITextView is
    //                           treated as sensitive (input controls)
    //   occludeAllTextViews   → every UILabel is treated as sensitive
    //                           (anything that DISPLAYS read-only text)
    //   occludeAllScreen      → whole captured frame is painted over
    //                           with one solid box
    //
    // Flags are checked in isSensitive() + BitmapCapture's overlay
    // pass; setting them mid-session takes effect on the NEXT snapshot.
    // `@objc` so the bridge class in ReplayObjC can flip them too.

    var occludeAllTextFields: Bool = false
    /// The dashboard's "always mask input values" switch, set from every
    /// `/v1/mobile/start` response (a missing value clears it). A second
    /// source next to the app's `occludeAllTextFields`, ORed with it: the
    /// app's flag cannot clear it, and it cannot clear the app's flag.
    /// Written and read on the main thread.
    var remoteOccludeAllTextFields: Bool = false
    var occludeAllTextViews: Bool = false
    var occludeAllScreen: Bool = false
    /// While the whole screen is occluded, gestures are not recorded either.
    /// The reference tracker hides them with the screen by default; an app
    /// can keep them with `occludeSensitiveScreen(_:hideGestures: false)`.
    var hideScreenGestures: Bool = false

    /// Every text field / text view is masked, by the app's flag or by the
    /// dashboard's.
    var occludesAllTextFields: Bool { occludeAllTextFields || remoteOccludeAllTextFields }

    // -----------------------------------------------------------------
    //  Mask render style (the reference's occlusion types)
    // -----------------------------------------------------------------
    //
    // The render style for every masked region the app chose itself
    // (addPrivacyView, occludeAll*, applyOcclusion, rects without their own
    // style). Both reference trackers paint an opaque box by default, so the
    // default is `.overlay`; `.blur` and `.pixelate` are opt-in. The regions
    // the SDK finds on its own (secure and password-type inputs, password
    // inputs inside web views) and the whole-screen cover are always solid,
    // whatever this says. Per-region styles (React Native / Flutter mask
    // widgets) override this on their own rects.

    var maskStyle: ReplayMaskStyle = .overlay
    /// Gaussian blur radius applied to `.blur` regions.
    var blurRadius: Double = 8

    /// Mask password inputs inside `WKWebView`s (on by default, as in the
    /// reference tracker). Off only through `ReplayConfig.disableWebViewMasking`.
    var webViewMaskingEnabled: Bool = true

    // -----------------------------------------------------------------
    //  Per-class occlusion (the reference mobile SDK applyOcclusion / removeOcclusion)
    // -----------------------------------------------------------------
    //
    // Customers can register arbitrary UIView subclasses; every
    // instance on screen gets masked. Goes beyond the
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

    /// Whether [view] or any of its ancestors is an instance of a
    /// registered class. The frames mask such an instance whole, so the
    /// labels and inputs inside it are masked too.
    func isInsideOccludedClass(_ view: UIView) -> Bool {
        let classes = occludedClassesLock.withLock { occludedClasses }
        if classes.isEmpty { return false }
        var cur: UIView? = view
        while let c = cur {
            if classes.contains(where: { c.isKind(of: $0) }) { return true }
            cur = c.superview
        }
        return false
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
    private var pendingFrameRects: [MaskRect] = []

    /// Bridge entry point — set the rects to paint on the next
    /// snapshot. Replaces any prior pending set. Each rect carries its own
    /// render style (the host's mask widget chooses blur vs overlay).
    func setPendingFrameRects(_ rects: [MaskRect]) {
        pendingRectsLock.withLock { pendingFrameRects = rects }
    }

    /// Snapshot + clear atomically so we never paint the same rect
    /// twice. Called by BitmapCapture once per capture.
    func consumePendingFrameRects() -> [MaskRect] {
        return pendingRectsLock.withLock {
            let snapshot = pendingFrameRects
            pendingFrameRects = []
            return snapshot
        }
    }

    private init() {}

    #if canImport(UIKit)
    #if canImport(WebKit)
    /// Password inputs inside the web views on screen, looked up before
    /// each native capture (see ``prepareFrame(_:)``).
    let webViews = WebViewMasking()
    #endif

    // -----------------------------------------------------------------
    //  What the reference tracker treats as secure, and as visible
    // -----------------------------------------------------------------

    /// Content types the reference tracker treats as secure, in addition to
    /// isSecureTextEntry, for both single- and multi-line text inputs.
    static let secureContentTypes: Set<UITextContentType> =
        [.password, .newPassword, .oneTimeCode, .creditCardNumber]

    /// A text input whose content is masked whatever the app's flags say:
    /// secure entry, or one of ``secureContentTypes``, on a `UITextField`
    /// or a `UITextView`. Read on every frame, so it follows a field whose
    /// secure entry is toggled ("show password").
    static func isSecureTextInput(_ view: UIView) -> Bool {
        if let f = view as? UITextField {
            if f.isSecureTextEntry { return true }
            if let t = f.textContentType { return secureContentTypes.contains(t) }
            return false
        }
        if let v = view as? UITextView {
            if v.isSecureTextEntry { return true }
            if let t = v.textContentType { return secureContentTypes.contains(t) }
        }
        return false
    }

    /// On-screen alpha, as the reference tracker measures it: the larger of
    /// the model alpha and the presentation-layer opacity, so a view that is
    /// fading out (model alpha already 0, still drawn) still counts as
    /// visible. The presentation layer is read only when the model alpha says
    /// invisible, which keeps the per-frame tree walk cheap.
    static func effectiveAlpha(_ v: UIView) -> CGFloat {
        let a = v.alpha
        if a > 0.01 { return a }
        if let p = v.layer.presentation() { return max(a, CGFloat(p.opacity)) }
        // Not committed to the render tree yet: an opacity animation in
        // flight means it is about to be drawn.
        let fading = v.layer.animationKeys()?.contains {
            (v.layer.animation(forKey: $0) as? CAPropertyAnimation)?.keyPath == "opacity"
        } ?? false
        return fading ? 1 : a
    }

    /// In a window, and neither hidden nor transparent itself or through any
    /// ancestor (the reference tracker's 0.01 alpha floor). There is no size
    /// check: a zero-size container that does not clip still draws its
    /// children.
    static func isEffectivelyVisible(_ v: UIView) -> Bool {
        guard v.window != nil else { return false }
        var cur: UIView? = v
        while let c = cur {
            if c.isHidden || effectiveAlpha(c) <= 0.01 { return false }
            cur = c.superview
        }
        return true
    }

    /// Rect of `view` in `root` as currently drawn. Mid-animation (push/pop,
    /// sheet, slide) the model frame is already at its destination while the
    /// pixels are not, so the reference tracker reads the presentation layer.
    /// We cover both positions so a mask never trails the pixels. `rect` is
    /// a region in the view's own coordinates (its bounds by default).
    static func screenRect(of view: UIView, in root: UIView, rect: CGRect? = nil) -> CGRect {
        let local = rect ?? view.bounds
        let model = view.convert(local, to: root)
        guard let p = view.layer.presentation(),
              let rp = root.layer.presentation() else { return model }
        let pres = p.convert(rect ?? p.bounds, to: rp)
        return pres.isNull || pres.isEmpty ? model : model.union(pres)
    }

    /// Mark a view as sensitive. Idempotent — adding the same view
    /// twice is a no-op. Gestures on it are still recorded (with a masked
    /// label); see ``add(_:blockGestures:)``.
    func add(_ view: UIView) {
        add(view, blockGestures: false)
    }

    /// Mark a view as sensitive and say whether gestures that START in it
    /// are recorded. The last call for a view decides.
    func add(_ view: UIView, blockGestures: Bool) {
        lock.withLock {
            table.add(view)
            if blockGestures { gestureBlockers.add(view) } else { gestureBlockers.remove(view) }
        }
    }

    /// Remove a previously-marked view. Safe to call even if the
    /// view was never added.
    func remove(_ view: UIView) {
        lock.withLock {
            table.remove(view)
            gestureBlockers.remove(view)
        }
    }

    /// Whether a gesture starting at `point` (window coordinates) starts in a
    /// view registered with `blockGestures`. Such gestures are not recorded,
    /// as in the reference tracker; the app still receives them.
    func isGestureBlocked(at point: CGPoint, in window: UIWindow) -> Bool {
        return lock.withLock {
            for view in gestureBlockers.allObjects where view.window === window {
                guard Self.isEffectivelyVisible(view) else { continue }
                if Self.screenRect(of: view, in: window).contains(point) { return true }
            }
            return false
        }
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
        // the reference mobile SDK's API surface (customers can hide JUST the inputs
        // without redacting labels + buttons).
        if occludesAllTextFields,
           view is UITextField || view is UITextView {
            return true
        }
        if occludeAllTextViews, view is UILabel {
            return true
        }
        // Per-class occlusion (applyOcclusion). The frames mask an
        // instance whole, so whatever sits inside one is sensitive too.
        if isInsideOccludedClass(view) {
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

    /// Whether what a gesture or an input names in `view` must be blanked:
    /// the whole screen is occluded, the view is (or sits inside) a secure or
    /// password-type input, every text field is masked and it is one (or sits
    /// inside one), it is masked by class or by registration (itself or an
    /// ancestor), or it overlaps a registered marker (SwiftUI). The reference
    /// tracker blanks the exact registered view only; the ancestor and
    /// overlap checks follow what the frames hide.
    func isOccludedElement(_ view: UIView) -> Bool {
        if occludeAllScreen { return true }
        let allFields = occludesAllTextFields
        var cur: UIView? = view
        while let c = cur {
            if Self.isSecureTextInput(c) { return true }
            if allFields && (c is UITextField || c is UITextView) { return true }
            cur = c.superview
        }
        return isSensitiveCombined(view)
    }

    /// Walk [root]'s view tree and return frames (in root coords) of
    /// every UIView whose class matches a currently-enabled bulk-
    /// privacy flag, a registered occluded class, OR is a secure text
    /// input. Used by BitmapCapture to paint overlays over the matching
    /// regions in the captured PNG.
    ///
    /// Always walks — secure inputs (see ``isSecureTextInput(_:)``) are
    /// masked unconditionally, so we can't early-return even when no bulk
    /// flag / class is set.
    func bulkBounds(within root: UIView) -> [CGRect] {
        return bulkMaskRects(within: root).map { $0.rect }
    }

    /// ``bulkBounds(within:)`` with each region's render style: secure inputs
    /// are always solid, the rest use the app's ``maskStyle``.
    func bulkMaskRects(within root: UIView) -> [MaskRect] {
        var walk = BulkWalk(
            fields: occludesAllTextFields,
            labels: occludeAllTextViews,
            style: maskStyle,
            webViews: false
        )
        walkBulk(root, root: root, into: &walk)
        return walk.out
    }

    /// What one walk of the view tree is looking for, and what it found.
    private struct BulkWalk {
        let fields: Bool
        let labels: Bool
        let style: ReplayMaskStyle
        /// Mask web views too (the frames screenshotter's walk).
        let webViews: Bool
        var out: [MaskRect] = []
    }

    private func walkBulk(_ view: UIView, root: UIView, into walk: inout BulkWalk) {
        // The walk prunes at hidden or transparent views, which equals the
        // reference tracker's ancestor check. No size gate: neither reference
        // has one, and a zero-size, unclipped container still shows its
        // children.
        guard !view.isHidden, Self.effectiveAlpha(view) > 0.01 else { return }
        // Secure entry and password-type content are ALWAYS masked, solid,
        // regardless of any flag — the reference masks them by default, and
        // our web SDK forces password masking on.
        if Self.isSecureTextInput(view) {
            let r = Self.screenRect(of: view, in: root)
            if !r.isEmpty { walk.out.append(MaskRect(rect: r, style: .overlay)) }
            return
        }
        let matches = (walk.fields && (view is UITextField || view is UITextView)) ||
                      (walk.labels && view is UILabel) ||
                      // Per-class occlusion (applyOcclusion). Cheap
                      // when no classes registered (empty-set early-
                      // out lives inside matchesOccludedClass).
                      matchesOccludedClass(view)
        if matches {
            let r = Self.screenRect(of: view, in: root)
            if !r.isEmpty { walk.out.append(MaskRect(rect: r, style: walk.style)) }
            // Don't recurse — text widgets don't contain other
            // text widgets meaningfully.
            return
        }
        #if canImport(WebKit)
        if walk.webViews, let web = view as? WKWebView {
            walk.out += webViews.maskRects(for: web, in: root)
        }
        #endif
        for sub in view.subviews {
            walkBulk(sub, root: root, into: &walk)
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
                guard marker.window === window else { continue }
                guard Self.isEffectivelyVisible(marker) else { continue }
                let markerFrame = Self.screenRect(of: marker, in: window)
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
    /// know where to paint the overlay. Only views drawn on screen count:
    /// hidden or transparent ones, or ones under a hidden or transparent
    /// ancestor, are skipped; a fading one still counts.
    func sensitiveBounds(within root: UIView) -> [CGRect] {
        return lock.withLock {
            var rects: [CGRect] = []
            for view in table.allObjects {
                guard view.window === root.window || view.isDescendant(of: root) else { continue }
                guard Self.isEffectivelyVisible(view) else { continue }
                let r = Self.screenRect(of: view, in: root)
                guard !r.isEmpty else { continue }
                rects.append(r)
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
    ///     secure text input, always (``bulkMaskRects``)
    ///   - password inputs inside web views (``prepareFrame(_:)``)
    ///   - one-shot bridge rects (React Native / Flutter)
    ///
    /// `occludeSensitiveScreen` short-circuits to a single window-sized
    /// rect so no pixel survives. Must be called on the main thread
    /// (it touches UIKit) — the screenshotter's capture runs there.
    func windowPrivacyBounds() -> [MaskRect] {
        guard let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow })
            ?? UIApplication.shared.windows.first
        else { return [] }
        return windowPrivacyBounds(in: window)
    }

    /// ``windowPrivacyBounds()`` for a given window.
    func windowPrivacyBounds(in window: UIWindow) -> [MaskRect] {
        if occludeAllScreen {
            // Drain pending bridge rects even on the full-screen path so
            // they don't carry into a later non-full-screen frame.
            _ = consumePendingFrameRects()
            // Always solid, whatever the mask style: the reference tracker
            // blanks the whole screen.
            return [MaskRect(rect: window.bounds, style: .overlay)]
        }
        // Native/bulk sources render with the global style (secure inputs
        // and web views always solid); the bridge rects (React Native /
        // Flutter) carry their own per-region style.
        let style = maskStyle
        var walk = BulkWalk(
            fields: occludesAllTextFields,
            labels: occludeAllTextViews,
            style: style,
            webViews: webViewMaskingEnabled
        )
        walkBulk(window, root: window, into: &walk)
        #if canImport(WebKit)
        // Each lookup serves one frame only.
        webViews.endFrame()
        #endif
        let marked = sensitiveBounds(within: window).map { MaskRect(rect: $0, style: style) }
        return marked + walk.out + consumePendingFrameRects()
    }

    /// Get ready to capture a frame of the key window, then call `ready` on
    /// the main thread: looks up the password inputs inside the web views
    /// seen on screen, waiting for them at most ``WebViewMasking/timeout``.
    /// A web view with no answer by then is masked whole. Main thread only.
    func prepareFrame(_ ready: @escaping () -> Void) {
        #if canImport(WebKit)
        guard webViewMaskingEnabled, !occludeAllScreen else { ready(); return }
        webViews.prepare(allFields: occludesAllTextFields, ready)
        #else
        ready()
        #endif
    }

    /// Wipe the registry. Used on opt-out / SDK stop.
    func clear() {
        lock.withLock {
            table.removeAllObjects()
            gestureBlockers.removeAllObjects()
        }
    }
    #endif
}
