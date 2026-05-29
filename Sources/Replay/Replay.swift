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
    /// in playback, taps on it are blanked, and the view tree
    /// snapshot reports it as `occluded`.
    ///
    /// Marks propagate down the view hierarchy: marking a
    /// `UIStackView` automatically protects every subview without
    /// per-leaf calls. Removing the mark from a parent (via
    /// ``removePrivacyView(_:)``) restores subview visibility
    /// unless they were independently marked.
    public static func addPrivacyView(_ view: UIView) {
        PrivacyRegistry.shared.add(view)
    }

    /// Remove a previously-added privacy mark. Safe to call even
    /// for views that were never marked.
    public static func removePrivacyView(_ view: UIView) {
        PrivacyRegistry.shared.remove(view)
    }

    /// Occlude every `UITextField` and `UITextView` in the host app
    /// regardless of whether it's been explicitly registered via
    /// ``addPrivacyView(_:)``. Useful default-on PII protection when
    /// the app routinely handles sensitive input.
    ///
    /// Mirrors UXCam's `occludeAllTextFields(_:)`.
    public static func occludeAllTextFields(_ occlude: Bool) {
        PrivacyRegistry.shared.occludeAllTextFields = occlude
    }

    /// Occlude every `UILabel` — anything that DISPLAYS read-only
    /// text. Pair with ``occludeAllTextFields(_:)`` to redact 100%
    /// of textual content in the captured snapshot.
    ///
    /// Mirrors UXCam's `occludeAllTextView(_:)`.
    public static func occludeAllTextView(_ occlude: Bool = true) {
        PrivacyRegistry.shared.occludeAllTextViews = occlude
    }

    /// Paint the ENTIRE captured snapshot with the diagonal-stripe
    /// occlusion overlay. Nuclear option for screens where the
    /// customer doesn't want ANY pixel data to leave the device
    /// (health records, banking pin pad, etc.). Set false to
    /// restore normal capture.
    ///
    /// Mirrors UXCam's `occludeSensitiveScreen(_:)`.
    public static func occludeSensitiveScreen(_ occlude: Bool) {
        PrivacyRegistry.shared.occludeAllScreen = occlude
    }

    /// Paint the diagonal-stripe overlay over a set of `CGRect`
    /// regions on the NEXT snapshot only. Entry point for
    /// cross-platform SDK bridges (React Native, Flutter) whose
    /// components don't have native `UIView` references — the
    /// bridge calculates rects on the JS / Dart side
    /// (RN `measureInWindow`, Flutter `RenderBox.localToGlobal`)
    /// and hands them here in root-relative points.
    ///
    /// One-shot: the rects clear once a snapshot fires. Bridges
    /// call this every frame (or before any capture they want
    /// occluded). Calling it again without a snapshot in between
    /// REPLACES (does not append to) the prior set.
    ///
    /// Mirrors UXCam's `occludeRectsOnNextFrame(rects)`.
    public static func occludeRectsOnNextFrame(_ rects: [CGRect]) {
        PrivacyRegistry.shared.setPendingFrameRects(rects)
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

    /// Attach a sticky property to the END USER (persists across
    /// sessions, attached to the EndUser row server-side). Distinct
    /// from `track` event properties which only attach to a single
    /// event.
    ///
    /// Mirrors UXCam's `setUserProperty(_:, _:)` per-primitive
    /// overloads — Swift's `Any?` subsumes them.
    ///
    /// Common use: `Replay.setUserProperty("plan", value: "pro")`
    /// or `Replay.setUserProperty("signupSource", value: "google_ads")`.
    public static func setUserProperty(_ key: String, value: Any?) {
        ReplayCore.shared.setUserProperty(key, value: value)
    }

    /// Attach a sticky property to the CURRENT SESSION. Visible on
    /// the dashboard as a Session-level field (chip on the player
    /// header — dashboard wiring is a separate task).
    ///
    /// Use for ephemeral per-session context:
    /// `Replay.setSessionProperty("ab_variant", value: "B")`,
    /// `Replay.setSessionProperty("checkout_step", value: "shipping")`.
    public static func setSessionProperty(_ key: String, value: Any?) {
        ReplayCore.shared.setSessionProperty(key, value: value)
    }

    // -----------------------------------------------------------------
    //  UXCam-parity session-control surface
    // -----------------------------------------------------------------

    /// Toggle the UIViewController.viewDidAppear auto-tagger on/off
    /// at runtime. Default-on (via `ReplayConfig.autoScreenName`);
    /// flip false to drive routes manually via ``tagScreenName(_:)``
    /// for a flow where VC class names don't map cleanly to
    /// user-meaningful screens.
    ///
    /// Mirrors UXCam's `setAutomaticScreenNameTagging(_:)`.
    public static func setAutomaticScreenNameTagging(_ enabled: Bool) {
        ReplayCore.shared.setAutomaticScreenNameTagging(enabled)
    }

    /// Attach the device's push-notification token to the session.
    /// Defaults `platform` to "apns"; pass "fcm" if you're piping
    /// a Firebase token. Dashboard wiring (chip on player header)
    /// tracked separately.
    ///
    /// Mirrors UXCam's `setPushNotificationToken(_:)`.
    public static func setPushNotificationToken(
        _ token: String,
        platform: String = "apns"
    ) {
        ReplayCore.shared.setPushNotificationToken(token, platform: platform)
    }

    /// Flag the current session as a favorite so it surfaces in the
    /// "starred sessions" filter on the dashboard. One-shot — call
    /// once per session you want flagged.
    ///
    /// Mirrors UXCam's `markSessionAsFavorite()`.
    public static func markSessionAsFavorite() {
        ReplayCore.shared.markSessionAsFavorite()
    }

    /// Attach a SESSION-level tag (with optional properties) for
    /// filtering the session list. Distinct from ``track(_:properties:)``
    /// which is event-level. Use for "this session is in A/B variant
    /// X" or "this session belongs to the holiday checkout flow".
    ///
    /// Mirrors UXCam's `addTagWithProperties(_:properties:)`.
    public static func addTagWithProperties(
        _ name: String,
        properties: [String: Any]? = nil
    ) {
        ReplayCore.shared.addTagWithProperties(name, properties: properties)
    }

    /// Force-end the current session + spin up a fresh one. Useful
    /// for logical session boundaries inside one app process —
    /// user logout-then-login, A/B re-bucketing, "start over"
    /// flows. Drains the old session's events first so they don't
    /// bleed into the new one.
    ///
    /// Mirrors UXCam's `startNewSession()`.
    public static func startNewSession() {
        ReplayCore.shared.startNewSession()
    }

    /// Stop recording AND block (up to `timeoutSeconds`) until the
    /// in-memory buffer has been uploaded or persisted to disk.
    /// Call this from `applicationWillTerminate` or a sign-out
    /// flow when you want strong-delivery semantics. Caps the wait
    /// so a wedged network can't hang the host app.
    ///
    /// Mirrors UXCam's `stopApplicationAndUploadData()`. Default
    /// timeout 5s.
    public static func stopApplicationAndUploadData(timeoutSeconds: TimeInterval = 5) {
        ReplayCore.shared.stopApplicationAndUploadData(timeoutSeconds: timeoutSeconds)
    }

    /// Bridge customer-side logging into the SDK's console-event
    /// stream. `print()` / `NSLog()` are captured automatically when
    /// `captureConsole = true`. Use this entry point for loggers
    /// that don't write to STDOUT/STDERR — `Logger`, `os_log`,
    /// CocoaLumberjack, SwiftyBeaver, custom systems.
    ///
    /// Mirrors the Android SDK's `Replay.log(level, message, stack)`.
    ///
    /// - Parameters:
    ///   - level:   "log" | "info" | "warn" | "error" | "debug"
    ///   - message: Free-text log line.
    ///   - stack:   Optional stack trace (for exception logs).
    public static func log(
        level: String,
        message: String,
        stack: String? = nil
    ) {
        ReplayCore.shared.logExplicit(level: level, message: message, stack: stack)
    }
}
