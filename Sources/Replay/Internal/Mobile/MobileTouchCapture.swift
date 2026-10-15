#if canImport(UIKit)
import UIKit
import ObjectiveC

/// Captures touches by swizzling `UIWindow.sendEvent`. On touch-end it
/// classifies the gesture — swipe (start→end distance > 10 pt), long-press
/// (held ≥ 0.5 s with little movement), else tap — derives a label from the
/// hit view, and forwards to the engine.
final class MobileTouchCapture {
    /// `kind` is "tap" / "long_press" / "swipe" / "pinch" / "rotate".
    typealias Handler = (_ label: String, _ x: UInt64, _ y: UInt64, _ kind: String, _ direction: String) -> Void

    /// Press held at least this long (with little movement) → long_press.
    private static let longPressThreshold: CFTimeInterval = 0.5

    /// Advanced gestures (pinch / rotate). Off by default — correlating the two
    /// touches every event costs nothing until a host opts in via
    /// `Replay.enableAdvancedGestureRecognizer(true)`. tap/swipe/long_press are
    /// always on regardless of this flag.
    static var advancedGesturesEnabled = false

    private static var handler: Handler?
    private static var swizzled = false

    func install(_ handler: @escaping Handler) {
        MobileTouchCapture.handler = handler
        guard !MobileTouchCapture.swizzled else { return }
        MobileTouchCapture.swizzled = true
        let original = #selector(UIWindow.sendEvent(_:))
        let swizzled = #selector(UIWindow.replay_sendEvent(_:))
        if let o = class_getInstanceMethod(UIWindow.self, original),
           let s = class_getInstanceMethod(UIWindow.self, swizzled) {
            method_exchangeImplementations(o, s)
        }
    }

    func uninstall() {
        MobileTouchCapture.handler = nil
    }

    static func capture(event: UIEvent, in window: UIWindow) {
        guard let handler = handler, event.type == .touches,
              let touches = event.allTouches else { return }
        // Advanced multi-touch (pinch / rotate) is correlated separately and
        // marks its two touches "consumed" so the single-touch classifier below
        // doesn't ALSO emit a pair of swipes for the same gesture.
        if advancedGesturesEnabled { handleMultiTouch(touches, in: window) }
        for touch in touches {
            let id = ObjectIdentifier(touch)
            // Skip touches already accounted for by a two-finger gesture; clear
            // them from the consumed set as they lift.
            if consumedByGesture.contains(id) {
                if touch.phase == .ended || touch.phase == .cancelled {
                    starts[id] = nil
                    consumedByGesture.remove(id)
                }
                continue
            }
            switch touch.phase {
            case .began:
                let point = touch.location(in: window)
                // A gesture that STARTS in a view registered with
                // blockGestures is not recorded (the reference rule); the
                // app still gets it.
                let blocked = PrivacyRegistry.shared.isGestureBlocked(at: point, in: window)
                starts[id] = TouchStart(point: point, time: CACurrentMediaTime(), blocked: blocked,
                                        view: touch.view)
            case .ended:
                let end = touch.location(in: window)
                let began = starts[id]
                let (start, t0, blocked) = (began?.point ?? end, began?.time ?? CACurrentMediaTime(),
                                            began?.blocked ?? false)
                starts[id] = nil
                if blocked { break }
                let dx = end.x - start.x, dy = end.y - start.y
                let kind: String
                if hypot(dx, dy) > 10 {
                    kind = "swipe"
                } else if CACurrentMediaTime() - t0 >= longPressThreshold {
                    kind = "long_press"
                } else {
                    kind = "tap"
                }
                // Drop taps on framework/system views (keyboard, FlutterView, …)
                // — describe returns nil for those.
                guard let label = gestureLabel(ended: touch.view, began: began?.view,
                                               at: end, in: window) else { break }
                let x = UInt64(max(end.x, 0)), y = UInt64(max(end.y, 0))
                handler(label, x, y, kind, direction(dx, dy))
            case .cancelled:
                starts[id] = nil
            default: break
            }
        }
    }

