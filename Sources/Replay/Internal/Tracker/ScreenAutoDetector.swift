#if canImport(UIKit)
import Foundation
import UIKit
import ObjectiveC.runtime

/// Auto-detects screen changes by swizzling
/// `UIViewController.viewDidAppear(_:)` and reporting the appearing
/// VC's class name as the current screen.
///
/// Why swizzle vs alternatives:
///
///   - `UINavigationControllerDelegate` only works for VCs pushed
///     onto a UINavigationController — modal presentations + tab
///     bars + custom containers all bypass it.
///   - `NotificationCenter` for `UIWindowSceneActivationDidChange`
///     only fires on app-level transitions, not per-VC navigation.
///   - Swizzling viewDidAppear is what every iOS analytics SDK does
///     (UXCam, Mixpanel, Amplitude, Sentry, Datadog) because it's
///     the ONE hook that fires for every visible-screen change
///     regardless of presentation style.
///
/// Safety: we swizzle ONCE per process (`dispatch_once` via
/// `enabled` flag), chain to the original implementation (so
/// customer code in viewDidAppear continues to run), and filter
/// out internal UIKit / Apple containers (`UINavigationController`,
/// `UITabBarController`, `UISplitViewController`, alert / preview
/// controllers, etc.) so the route reflects the USER-visible screen
/// rather than the wrapping chrome.
///
/// Mirrors the Android SDK's auto-detection (TapTracker.updateRoute
/// fires on every `onActivityResumed` with `activity.javaClass.simpleName`).
/// Customers who don't want auto-detection set
/// `ReplayConfig(autoScreenName: false)` to opt out — explicit
/// `Replay.tagScreenName(...)` still works.
final class ScreenAutoDetector {

    /// Called with the detected screen name (typically the VC's
    /// class name). Wired by ReplayCore to ReplayCore.setRoute.
    static var onScreenChange: ((String) -> Void)?

    /// Runtime kill switch for the auto-tagger. Default-true so the
    /// existing ReplayConfig.autoScreenName behaviour is preserved
    /// — flipping to false makes the swizzled viewDidAppear no-op
    /// without un-swizzling (which is fragile in production). Wired
    /// from ``Replay/setAutomaticScreenNameTagging(_:)`` so customers
    /// can toggle per-flow at runtime.
    static var enabled: Bool = true

    /// Has the swizzle been installed? Idempotent — repeated
    /// `enable()` calls are no-ops.
    private static var installed = false
    private static let installLock = NSLock()

    /// Install the swizzle. Must be called from main thread (Apple's
    /// docs say class swizzling is safe from any thread, but the
    /// runtime APIs we use accept method modification from main
    /// only in practice — observed CFRunLoop issues otherwise).
    static func enable() {
        installLock.lock()
        defer { installLock.unlock() }
        if installed { return }
        installed = true

        let cls: AnyClass = UIViewController.self
        let original = #selector(UIViewController.viewDidAppear(_:))
        let swizzled = #selector(UIViewController.replay_viewDidAppear(_:))

        guard
            let originalMethod = class_getInstanceMethod(cls, original),
            let swizzledMethod = class_getInstanceMethod(cls, swizzled)
        else {
            // Shouldn't happen — viewDidAppear is a base UIKit method.
            // Fail silently so we don't crash the host app.
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }
}

extension UIViewController {

    /// The swizzled body. After installation, this runs every time
    /// any UIViewController's viewDidAppear fires (the original
    /// implementation is now reachable by calling this method's
    /// selector — `method_exchangeImplementations` swaps the IMPs,
    /// so `super.viewDidAppear` from inside this body actually
    /// calls our OWN body recursively. We use the simpler `replay_`
    /// approach: do our work, then call the swapped IMP via
    /// `self.replay_viewDidAppear(animated)` which after the swap
    /// IS the original UIKit implementation.).
    @objc func replay_viewDidAppear(_ animated: Bool) {
        // Chain to the original viewDidAppear FIRST so customer code
        // + UIKit internals run before our analytics work — keeps
        // any side effects in the right order.
        self.replay_viewDidAppear(animated)

        // Skip container / system VCs that don't represent a
        // user-visible "screen" change on their own.
        if shouldSkipForAutoRoute() { return }
        // Skip the very-bottom-window's root VC swap (it fires
        // immediately on app launch with empty content sometimes);
        // we'd see it as a noisy duplicate of the real first screen.
        if self.view.window == nil { return }
        // Runtime kill-switch — customers can flip
        // Replay.setAutomaticScreenNameTagging(false) for a specific
        // modal flow and back on when they leave it.
        if !ScreenAutoDetector.enabled { return }

        let name = String(describing: type(of: self))
        ScreenAutoDetector.onScreenChange?(name)
    }

    /// Filter out UIKit / system-provided container VCs. The
    /// USER navigates between content VCs; they don't experience
    /// `UINavigationController` as a screen.
    fileprivate func shouldSkipForAutoRoute() -> Bool {
        // String-class match avoids importing optional frameworks
        // (UIKit + Safari + others all define their own internals
        // here). Compile-checked when the class is in stdlib.
        let cls = String(describing: type(of: self))
        return cls == "UINavigationController"
            || cls == "UITabBarController"
            || cls == "UISplitViewController"
            || cls == "UIPageViewController"
            || cls == "UIAlertController"
            || cls == "UIInputViewController"
            || cls.hasPrefix("_")                    // private Apple subclasses
            || cls.hasPrefix("UICompatibility")
            || cls.hasPrefix("UISystem")
            || cls.hasPrefix("SFAuthentication")     // ASWebAuthenticationSession internals
            || cls.hasPrefix("UIRemote")             // Remote keyboard, etc.
            || cls.hasPrefix("UIEditingOverlay")
    }
}
#endif
