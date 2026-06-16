#if canImport(UIKit)
import UIKit
import ObjectiveC

/// Captures touches by swizzling `UIWindow.sendEvent`. On touch-end it
/// classifies the gesture — swipe (start→end distance > 10 pt), long-press
/// (held ≥ 0.5 s with little movement), else tap — derives a label from the
/// hit view, and forwards to the engine.
final class MobileTouchCapture {
    /// `kind` is "tap" / "long_press" / "swipe".
    typealias Handler = (_ label: String, _ x: UInt64, _ y: UInt64, _ kind: String, _ direction: String) -> Void

    /// Press held at least this long (with little movement) → long_press.
    private static let longPressThreshold: CFTimeInterval = 0.5

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
        for touch in touches {
            let id = ObjectIdentifier(touch)
            switch touch.phase {
            case .began:
                starts[id] = (touch.location(in: window), CACurrentMediaTime())
            case .ended:
                let end = touch.location(in: window)
                let (start, t0) = starts[id] ?? (end, CACurrentMediaTime())
                starts[id] = nil
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
                guard let label = describe(touch.view) else { break }
                let x = UInt64(max(end.x, 0)), y = UInt64(max(end.y, 0))
                handler(label, x, y, kind, direction(dx, dy))
            case .cancelled:
                starts[id] = nil
            default: break
            }
        }
    }

    private static var starts: [ObjectIdentifier: (CGPoint, CFTimeInterval)] = [:]

    private static func direction(_ dx: CGFloat, _ dy: CGFloat) -> String {
        if abs(dx) > abs(dy) { return dx > 0 ? "right" : "left" }
        if abs(dy) > abs(dx) { return dy > 0 ? "down" : "up" }
        return "right"
    }

    /// Single best label, most-specific first; returns `nil` when the only
    /// thing left to name the view by is a framework/system class (keyboard,
    /// cursor / input accessory, the Flutter / RN engine hosts) — those taps
    /// are dropped, not labelled, so they don't add noise or phantom tap-rage.
    private static func describe(_ view: UIView?) -> String? {
        guard let view = view else { return "view" }
        // RN maps `testID` → accessibilityIdentifier and <Text> →
        // accessibilityLabel; the native iOS reference omits accessibility, but
        // it's what surfaces real RN labels instead of class names. Text fields
        // use the placeholder, never the typed value (privacy).
        if let id = view.accessibilityIdentifier, !id.isEmpty { return id }
        if let b = view as? UIButton,
           let t = b.currentTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            return String(t.prefix(50))
        }
        if let l = view as? UILabel,
           let t = l.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            return String(t.prefix(50))
        }
        if let a = view.accessibilityLabel, !a.isEmpty { return String(a.prefix(50)) }
        if let tf = view as? UITextField, let p = tf.placeholder, !p.isEmpty { return p }
        let cls = "\(type(of: view))"
        return isSystemClassName(cls) ? nil : cls
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