    /// Where and when a touch began, whether it began in a view whose
    /// gestures are blocked, and the view it began in.
    private struct TouchStart {
        let point: CGPoint
        let time: CFTimeInterval
        let blocked: Bool
        weak var view: UIView?
    }
    private static var starts: [ObjectIdentifier: TouchStart] = [:]

    /// The label of a finished gesture: ``describe(_:)`` of the view it
    /// ended in. A touch a gesture recognizer took over (text fields and web
    /// views have their own) ends with no view on iOS 26, and was labelled
    /// "view" whatever it touched, so a tap on a masked field never came out
    /// as "***". Then the view it began in names it, or failing that the
    /// view under where it ended; when neither can (a framework view), it
    /// keeps the generic "view" it always had.
    static func gestureLabel(ended: UIView?, began: UIView?, at point: CGPoint, in window: UIWindow) -> String? {
        if let ended { return describe(ended) }
        let view = (began?.window === window ? began : nil) ?? window.hitTest(point, with: nil)
        return describe(view) ?? "view"
    }

    // ── Advanced multi-touch (pinch / rotate) ────────────────────────
    // Correlate exactly two simultaneous touches: capture their initial
    // separation + angle when the second finger lands, track the latest as they
    // move, and emit ONCE when a finger lifts. Two-finger scrolls / accidental
    // double-touches stay below threshold and are dropped.
    private static var pinchTracking = false
    private static var pinchEmitted = false
    private static var pinchInitialDistance: CGFloat = 0
    private static var pinchInitialAngle: CGFloat = 0
    private static var pinchLastDistance: CGFloat = 0
    private static var pinchLastAngle: CGFloat = 0
    private static var pinchCenter: CGPoint = .zero
    /// The two-finger gesture began in a view whose gestures are blocked.
    private static var pinchBlocked = false
    /// Touch ids owned by the active two-finger gesture — the single-touch
    /// classifier ignores these so a pinch isn't double-counted as two swipes.
    private static var consumedByGesture: Set<ObjectIdentifier> = []

    private static func handleMultiTouch(_ touches: Set<UITouch>, in window: UIWindow) {
        let down = touches.filter { $0.phase == .began || $0.phase == .moved || $0.phase == .stationary }
        if down.count == 2 {
            let a = down.first!.location(in: window)
            let b = down.dropFirst().first!.location(in: window)
            let dist = hypot(a.x - b.x, a.y - b.y)
            let ang = atan2(b.y - a.y, b.x - a.x)
            if !pinchTracking {
                pinchTracking = true
                pinchEmitted = false
                pinchInitialDistance = dist
                pinchInitialAngle = ang
                pinchBlocked = PrivacyRegistry.shared.isGestureBlocked(at: a, in: window)
                    || PrivacyRegistry.shared.isGestureBlocked(at: b, in: window)
            }
            consumedByGesture.formUnion(down.map { ObjectIdentifier($0) })
            pinchLastDistance = dist
            pinchLastAngle = ang
            pinchCenter = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        } else if pinchTracking && down.count < 2 {
            emitPinchRotate(in: window)
            pinchTracking = false
        }
    }

    private static func emitPinchRotate(in window: UIWindow) {
        guard let handler = handler, !pinchEmitted, pinchInitialDistance > 1 else { return }
        pinchEmitted = true
        if pinchBlocked { return }
        let scale = pinchLastDistance / pinchInitialDistance
        var angleDelta = pinchLastAngle - pinchInitialAngle
        while angleDelta > .pi { angleDelta -= 2 * .pi }   // normalize to [-π, π]
        while angleDelta < -.pi { angleDelta += 2 * .pi }

        let label = describe(window.hitTest(pinchCenter, with: nil)) ?? "view"
        let x = UInt64(max(pinchCenter.x, 0)), y = UInt64(max(pinchCenter.y, 0))
        // Pinch when separation changed ≥15%; rotate when the line between the
        // fingers turned ≥15°. Emit whichever crossed its threshold (both if the
        // user did both). `direction` carries the sense: pinch out/in (spread /
        // close), rotate cw/ccw.
        if abs(scale - 1) >= 0.15 {
            handler(label, x, y, "pinch", scale >= 1 ? "out" : "in")
        }
        if abs(angleDelta) >= (.pi / 12) {
            handler(label, x, y, "rotate", angleDelta >= 0 ? "cw" : "ccw")
        }
    }

