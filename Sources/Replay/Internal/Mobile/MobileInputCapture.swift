#if canImport(UIKit)
import UIKit

/// Observes specific `UITextField`s and reports their value when editing ends.
///
/// Mirrors the reference's `addObservedInput`: inputs are opt-in per field (no
/// global auto-capture), the value is read on `.editingDidEnd` (not per
/// keystroke), and a field the frames mask (secure entry, a secure content
/// type, every field while all text fields are masked, a registered or
/// class-masked field) reports a masked placeholder — never the typed text —
/// while the field's `placeholder` is used as the label.
final class MobileInputCapture: NSObject {
    /// `(value, masked, label)` — `value` is `"***"` for masked fields.
    typealias Handler = (_ value: String, _ masked: Bool, _ label: String) -> Void

    var onInput: Handler?

    // Weak refs so observing a field never keeps it (or its view controller)
    // alive — `UIControl` already only weakly retains its targets.
    private let observed = NSHashTable<UITextField>.weakObjects()

    func observe(_ field: UITextField) {
        field.removeTarget(self, action: #selector(editingEnded(_:)), for: .editingDidEnd)
        field.addTarget(self, action: #selector(editingEnded(_:)), for: .editingDidEnd)
        observed.add(field)
    }

    @objc func editingEnded(_ sender: UITextField) {
        // Whatever the frames hide, the event must not carry either.
        let masked = PrivacyRegistry.shared.isOccludedElement(sender)
        let value = masked ? "***" : (sender.text ?? "")
        onInput?(value, masked, sender.placeholder ?? "")
    }
}
#endif
