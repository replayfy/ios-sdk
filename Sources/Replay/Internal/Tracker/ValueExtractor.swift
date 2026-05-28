import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Extracts the `uiValue` field for a tapped view. Semantics differ
/// per widget type, mirroring the Android `ValueExtractor`:
///
///   - text     → the rendered text
///   - button   → the button title (current state's, not all states')
///   - field    → the *placeholder*, NEVER the contents (privacy floor)
///   - image    → accessibilityLabel / asset name
///   - compound → current state ("on" / "off" / progress)
///   - container/unknown → empty
///
/// Field-content occlusion (never extracting user input) is a
/// non-negotiable security floor — even when `isSensitive=false`.
/// Customers opt into field-content capture via future privacy config
/// (rarely useful for analytics, lots of risk).
enum ValueExtractor {

    /// Max chars per uiValue. Twitter rule; long values are noise.
    private static let maxLength = 280

    #if canImport(UIKit)
    static func extract(_ view: UIView, type: WidgetClassifier.UiType) -> String {
        let raw: String = {
            switch type {
            case .text:
                return extractText(view)
            case .button:
                return extractButtonTitle(view)
            case .field:
                return extractFieldPlaceholder(view)
            case .image:
                return extractImageRef(view)
            case .compound:
                return extractCompoundState(view)
            case .container, .unknown:
                return ""
            }
        }()
        return String(raw.prefix(maxLength))
    }

    private static func extractText(_ view: UIView) -> String {
        if let label = view as? UILabel {
            return label.text ?? label.accessibilityLabel ?? ""
        }
        return view.accessibilityLabel ?? ""
    }

    private static func extractButtonTitle(_ view: UIView) -> String {
        if let button = view as? UIButton {
            // Prefer the current-state title (handles selected/highlighted
            // states correctly). Fall back to .normal then accessibility.
            if let t = button.title(for: button.state), !t.isEmpty { return t }
            if let t = button.title(for: .normal), !t.isEmpty { return t }
            // Image-only button — surface the image's accessibility
            // identifier or the asset name from the configuration.
            if let image = button.image(for: button.state) ?? button.image(for: .normal) {
                if let id = image.accessibilityIdentifier, !id.isEmpty { return id }
            }
            return button.accessibilityLabel ?? ""
        }
        return view.accessibilityLabel ?? ""
    }

    /// Field placeholder extraction. NEVER read `.text` — that's the
    /// user's input (password, message, search query). The tap event
    /// must describe WHICH field was tapped, not its contents.
    private static func extractFieldPlaceholder(_ view: UIView) -> String {
        if let field = view as? UITextField {
            if let p = field.placeholder, !p.isEmpty { return p }
            if let l = field.accessibilityLabel, !l.isEmpty { return l }
        }
        if let search = view as? UISearchBar {
            if let p = search.placeholder, !p.isEmpty { return p }
            return search.accessibilityLabel ?? "Search"
        }
        if view is UITextView {
            // UITextView has no native placeholder; customers typically
            // use accessibilityLabel. NEVER read .text.
            return view.accessibilityLabel ?? ""
        }
        return ""
    }

    private static func extractImageRef(_ view: UIView) -> String {
        if let iv = view as? UIImageView {
            if let id = iv.image?.accessibilityIdentifier, !id.isEmpty { return id }
            if let label = iv.accessibilityLabel, !label.isEmpty { return label }
        }
        return view.accessibilityLabel ?? ""
    }

    private static func extractCompoundState(_ view: UIView) -> String {
        if let sw = view as? UISwitch {
            return sw.isOn ? "on" : "off"
        }
        if let slider = view as? UISlider {
            return String(format: "%.2f", slider.value)
        }
        if let stepper = view as? UIStepper {
            return String(format: "%.0f", stepper.value)
        }
        if let seg = view as? UISegmentedControl {
            if seg.selectedSegmentIndex == UISegmentedControl.noSegment { return "" }
            if let title = seg.titleForSegment(at: seg.selectedSegmentIndex) {
                return title
            }
            return "segment\(seg.selectedSegmentIndex)"
        }
        return view.accessibilityLabel ?? ""
    }
    #endif
}
