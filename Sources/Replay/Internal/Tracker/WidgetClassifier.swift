import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Maps a UIView subclass to one of the platform-neutral widget
/// types defined in our schema's `TapEventData.uiType`.
///
/// Same taxonomy across web / iOS / Android / Flutter / RN so the
/// dashboard's heatmap + funnels group by type without forking.
///
/// Classification is by Obj-C class identity / `is`-checks — no
/// reflection on state — so an icon-only UIButton classifies as
/// `button` based on the class, not the title.
enum WidgetClassifier {

    enum UiType: String {
        case button = "button"
        case field = "field"
        case compound = "compound"
        case text = "text"
        case image = "image"
        case container = "container"
        case unknown = "unknown"
    }

    #if canImport(UIKit)
    /// Classify a view. Cheap — only `is`-checks. Order matters:
    /// most-specific subclasses tested first (Switch extends Control
    /// extends View, so we check Switch before Control).
    static func classify(_ view: UIView) -> UiType {
        // Compound controls — Switch, Slider, Stepper, SegmentedControl,
        // DatePicker. Own bucket so the dashboard renders the right
        // widget type in playback.
        if view is UISwitch || view is UISlider || view is UIStepper ||
            view is UISegmentedControl || view is UIDatePicker {
            return .compound
        }

        // Text inputs — UITextField + UITextView (editable) + UISearchBar.
        if view is UITextField || view is UISearchBar {
            return .field
        }
        if let tv = view as? UITextView, tv.isEditable {
            return .field
        }

        // Buttons — UIButton (covers IconButton via image), and the
        // tab/toolbar items render as private UIView subclasses with
        // "Button" in their class name; fall through to that as a
        // last-ditch heuristic below.
        if view is UIButton {
            return .button
        }

        // Image-only views.
        if view is UIImageView {
            return .image
        }

        // Plain labels.
        if view is UILabel {
            return .text
        }

        // Scrollable containers (UITableView extends UIScrollView,
        // UICollectionView extends UIScrollView, so this catches both).
        if view is UIScrollView || view is UIStackView {
            return .container
        }

        // Catch-all for tappable views with user-attached gesture
        // recognizers — generic UIControl, or a UIView the customer
        // explicitly added a UITapGestureRecognizer to.
        if view is UIControl {
            return .button
        }
        if (view.gestureRecognizers?.contains(where: { $0 is UITapGestureRecognizer })) == true {
            return .button
        }

        // Private-class fallback: UIKit's internal "_…Button" /
        // "…BarButton" classes don't subclass UIButton publicly but
        // are tap targets. Sniff by class name as a last resort.
        let className = NSStringFromClass(type(of: view))
        if className.contains("Button") { return .button }

        return .unknown
    }

    /// Whether the view is "interesting enough" to emit a tap event
    /// for. The tap tracker uses this to filter out backgrounds /
    /// containers that happen to receive touches (e.g. a Spacer in
    /// a SwiftUI hierarchy that bubbles up taps to its parent).
    static func isMeaningful(_ view: UIView) -> Bool {
        let type = classify(view)
        return type != .unknown && type != .container
    }
    #endif
}
