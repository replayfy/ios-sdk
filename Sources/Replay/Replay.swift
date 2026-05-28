import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Public entry point for the Replay iOS SDK.
///
/// Most apps only need ``start(with:)`` — everything else (snapshot
/// capture, tap tracking, screen tagging, lifecycle management) runs
/// automatically once start returns.
///
/// API parallels the Android SDK's `Replay` object so cross-platform
/// codebases (and our own docs) stay symmetric. We don't subclass
/// UXCam's `+optInOverall`-style API surface 1:1 — we adopt the
/// modern Swift idioms (lowercase methods, structured concurrency,
/// optional params) while keeping the underlying capabilities the same.
///
/// Foundation v0: ``start(with:)`` + ``identify(_:properties:)`` +
/// ``track(_:properties:)`` + ``stop()`` + ``isRecording``. The rest
/// (``tagScreenName(_:)``, ``addPrivacyView(_:)``, ``pauseRecording()``,
/// ``resumeRecording()``, ``cancelSession()``) ship as stubs that log
/// + no-op until their respective engines land in follow-up commits.
public enum Replay {

    /// Initialize the SDK and start recording. Call once per process
    /// from `application(_:didFinishLaunchingWithOptions:)`.
    ///
    /// Subsequent calls are ignored (with a console warning) so a
    /// misconfigured AppDelegate can't double-instantiate the runtime.
    ///
    /// Unlike Android, iOS has no `ContentProvider` equivalent that
    /// runs before the customer's code, so the SDK only comes alive
    /// when ``start(with:)`` is called. Take care to invoke this
    /// EARLY (before any other SDK code paths) so we don't miss
    /// initial state.
    public static func start(with config: ReplayConfig) {
        ReplayCore.shared.start(config: config)
    }

    /// Attach a known-user identity to the current session. Anonymous
    /// sessions from this device retroactively link to the identified
    /// user on the dashboard.
    ///
    /// - Parameters:
    ///   - distinctId: Stable id from your auth system. Email, uuid,
    ///                 numeric id all work.
    ///   - properties: Optional user-level traits. Surface in the
    ///                 dashboard as filterable fields.
    public static func identify(
        _ distinctId: String,
        properties: [String: Any]? = nil
    ) {
        ReplayCore.shared.identify(distinctId: distinctId, properties: properties)
    }

    /// Fire a custom event onto the timeline. Drives the "Event"
    /// step kind in funnels + any event-based filters on the dashboard.
    ///
    /// - Parameters:
    ///   - name: Stable event name (snake_case or camelCase, no
    ///           spaces — searchable in the dashboard).
    ///   - properties: Optional metadata. Capped to 20 keys / 200
    ///                 chars per string value.
    public static func track(
        _ name: String,
        properties: [String: Any]? = nil
    ) {
        ReplayCore.shared.track(name: name, properties: properties)
    }

    /// Manually end the current session and force-upload the in-memory
    /// batch. The next foregrounding triggers a fresh session.
    ///
    /// Most apps never need this — the lifecycle observer handles
    /// session boundaries automatically. Use this for opt-out flows
    /// or end-of-onboarding screens where you want the session to
    /// close immediately rather than at next backgrounding.
    public static func stop() {
        ReplayCore.shared.stop()
    }

    /// Whether the SDK is currently recording. Returns false when
    /// `start(with:)` hasn't been called, when the user is opted
    /// out, or when a sampling decision dropped the current session.
    public static var isRecording: Bool {
        ReplayCore.shared.isRecording
    }

    // MARK: - Stubs (engine in follow-up commits)

    /// Tag the current screen with a name. Manual override for the
    /// auto-tagger (which uses `UIViewController` class names by default).
    public static func tagScreenName(_ name: String) {
        ReplayCore.shared.setRoute(name)
    }

    #if canImport(UIKit)
    /// Mark a view as privacy-sensitive — its contents won't appear
    /// in playback, taps on it are blanked.
    public static func addPrivacyView(_ view: UIView) {
        ReplayCore.shared.stub("addPrivacyView(\(type(of: view)))")
    }

    /// Remove a previously-added privacy mark.
    public static func removePrivacyView(_ view: UIView) {
        ReplayCore.shared.stub("removePrivacyView(\(type(of: view)))")
    }
    #endif

    /// Pause schematic capture; events keep flowing.
    public static func pauseRecording() {
        ReplayCore.shared.stub("pauseRecording")
    }

    /// Resume schematic capture after `pauseRecording`.
    public static func resumeRecording() {
        ReplayCore.shared.stub("resumeRecording")
    }

    /// Discard the current session entirely — no upload.
    public static func cancelSession() {
        ReplayCore.shared.stub("cancelSession")
    }
}
