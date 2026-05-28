import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Builds the ``ReplayPageContext`` we attach to every batch.
///
/// Native sessions don't have a URL, so we synthesize a
/// `replay://app/{bundleId}/{screen}` deep-link style identifier.
/// `tagScreenName(_:)` rewrites the trailing segment so the
/// dashboard's path filters work the same as for web.
enum DeviceContext {

    static func build() -> ReplayPageContext {
        ReplayPageContext(
            url: synthesizedUrl(),
            userAgent: userAgent(),
            viewport: viewport(),
            title: nil,
            referrer: nil,
            timezone: TimeZone.current.identifier,
            language: Locale.current.identifier
        )
    }

    // MARK: -

    private static func synthesizedUrl() -> String {
        let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
        return "replay://app/\(bundleId)"
    }

    private static func userAgent() -> String {
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        let bundleId = Bundle.main.bundleIdentifier ?? "?"
        #if canImport(UIKit)
        let device = UIDevice.current
        return "\(BuildInfo.sdkName)/\(BuildInfo.sdkVersion) " +
            "(\(bundleId)/\(appVersion); \(deviceModelIdentifier()); " +
            "\(device.systemName) \(device.systemVersion))"
        #else
        // macOS / Linux build (tests) — fall back to a minimal UA.
        return "\(BuildInfo.sdkName)/\(BuildInfo.sdkVersion) (\(bundleId)/\(appVersion))"
        #endif
    }

    private static func viewport() -> ViewportDimensions {
        #if canImport(UIKit)
        let screen = UIScreen.main.bounds
        let scale = UIScreen.main.scale
        // Native viewport is in *device pixels* (matches what the
        // snapshot pipeline will capture) — multiply by the scale
        // factor so the dashboard's `width × height` pill shows the
        // raw screen size, not the points.
        return ViewportDimensions(
            width: Int(screen.width * scale),
            height: Int(screen.height * scale)
        )
        #else
        return ViewportDimensions(width: 0, height: 0)
        #endif
    }

    #if canImport(UIKit)
    /// The hardware model identifier — e.g. `iPhone15,2` for the
    /// iPhone 14 Pro. UIDevice.model returns just "iPhone" / "iPad"
    /// which is too coarse for analytics.
    ///
    /// Uses `uname()` to read the machine identifier; the standard
    /// trick documented by Apple in TN2002.
    private static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { partial, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            partial.append(Character(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? UIDevice.current.model : identifier
    }
    #endif
}
