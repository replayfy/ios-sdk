import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Captures every tap across every active window.
///
/// Strategy: install a single ``UIGestureRecognizer`` on each
/// `UIWindow` with `cancelsTouchesInView = false`, `delaysTouches*
/// = false` so we observe taps without interfering with the host
/// app's gesture handling. On `.began`, hit-test the touch location
/// to find the touched view, walk up to the most-specific
/// meaningful ancestor, classify, extract value, emit.
///
/// Why per-window injection rather than UIApplication.sendEvent
/// swizzling: swizzling system methods is fragile, frowned upon by
/// reviewers (App Store risk), and breaks under SwiftUI's hosting
/// views. UIGestureRecognizer injection is the documented Apple way
/// to observe touches, and matches what UXCam ships per their
/// public `+GetGestureRecognizers` API.
///
/// Mirrors the Android SDK's `TapTracker.kt`. We keep the same
/// shape so cross-platform debugging stays symmetric.
final class TapTracker: NSObject {

    private let emit: (TapEventData) -> Void

    /// Current screen name — defaults to top UIViewController's
    /// class name, can be overridden by `Replay.tagScreenName`.
    private var _route: String = "/"
    private let routeLock = NSLock()

    var currentRoute: String {
        get { routeLock.withLock { _route } }
        set { routeLock.withLock { _route = newValue } }
    }

    #if canImport(UIKit)
    /// Windows we've already attached our recognizer to. Weak so
    /// detached windows are auto-evicted.
    private let attached = NSHashTable<UIWindow>.weakObjects()
    private var windowDidBecomeKeyObserver: NSObjectProtocol?
    #endif

    init(emit: @escaping (TapEventData) -> Void) {
        self.emit = emit
        super.init()
    }

    func attach() {
        #if canImport(UIKit)
        attachToExistingWindows()
        // New windows can appear at any time (modal presentations,
        // SwiftUI scenes, UIAlertController). Subscribe to the
        // didBecomeKey notification so we catch them.
        windowDidBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            if let window = note.object as? UIWindow {
                self?.attachToWindowIfNeeded(window)
            }
        }
        #endif
    }

    func detach() {
        #if canImport(UIKit)
        if let obs = windowDidBecomeKeyObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        // Recognizers stay on the windows; UIKit cleans them up
        // when the window is deallocated. Removing them now would
        // require enumerating + identifying our recognizer by
        // delegate identity, which adds complexity without payoff.
        #endif
    }

    #if canImport(UIKit)
    /// Scan currently-known windows and attach to each. Called once
    /// at attach time, and again from the didBecomeKey observer.
    private func attachToExistingWindows() {
        // UIApplication.windows is deprecated in iOS 15+ in favour
        // of per-scene window lookup. Walk the connected scenes
        // instead — works back to iOS 13.
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                attachToWindowIfNeeded(window)
            }
        }
    }

    private func attachToWindowIfNeeded(_ window: UIWindow) {
        if attached.contains(window) { return }
        let recognizer = UITapAndPanRecognizer(target: self, action: #selector(onTouch(_:)))
        recognizer.delegate = self
        // Critical flags — without these, our recognizer would
        // swallow events that should reach the app's own buttons.
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        window.addGestureRecognizer(recognizer)
        attached.add(window)
    }

    @objc private func onTouch(_ recognizer: UIGestureRecognizer) {
        guard recognizer.state == .began else { return }
        guard let view = recognizer.view else { return }
        let location = recognizer.location(in: view)
        captureTap(at: location, in: view)
    }

    /// Hit-test → walk up → classify → emit.
    private func captureTap(at location: CGPoint, in rootView: UIView) {
        // Hit-test the root window. May return a deep descendant
        // (label inside a button cell). We walk up until we find
        // the most-specific MEANINGFUL ancestor.
        guard let hit = rootView.hitTest(location, with: nil) else { return }

        let target = mostSpecificMeaningfulAncestor(of: hit) ?? hit
        let type = WidgetClassifier.classify(target)
        if type == .unknown { return }

        // Privacy check — if the tapped view (or any ancestor) is
        // marked sensitive, we blank out uiClass / uiValue / uiId
        // so the wire event carries only the fact that *a tap
        // happened in this region* — never WHICH button or WHAT
        // text. The dashboard renders these as a generic
        // "sensitive tap" marker.
        let isSensitive = PrivacyRegistry.shared.isSensitive(target)
        let uiClass = isSensitive
            ? ""
            : (NSStringFromClass(Swift.type(of: target))
                .components(separatedBy: ".").last ?? "View")
        let uiValue = isSensitive ? "" : ValueExtractor.extract(target, type: type)
        let uiId = isSensitive
            ? "\(currentRoute):sensitive"
            : UiIdHasher.uiId(route: currentRoute, uiClass: uiClass, uiValue: uiValue)

        // Convert points → device pixels for parity with Android
        // (which ships pixel bounds). Scale factor differs per device.
        let scale = target.window?.screen.scale ?? UIScreen.main.scale
        let frameInWindow = target.convert(target.bounds, to: nil)
        let bounds = TapBounds(
            x: Int(frameInWindow.minX * scale),
            y: Int(frameInWindow.minY * scale),
            w: Int(frameInWindow.width * scale),
            h: Int(frameInWindow.height * scale),
        )
        // Tap point in window coordinates × scale.
        let pointInWindow = rootView.convert(location, to: nil)
        let point = TapPoint(
            x: Int(pointInWindow.x * scale),
            y: Int(pointInWindow.y * scale),
        )

        let tap = TapEventData(
            bounds: bounds,
            point: point,
            route: currentRoute,
            uiClass: uiClass,
            uiType: isSensitive ? "unknown" : type.rawValue,
            uiValue: uiValue,
            uiId: uiId,
            isSensitive: isSensitive,
        )
        emit(tap)
    }

    /// Walk up the superview chain to find the most-specific view
    /// that's meaningful per `WidgetClassifier.isMeaningful`. If the
    /// touch landed on a label INSIDE a button, we want the button
    /// — the label's text is interesting context, but the user
    /// tapped a "button".
    private func mostSpecificMeaningfulAncestor(of view: UIView) -> UIView? {
        var current: UIView? = view
        while let v = current {
            if WidgetClassifier.isMeaningful(v) { return v }
            current = v.superview
        }
        return nil
    }
    #endif
}

#if canImport(UIKit)
extension TapTracker: UIGestureRecognizerDelegate {
    // Recognize alongside everything else — never block the app.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }

    // Don't require any other recognizer to fail before us.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf other: UIGestureRecognizer
    ) -> Bool { false }
}

/// Custom recognizer that fires on the first touch begin and never
/// fails (because we want to observe, not own, gestures). Standard
/// UITapGestureRecognizer waits for the touch to end before firing
/// — too late for us; the view's state may have already changed.
private final class UITapAndPanRecognizer: UIGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        // Set state to .began so target/action fires immediately on
        // the down-event. We never transition to .ended; the
        // recognizer just resets for the next touch.
        state = .began
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        state = .ended
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        state = .cancelled
    }
    override func reset() {
        super.reset()
    }
}
#endif