    private static func direction(_ dx: CGFloat, _ dy: CGFloat) -> String {
        if abs(dx) > abs(dy) { return dx > 0 ? "right" : "left" }
        if abs(dy) > abs(dx) { return dy > 0 ? "down" : "up" }
        return "right"
    }

    /// Single best label, most-specific first; returns `nil` when the only
    /// thing left to name the view by is a framework/system class (keyboard,
    /// cursor / input accessory, the Flutter / RN engine hosts) — those taps
    /// are dropped, not labelled, so they don't add noise or phantom tap-rage.
    /// A view whose content the frames hide is labelled `"***"`, as the
    /// reference tracker blanks the content of an occluded element.
    static func describe(_ view: UIView?) -> String? {
        guard let view = view else { return "view" }
        // RN maps `testID` → accessibilityIdentifier and <Text> →
        // accessibilityLabel; the native iOS reference omits accessibility, but
        // it's what surfaces real RN labels instead of class names. Text fields
        // use the placeholder, never the typed value (privacy).
        if let id = view.accessibilityIdentifier, !id.isEmpty { return id }
        let (label, isText) = contentLabel(view)
        // Secure / password-type fields, every field while all are masked,
        // registered or class-masked views and their content, views under a
        // marker, or the whole screen occluded. Like the reference tracker,
        // taps on masked text inputs are kept with the content blanked (they
        // used to be dropped as system views); framework hosts stay dropped.
        if PrivacyRegistry.shared.isOccludedElement(view) {
            return label != nil || isInsideTextInput(view) ? "***" : nil
        }
        // While every label is masked, so is the text a button, segment, bar
        // button or placeholder draws (in a UILabel the frames cover), and
        // the accessibility label that usually repeats it.
        if isText && PrivacyRegistry.shared.occludeAllTextViews { return "***" }
        return label
    }

    /// ``describe(_:)`` before any masking, and whether the label is text
    /// shown on screen (a title, text, accessibility label or placeholder)
    /// rather than the view's class name.
    private static func contentLabel(_ view: UIView) -> (String?, isText: Bool) {
        if let b = view as? UIButton,
           let t = b.currentTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            return (String(t.prefix(50)), true)
        }
        if let l = view as? UILabel,
           let t = l.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            return (String(t.prefix(50)), true)
        }
        if let a = view.accessibilityLabel, !a.isEmpty { return (String(a.prefix(50)), true) }
        if let tf = view as? UITextField, let p = tf.placeholder, !p.isEmpty { return (p, true) }
        let cls = "\(type(of: view))"
        return (isSystemClassName(cls) ? nil : cls, false)
    }

    /// A text field or text view, or one of its internal subviews.
    private static func isInsideTextInput(_ view: UIView) -> Bool {
        var cur: UIView? = view
        while let c = cur {
            if c is UITextField || c is UITextView { return true }
            cur = c.superview
        }
        return false
    }

    /// Framework/system view classes whose taps are noise rather than app
    /// interactions: UIKit internals (`UI…` / `_UI…`, e.g. the keyboard cursor
    /// accessory), react-native-screens (`RNS…`), React Native internals
    /// (`RCT…`), and the Flutter engine host (`Flutter…`). Mirrors the
    /// ingest-side denylist so signal stays consistent across SDKs.
    private static func isSystemClassName(_ name: String) -> Bool {
        var n = Substring(name)
        if n.first == "_" { n = n.dropFirst() }
        if n.hasPrefix("RNS") || n.hasPrefix("RCT") || n.hasPrefix("Flutter") { return true }
        if n.hasPrefix("UI") {
            let third = n.index(n.startIndex, offsetBy: 2)
            return third < n.endIndex && n[third].isUppercase
        }
        return false
    }
}

extension UIWindow {
    @objc fileprivate func replay_sendEvent(_ event: UIEvent) {
        self.replay_sendEvent(event) // calls original (swapped)
        MobileTouchCapture.capture(event: event, in: self)
    }
}
#endif
