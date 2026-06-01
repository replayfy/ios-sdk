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
        // Reference-parity mobile recording engine: periodic JPEG frames
        // + binary message protocol → /v1/mobile/*. Replaces the legacy
        // per-snapshot/asset engine (no backward compatibility).
        #if canImport(UIKit)
        MobileEngine.shared.start(projectKey: config.apiKey, host: config.apiHost)
        #endif
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
        #if canImport(UIKit)
        MobileEngine.shared.setUserID(distinctId)
        #endif
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
        #if canImport(UIKit)
        var payload = ""
        if let properties = properties,
           let data = try? JSONSerialization.data(withJSONObject: properties),
           let str = String(data: data, encoding: .utf8) {
            payload = str
        }
        MobileEngine.shared.sendEvent(name: name, payload: payload)
        #endif
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
        #if canImport(UIKit)
        // Manual screen tag → viewComponent message, same as the
        // UIViewController auto-tagger, so the Screens tab reflects it.
        MobileEngine.shared.sendScreen(screenName: name, viewName: name, visible: true)
        #endif
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

    /// Register a `UIView` subclass for occlusion — every instance
    /// (including subclasses) on screen gets the stripe overlay.
    /// Goes beyond the bulk `UITextField` / `UILabel` flags: use
    /// when the app has custom widgets (e.g. CreditCardInputView,
    /// MedicalRecordCard) that should be default-occluded across
    /// every screen they appear on.
    ///
    /// Cheap when no classes registered (~zero overhead). Class
    /// set size is typically single-digit in practice.
    ///
    /// Mirrors UXCam's `applyOcclusion(_:)`.
    public static func applyOcclusion(_ viewClass: UIView.Type) {
        PrivacyRegistry.shared.applyOcclusion(viewClass)
    }

    /// Unregister a previously-added occluded class. Safe to call
    /// for classes that were never registered.
    public static func removeOcclusion(_ viewClass: UIView.Type) {
        PrivacyRegistry.shared.removeOcclusion(viewClass)
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

    /// Pause schematic capture — snapshots stop, taps + network +
    /// console + perf events keep flowing. In-memory only; a
    /// process restart resets to running. Use
    /// ``optOutOfSchematicRecordings(_:)`` for a durable opt-out.
    ///
    /// Mirrors UXCam's `pauseScreenRecording()`.
    public static func pauseRecording() {
        ReplayCore.shared.setSnapshotPaused(true)
    }

    /// Resume schematic capture after ``pauseRecording()``.
    /// Mirrors UXCam's `resumeScreenRecording()`.
    public static func resumeRecording() {
        ReplayCore.shared.setSnapshotPaused(false)
    }

    /// Discard the current session entirely — clears the in-memory
    /// buffer AND deletes any on-disk batches still queued for
    /// upload. The session never reaches the backend. Different
    /// from ``stop()`` (graceful end + upload).
    ///
    /// Mirrors UXCam's `cancelCurrentSession()`.
    public static func cancelSession() {
        ReplayCore.shared.cancelCurrentSession()
    }

    // -----------------------------------------------------------------
    //  UXCam-parity GDPR opt-in / opt-out
    // -----------------------------------------------------------------

    /// Overall opt-out. When set to true: every event drops at the
    /// emit gate, no snapshots fire, no uploads happen. Persisted
    /// across launches via UserDefaults. The customer MUST call
    /// again with false to start recording again.
    ///
    /// Mirrors UXCam's `optOutOverall()` / `optInOverall()` —
    /// collapsed to one boolean for the idiomatic Swift shape.
    public static func optOutOverall(_ optOut: Bool) {
        ReplayCore.shared.setOverallOptOut(optOut)
    }

    /// Whether the customer is currently opted out overall.
    public static var isOptedOutOverall: Bool {
        ReplayCore.shared.isOverallOptedOut
    }

    /// Schematic (snapshot-only) opt-out. When set to true: pixel
    /// capture stops but every other event type keeps flowing.
    /// Persisted across launches.
    ///
    /// Mirrors UXCam's `optOutOfSchematicRecordings()` /
    /// `optIntoSchematicRecordings()`.
    public static func optOutOfSchematicRecordings(_ optOut: Bool) {
        ReplayCore.shared.setSchematicOptOut(optOut)
    }

    /// Whether schematic (snapshot) recording is currently opted out.
    public static var isOptedOutOfSchematicRecordings: Bool {
        ReplayCore.shared.isSchematicOptedOut
    }

    // -----------------------------------------------------------------
    //  UXCam-parity deep-link helpers
    // -----------------------------------------------------------------

    /// Dashboard URL for the current session, or nil when no
    /// session is active. Derived from `ReplayConfig.apiHost`
    /// by substituting `://api.` with `://app.`. Self-hosted
    /// customers' hosts work unchanged.
    ///
    /// Mirrors UXCam's `urlForCurrentSession()`.
    public static func urlForCurrentSession() -> String? {
        ReplayCore.shared.urlForCurrentSession
    }

    /// Dashboard URL for the currently-identified user (all
    /// sessions for the active distinctId), or nil when no
    /// `identify()` has been called yet.
    ///
    /// Mirrors UXCam's `urlForCurrentUser()`.
    public static func urlForCurrentUser() -> String? {
        ReplayCore.shared.urlForCurrentUser
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

    /// Override the host app's marketing version + build that the
    /// SDK auto-detects from `CFBundleShortVersionString` +
    /// `CFBundleVersion`. Used by:
    ///
    ///   - Cross-platform wrappers (React Native, Flutter, Cordova)
    ///     whose JS / Dart bundle has its OWN version separate from
    ///     the iOS host shell's.
    ///   - White-label apps that brand each variant with its own
    ///     marketing version.
    ///
    /// Call BEFORE `Replay.start(with:)` (or at app startup before
    /// any session fires) so the FIRST batch carries the override.
    /// Sticky for the process lifetime.
    ///
    /// Used by the backend symbolication service to pick the right
    /// dSYM for crash stacks. Pass nil to clear the override and
    /// fall back to Bundle.main.
    public static func setAppVersion(_ version: String?, build: String? = nil) {
        ReplayCore.shared.setAppVersionOverride(version: version, build: build)
    }

    /// Wire network capture for a custom `URLSessionConfiguration`.
    /// The auto-installed `URLProtocol` only catches `URLSession.shared`
    /// + deprecated `NSURLConnection` paths — custom configurations
    /// constructed via `URLSession(configuration:)` bypass us unless
    /// the capture protocol sits in `configuration.protocolClasses`.
    ///
    /// Call BEFORE handing the configuration to `URLSession.init`
    /// (URLSession copies the config at construction).
    ///
    /// Honours the runtime `captureNetwork` flag — when off, the
    /// inserted class is inert (canInit returns false), so this is
    /// safe to wire at app launch regardless.
    ///
    ///     let cfg = URLSessionConfiguration.default
    ///     Replay.captureURLSessionConfiguration(cfg)
    ///     let session = URLSession(configuration: cfg)
    public static func captureURLSessionConfiguration(_ configuration: URLSessionConfiguration) {
        URLSessionCapture.captureCustomConfiguration(configuration)
    }

    /// Toggle capture of advanced gestures — long-press, four-
    /// direction swipe, pinch — in addition to the always-on tap.
    /// When enabled, each gesture emits a TapEventData with
    /// `gesture` set to "long_press" / "swipe_left" / "swipe_right" /
    /// "swipe_up" / "swipe_down" / "pinch". Pinch events also
    /// carry a `pinchScale` (final ratio).
    ///
    /// Default off. The extra recognizers attach lazily to newly-
    /// added windows AFTER the flag flips, so non-users pay zero
    /// overhead.
    ///
    /// Mirrors UXCam's `enableAdvancedGestureRecognizer(_:)`.
    public static func enableAdvancedGestureRecognizer(_ enabled: Bool) {
        ReplayCore.shared.setAdvancedGesturesEnabled(enabled)
    }

    /// Allow brief backgrounding (≤ `windowSeconds`, default 30 s)
    /// WITHOUT ending the session. The same session resumes when
    /// the user returns. Default off.
    ///
    /// Mirrors UXCam's `allowShortBreakForAnotherApp(_:)`.
    public static func allowShortBreakForAnotherApp(
        _ allow: Bool,
        windowSeconds: TimeInterval = 30
    ) {
        ReplayCore.shared.setAllowShortBreak(allow, windowSeconds: windowSeconds)
    }

    /// Toggle multi-session recording per app launch. When false,
    /// only ONE session fires per process — subsequent
    /// foregroundings after a session_end are no-ops. Default true.
    ///
    /// Mirrors UXCam's `setMultiSessionRecord(_:)`.
    public static func setMultiSessionRecord(_ enabled: Bool) {
        ReplayCore.shared.setMultiSessionRecord(enabled)
    }

    /// Register a callback that fires after the SDK's first
    /// successful batch upload (server-side handshake confirmed).
    /// Used during onboarding so the customer's "Verify integration"
    /// UI can light up.
    ///
    /// If verification has ALREADY fired this process the closure
    /// runs synchronously on the calling thread. Otherwise it
    /// runs on the MAIN thread when the next upload succeeds.
    /// One-shot per process.
    ///
    /// Returns a token used to remove the listener later. Mirrors
    /// UXCam's `addVerificationListener(VerificationListener)`.
    @discardableResult
    public static func addVerificationListener(_ listener: @escaping () -> Void) -> UUID {
        return ReplayCore.shared.addVerificationListener(listener)
    }

    /// Drop a previously-added verification listener.
    public static func removeVerificationListener(_ token: UUID) {
        ReplayCore.shared.removeVerificationListener(token)
    }

    /// Manual bug-report event. Wire to a "Send Feedback" /
    /// "Report Issue" button — the dashboard surfaces these as
    /// flagged events in the session timeline + a fresh snapshot
    /// fires so the report timestamp ships with the screen the
    /// user was looking at.
    ///
    /// Mirrors UXCam's `reportBugEvent(name:description:)`.
    public static func reportBugEvent(
        _ name: String,
        description: String? = nil,
        properties: [String: Any]? = nil
    ) {
        ReplayCore.shared.reportBugEvent(
            name: name,
            description: description,
            properties: properties
        )
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
        #if canImport(UIKit)
        // Bridge into the binary message stream → dashboard console tab.
        MobileEngine.shared.sendLog(severity: level, content: stack != nil ? "\(message)\n\(stack!)" : message)
        #endif
    }
}
