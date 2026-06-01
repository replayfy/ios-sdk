#if canImport(UIKit)
import UIKit
import ObjectiveC

/// Captures touches by swizzling `UIWindow.sendEvent`. On touch-end it
/// classifies tap vs swipe (start→end distance > 10 pt) + direction,
/// derives a label from the hit view, and forwards to the engine.
final class MobileTouchCapture {
    typealias Handler = (_ label: String, _ x: UInt64, _ y: UInt64, _ isSwipe: Bool, _ direction: String) -> Void

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
                starts[id] = touch.location(in: window)
            case .ended:
                let end = touch.location(in: window)
                let start = starts[id] ?? end
                starts[id] = nil
                let dx = end.x - start.x, dy = end.y - start.y
                let isSwipe = hypot(dx, dy) > 10
                let label = describe(touch.view)
                let x = UInt64(max(end.x, 0)), y = UInt64(max(end.y, 0))
                handler(label, x, y, isSwipe, direction(dx, dy))
            case .cancelled:
                starts[id] = nil
            default: break
            }
        }
    }

    private static var starts: [ObjectIdentifier: CGPoint] = [:]

    private static func direction(_ dx: CGFloat, _ dy: CGFloat) -> String {
        if abs(dx) > abs(dy) { return dx > 0 ? "right" : "left" }
        if abs(dy) > abs(dx) { return dy > 0 ? "down" : "up" }
        return "right"
    }

    private static func describe(_ view: UIView?) -> String {
        guard let view = view else { return "UIView" }
        if let b = view as? UIButton { return "UIButton '\(b.currentTitle ?? "")'" }
        if let l = view as? UILabel { return "UILabel '\(l.text ?? "")'" }
        if let t = view as? UITextField { return "UITextField '\(t.placeholder ?? "")'" }
        return "\(type(of: view))"
    }
}

extension UIWindow {
    @objc fileprivate func replay_sendEvent(_ event: UIEvent) {
        self.replay_sendEvent(event) // calls original (swapped)
        MobileTouchCapture.capture(event: event, in: self)
    }
}
#endif
