#if canImport(UIKit)
import SwiftUI
import UIKit
import Replay

/// SwiftUI integration for the Replay iOS SDK.
///
/// Two View modifiers — `.replayOcclude()` and `.replayTagScreenName(_:)` —
/// solve the two big "SwiftUI app needs Replay" gaps that the
/// UIKit-only SDK can't address:
///
///   1. Auto-screen-tagging relies on UIViewController class names;
///      SwiftUI apps often have one or zero hosting controllers so
///      every screen shows up as "RootView" without manual tagging.
///   2. `addPrivacyView(_:)` needs a UIView reference; SwiftUI views
///      don't expose their underlying UIView. The occlude modifier
///      bridges via a transparent marker UIView registered with
///      ``Replay.addPrivacyView`` — combined with the SDK's
///      bounds-intersection check (PrivacyRegistry.isSensitiveByBounds),
///      the SwiftUI content rendered at the same screen region is
///      treated as sensitive.
///
/// Optional dependency — customers building UIKit-first apps don't
/// need to import `ReplaySwiftUI` at all.

// MARK: - View extensions

public extension View {

    /**
     * Mark this view's rendered region as privacy-sensitive — the
     * region is masked in playback (solid by default, or the style set
     * with `Replay.setMaskStyle`), and taps on it are recorded with a
     * blanked label.
     *
     * Use on any view containing PII (credit card forms, payment
     * methods, password fields, profile addresses, etc).
     *
     * Implementation: inserts a transparent UIView marker at the
     * same screen rect via `.overlay(…)`. The marker registers with
     * the SDK's PrivacyRegistry; tap + snapshot pipelines check
     * bounds-intersection against registered markers. The marker never
     * takes part in hit-testing, so the content under it keeps
     * receiving every touch.
     *
     * - Parameter blockGestures: When true (default), gestures that
     *   start in the region are not recorded at all — useful when the
     *   sensitive region also responds to gestures that you don't
     *   want correlated with the user (e.g. a "show CVC" eyeball
     *   button). It only affects the recording; the app still
     *   receives the gestures. Defaults to true.
     */
    func replayOcclude(blockGestures: Bool = true) -> some View {
        // overlay places the marker IN FRONT, over the SwiftUI content's
        // region, so its frame matches what is drawn. It is fully
        // transparent and never hit-testable, so the user sees and
        // touches the content as if no modifier were applied.
        self.overlay(
            PrivacyMarker(blockGestures: blockGestures)
                .allowsHitTesting(false)
        )
    }

    /**
     * Tell the SDK what screen this view represents. Fires
     * `Replay.tagScreenName(_:)` on first appearance — drives the
     * dashboard's "current screen" label, the route prefix on uiId,
     * and the route field on `tap` events.
     *
     * Use ONCE per logical screen at the top of its view body, e.g.
     * `var body: some View { … .replayTagScreenName("Checkout") }`.
     *
     * Repeated `.onAppear` fires (e.g. when a sheet dismisses and
     * the underlying view reappears) re-tag, which is the right
     * behaviour — Tap events after the re-tag carry the correct
     * route.
     */
    func replayTagScreenName(_ name: String) -> some View {
        self.onAppear { Replay.tagScreenName(name) }
    }
}

// MARK: - UIViewRepresentable marker

/// Transparent UIView used as the bounds-intersection marker for
/// SwiftUI occlude regions. Registered with the SDK's PrivacyRegistry
/// in `makeUIView`, removed in `dismantleUIView`.
private struct PrivacyMarker: UIViewRepresentable {
    let blockGestures: Bool

    func makeUIView(context: Context) -> PrivacyMarkerView {
        let view = PrivacyMarkerView()
        // Register synchronously so the next snapshot/tap captures
        // already see this marker. Registry holds weak ref so we
        // don't leak the view across SwiftUI re-renders.
        Replay.addPrivacyView(view, blockGestures: blockGestures)
        return view
    }

    func updateUIView(_ uiView: PrivacyMarkerView, context: Context) {
        // blockGestures can change between renders.
        Replay.addPrivacyView(uiView, blockGestures: blockGestures)
    }

    static func dismantleUIView(_ uiView: PrivacyMarkerView, coordinator: ()) {
        Replay.removePrivacyView(uiView)
    }
}

/// Concrete UIView subclass for the marker. Transparent; doesn't
/// draw anything, and never takes a touch. Named subclass (rather
/// than a bare UIView) makes it easy to spot in the view hierarchy
/// debugger and lets us add debug overlays in the future without
/// churning the public surface.
private final class PrivacyMarkerView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        // We don't draw anything; clear out the default drawing path
        // so the renderer doesn't waste a fill on us.
        contentMode = .scaleToFill
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Touches go to the content underneath, never to the marker.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}
#endif // canImport(UIKit)
