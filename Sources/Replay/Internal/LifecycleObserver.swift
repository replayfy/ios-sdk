import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Listens to whole-app fore/background transitions via the
/// `UIApplication` notifications and asks ``LegacyCore`` to rotate
/// sessions accordingly.
///
/// Uses the application-level notifications (rather than UIScene)
/// because they still fire correctly even in modern scene-based
/// apps — the OS posts both. Avoids the extra complexity of
/// per-scene tracking for multi-window iPad apps.
///
/// Mirrors the Android SDK's `SessionLifecycleObserver` which hooks
/// `ProcessLifecycleOwner` for the same semantics.
final class LifecycleObserver {

    private let onForeground: () -> Void
    private let onBackground: () -> Void
    private var observers: [NSObjectProtocol] = []

    init(
        onForeground: @escaping () -> Void,
        onBackground: @escaping () -> Void
    ) {
        self.onForeground = onForeground
        self.onBackground = onBackground
    }

    func attach() {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in self?.onForeground() }
        )
        observers.append(
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in self?.onBackground() }
        )
        // Fire the initial foreground synthetic — `start(with:)` is
        // typically called from didFinishLaunching where the
        // willEnterForeground notification hasn't been (and won't be)
        // posted for the cold-launch case. Without this we'd never
        // get a session_start until the user backgrounds + returns.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if UIApplication.shared.applicationState != .background {
                self.onForeground()
            }
        }
        #endif
    }

    func detach() {
        let center = NotificationCenter.default
        for o in observers { center.removeObserver(o) }
        observers.removeAll()
    }
}
