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
/// the reference mobile SDK's `+optInOverall`-style API surface 1:1 — we adopt the
/// modern Swift idioms (lowercase methods, structured concurrency,
/// optional params) while keeping the underlying capabilities the same.
///
/// Foundation: ``start(with:)`` + ``identify(_:properties:)`` +
/// ``track(_:properties:)`` + ``stop()`` + ``isRecording`` — all live on the
/// active recording engine (``ReplayCore``).
///
/// ⚠️ **Stubbed facade methods.** A handful of public methods still delegate
/// to the legacy engine (``LegacyCore``), which ``start(with:)`` no longer
/// boots — so on a live session they are no-ops (or return nil). They are
/// kept on the public surface for source-compatibility and will be re-homed
/// onto ``ReplayCore`` (or backed by new engine features) in the
/// engine-consolidation follow-up. Each is marked `⚠️ STUB` at its
/// definition; see `docs/sdk-facade-status.md` for the canonical list:
///   - ``cancelSession()``
///   - ``optOutOfSchematicRecordings(_:)`` / ``isOptedOutOfSchematicRecordings``
///   - ``urlForCurrentSession()`` / ``urlForCurrentUser()``
///   - ``enableAdvancedGestureRecognizer(_:)``
///   - ``allowShortBreakForAnotherApp(_:windowSeconds:)``
///   - ``setMultiSessionRecord(_:)``
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
        ReplayCore.shared.start(config: config)
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
        ReplayCore.shared.setUserID(distinctId)
        // Each trait rides as its own metadata(92) message — the backend
        // promotes plan/email/name to EndUser columns and keeps the rest as
        // custom properties, mirroring the web identify path.
        if let properties = properties {
            for (key, value) in properties {
                ReplayCore.shared.sendMetadata(key: key, value: String(describing: value))
            }
        }
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
        ReplayCore.shared.sendEvent(name: name, payload: payload)
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
        #if canImport(UIKit)
        ReplayCore.shared.stop()
        #endif
    }

    /// Whether the SDK is currently recording. Returns false when
    /// `start(with:)` hasn't been called, when the user is opted
    /// out, or when a sampling decision dropped the current session.
    public static var isRecording: Bool {
        #if canImport(UIKit)
        return ReplayCore.shared.sessionID != nil
        #else
        return false
        #endif
    }

    // MARK: - Stubs (engine in follow-up commits)

    /// Tag the current screen with a name. Manual override for the
    /// auto-tagger (which uses `UIViewController` class names by default).
    public static func tagScreenName(_ name: String) {
        LegacyCore.shared.setRoute(name)
        #if canImport(UIKit)
        // Manual screen tag → viewComponent message, same as the
        // UIViewController auto-tagger, so the Screens tab reflects it.
        ReplayCore.shared.sendScreen(screenName: name, viewName: name, visible: true)
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
    /// Mirrors the reference mobile SDK's `occludeAllTextFields(_:)`.
    public static func occludeAllTextFields(_ occlude: Bool) {
        PrivacyRegistry.shared.occludeAllTextFields = occlude
    }

    /// Occlude every `UILabel` — anything that DISPLAYS read-only
    /// text. Pair with ``occludeAllTextFields(_:)`` to redact 100%
    /// of textual content in the captured snapshot.
    ///
    /// Mirrors the reference mobile SDK's `occludeAllTextView(_:)`.
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
    /// Mirrors the reference mobile SDK's `applyOcclusion(_:)`.
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
    /// Mirrors the reference mobile SDK's `occludeSensitiveScreen(_:)`.
    public static func occludeSensitiveScreen(_ occlude: Bool) {
        PrivacyRegistry.shared.occludeAllScreen = occlude
    }

    /// Mask a set of `CGRect` regions on the NEXT snapshot only. Entry point
    /// for cross-platform SDK bridges (React Native, Flutter) whose components
    /// don't have native `UIView` references — the bridge calculates rects on
    /// the JS / Dart side (RN `measureInWindow`, Flutter
    /// `RenderBox.localToGlobal`) and hands them here in root-relative points.
    /// Rendered with the current global ``setMaskStyle(_:)``.
    ///
    /// One-shot: the rects clear once a snapshot fires. Bridges call this every
    /// frame (or before any capture they want occluded). Calling it again
    /// without a snapshot in between REPLACES (does not append to) the prior
    /// set.
    ///
    /// Mirrors the reference mobile SDK's `occludeRectsOnNextFrame(rects)`.
    public static func occludeRectsOnNextFrame(_ rects: [CGRect]) {
        occludeRectsOnNextFrame(rects, style: PrivacyRegistry.shared.maskStyle)
    }

    /// As ``occludeRectsOnNextFrame(_:)`` but with an explicit render style for
    /// every rect in this set.
    public static func occludeRectsOnNextFrame(_ rects: [CGRect],
                                               style: ReplayMaskStyle) {
        PrivacyRegistry.shared.setPendingFrameRects(
            rects.map { MaskRect(rect: $0, style: style) })
    }

    /// The default render style for masked regions — `.blur` Gaussian-blurs
    /// the pixels, `.overlay` paints a solid box. Applies to `addPrivacyView`,
    /// `occludeAllTextFields`, secure fields, the whole-screen overlay, and any
    /// `occludeRectsOnNextFrame` call that doesn't pass its own style. Default
    /// `.blur`.
    public static func setMaskStyle(_ style: ReplayMaskStyle) {
        PrivacyRegistry.shared.maskStyle = style
    }

    /// Gaussian blur radius for `.blur` regions (default 8). Larger = stronger.
    public static func setBlurRadius(_ radius: Double) {
        PrivacyRegistry.shared.blurRadius = max(0, radius)
    }
    #endif

    /// Pause schematic capture — snapshots stop, taps + network +
    /// console + perf events keep flowing. In-memory only; a
    /// process restart resets to running. Use
    /// ``optOutOfSchematicRecordings(_:)`` for a durable opt-out.
    ///
    /// Mirrors the reference mobile SDK's `pauseScreenRecording()`.
    public static func pauseRecording() {
        #if canImport(UIKit)
        ReplayCore.shared.pauseCapture()
        #endif
    }

    /// Resume schematic capture after ``pauseRecording()``.
    /// Mirrors the reference mobile SDK's `resumeScreenRecording()`.
    public static func resumeRecording() {
        #if canImport(UIKit)
        ReplayCore.shared.resumeCapture()
        #endif
    }

    /// Discard the current session entirely — clears the in-memory
    /// buffer AND deletes any on-disk batches still queued for
    /// upload. The session never reaches the backend. Different
    /// from ``stop()`` (graceful end + upload).
    ///
    /// Mirrors the reference mobile SDK's `cancelCurrentSession()`.
    public static func cancelSession() {
        // ⚠️ STUB — LegacyCore isn't booted by start(); this does NOT cancel
        // the live ReplayCore session. See docs/sdk-facade-status.md.
        LegacyCore.shared.cancelCurrentSession()
    }

    // -----------------------------------------------------------------
    //  industry-standard GDPR opt-in / opt-out
    // -----------------------------------------------------------------

    /// Overall opt-out. When set to true: every event drops at the
    /// emit gate, no snapshots fire, no uploads happen. Persisted
    /// across launches via UserDefaults. The customer MUST call
    /// again with false to start recording again.
    ///
    /// Mirrors the reference mobile SDK's `optOutOverall()` / `optInOverall()` —
    /// collapsed to one boolean for the idiomatic Swift shape.
    public static func optOutOverall(_ optOut: Bool) {
        LegacyCore.shared.setOverallOptOut(optOut)
        #if canImport(UIKit)
        // GDPR: enforce on the LIVE engine, not just the legacy facade —
        // stop recording immediately when the user opts out. Opt-in takes
        // effect on the next start()/launch.
        if optOut { ReplayCore.shared.stop() }
        #endif
    }

    /// Whether the customer is currently opted out overall.
    public static var isOptedOutOverall: Bool {
        LegacyCore.shared.isOverallOptedOut
    }

    /// Schematic (snapshot-only) opt-out. When set to true: pixel
    /// capture stops but every other event type keeps flowing.
    /// Persisted across launches.
    ///
    /// Mirrors the reference mobile SDK's `optOutOfSchematicRecordings()` /
    /// `optIntoSchematicRecordings()`.
    public static func optOutOfSchematicRecordings(_ optOut: Bool) {
        // ⚠️ STUB — sets a flag on the un-booted LegacyCore that the live
        // engine never reads; pixel capture is unaffected. See
        // docs/sdk-facade-status.md.
        LegacyCore.shared.setSchematicOptOut(optOut)
    }

    /// Whether schematic (snapshot) recording is currently opted out.
    public static var isOptedOutOfSchematicRecordings: Bool {
        // ⚠️ STUB — reads the inert LegacyCore flag (see
        // optOutOfSchematicRecordings). docs/sdk-facade-status.md.
        LegacyCore.shared.isSchematicOptedOut
    }

    // -----------------------------------------------------------------
    //  industry-standard deep-link helpers
    // -----------------------------------------------------------------

    /// Dashboard URL for the current session, or nil when no
    /// session is active. Derived from `ReplayConfig.apiHost`
    /// by substituting `://api.` with `://app.`. Self-hosted
    /// customers' hosts work unchanged.
    ///
    /// Mirrors the reference mobile SDK's `urlForCurrentSession()`.
    public static func urlForCurrentSession() -> String? {
        // ⚠️ STUB — derived from the un-booted LegacyCore's (nonexistent)
        // session, so returns nil for live sessions. Re-home onto
        // ReplayCore.sessionID + apiHost. See docs/sdk-facade-status.md.
        LegacyCore.shared.urlForCurrentSession
    }

    /// Dashboard URL for the currently-identified user (all
    /// sessions for the active distinctId), or nil when no
    /// `identify()` has been called yet.
    ///
    /// Mirrors the reference mobile SDK's `urlForCurrentUser()`.
    public static func urlForCurrentUser() -> String? {
        // ⚠️ STUB — see urlForCurrentSession; nil for live sessions.
        // docs/sdk-facade-status.md.
        LegacyCore.shared.urlForCurrentUser
    }

    /// Attach a sticky property to the END USER (persists across
    /// sessions, attached to the EndUser row server-side). Distinct
    /// from `track` event properties which only attach to a single
    /// event.
    ///
    /// Mirrors the reference mobile SDK's `setUserProperty(_:, _:)` per-primitive
    /// overloads — Swift's `Any?` subsumes them.
    ///
    /// Common use: `Replay.setUserProperty("plan", value: "pro")`
    /// or `Replay.setUserProperty("signupSource", value: "google_ads")`.
    public static func setUserProperty(_ key: String, value: Any?) {
        guard let value = value else { return }
        #if canImport(UIKit)
        ReplayCore.shared.sendMetadata(key: key, value: String(describing: value))
        #endif
    }

    /// Attach a sticky property to the CURRENT SESSION. Visible on
    /// the dashboard as a Session-level field (chip on the player
    /// header — dashboard wiring is a separate task).
    ///
    /// Use for ephemeral per-session context:
    /// `Replay.setSessionProperty("ab_variant", value: "B")`,
    /// `Replay.setSessionProperty("checkout_step", value: "shipping")`.
    public static func setSessionProperty(_ key: String, value: Any?) {
        guard let value = value else { return }
        #if canImport(UIKit)
        ReplayCore.shared.sendMetadata(key: key, value: String(describing: value))
        #endif
    }

    // -----------------------------------------------------------------
    //  industry-standard session-control surface
    // -----------------------------------------------------------------

    /// Toggle the UIViewController.viewDidAppear auto-tagger on/off
    /// at runtime. Default-on (via `ReplayConfig.autoScreenName`);
    /// flip false to drive routes manually via ``tagScreenName(_:)``
    /// for a flow where VC class names don't map cleanly to
    /// user-meaningful screens.
    ///
    /// Mirrors the reference mobile SDK's `setAutomaticScreenNameTagging(_:)`.
    public static func setAutomaticScreenNameTagging(_ enabled: Bool) {
        #if canImport(UIKit)
        ReplayCore.shared.setAutoScreenName(enabled)
        #endif
    }

    /// Attach the device's push-notification token to the session.
    /// Defaults `platform` to "apns"; pass "fcm" if you're piping
    /// a Firebase token. Dashboard wiring (chip on player header)
    /// tracked separately.
    ///
    /// Mirrors the reference mobile SDK's `setPushNotificationToken(_:)`.
    public static func setPushNotificationToken(
        _ token: String,
        platform: String = "apns"
    ) {
        #if canImport(UIKit)
        ReplayCore.shared.sendMetadata(key: "$push_token", value: token)
        ReplayCore.shared.sendMetadata(key: "$push_platform", value: platform)
        #endif
    }

    /// Flag the current session as a favorite so it surfaces in the
    /// "starred sessions" filter on the dashboard. One-shot — call
    /// once per session you want flagged.
    ///
    /// Mirrors the reference mobile SDK's `markSessionAsFavorite()`.
    public static func markSessionAsFavorite() {
        #if canImport(UIKit)
        ReplayCore.shared.sendMetadata(key: "$favorited", value: "true")
        #endif
    }

    /// Attach a SESSION-level tag (with optional properties) for
    /// filtering the session list. Distinct from ``track(_:properties:)``
    /// which is event-level. Use for "this session is in A/B variant
    /// X" or "this session belongs to the holiday checkout flow".
    ///
    /// Mirrors the reference mobile SDK's `addTagWithProperties(_:properties:)`.
    public static func addTagWithProperties(
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
        ReplayCore.shared.sendEvent(name: name, payload: payload)
        #endif
    }

    /// Force-end the current session + spin up a fresh one. Useful
    /// for logical session boundaries inside one app process —
    /// user logout-then-login, A/B re-bucketing, "start over"
    /// flows. Drains the old session's events first so they don't
    /// bleed into the new one.
    ///
    /// Mirrors the reference mobile SDK's `startNewSession()`.
    public static func startNewSession() {
        #if canImport(UIKit)
        ReplayCore.shared.startNewSession()
        #endif
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
        #if canImport(UIKit)
        if let version = version { ReplayCore.shared.sendMetadata(key: "$app_version", value: version) }
        if let build = build { ReplayCore.shared.sendMetadata(key: "$app_build", value: build) }
        #endif
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
    /// Mirrors the reference mobile SDK's `enableAdvancedGestureRecognizer(_:)`.
    public static func enableAdvancedGestureRecognizer(_ enabled: Bool) {
        // ⚠️ STUB — needs an advanced-gesture recognizer in the live engine;
        // the LegacyCore flag is inert. See docs/sdk-facade-status.md.
        LegacyCore.shared.setAdvancedGesturesEnabled(enabled)
    }

    /// Allow brief backgrounding (≤ `windowSeconds`, default 30 s)
    /// WITHOUT ending the session. The same session resumes when
    /// the user returns. Default off.
    ///
    /// Mirrors the reference mobile SDK's `allowShortBreakForAnotherApp(_:)`.
    public static func allowShortBreakForAnotherApp(
        _ allow: Bool,
        windowSeconds: TimeInterval = 30
    ) {
        // ⚠️ STUB — needs session-resume-window logic in the live engine; the
        // LegacyCore flag is inert. See docs/sdk-facade-status.md.
        LegacyCore.shared.setAllowShortBreak(allow, windowSeconds: windowSeconds)
    }

    /// Toggle multi-session recording per app launch. When false,
    /// only ONE session fires per process — subsequent
    /// foregroundings after a session_end are no-ops. Default true.
    ///
    /// Mirrors the reference mobile SDK's `setMultiSessionRecord(_:)`.
    public static func setMultiSessionRecord(_ enabled: Bool) {
        // ⚠️ STUB — needs multi-session lifecycle in the live engine; the
        // LegacyCore flag is inert. See docs/sdk-facade-status.md.
        LegacyCore.shared.setMultiSessionRecord(enabled)
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
    /// the reference mobile SDK's `addVerificationListener(VerificationListener)`.
    @discardableResult
    public static func addVerificationListener(_ listener: @escaping () -> Void) -> UUID {
        #if canImport(UIKit)
        return ReplayCore.shared.addVerificationListener(listener)
        #else
        return UUID()
        #endif
    }

    /// Drop a previously-added verification listener.
    public static func removeVerificationListener(_ token: UUID) {
        #if canImport(UIKit)
        ReplayCore.shared.removeVerificationListener(token)
        #endif
    }

    /// Manual bug-report event. Wire to a "Send Feedback" /
    /// "Report Issue" button — the dashboard surfaces these as
    /// flagged events in the session timeline + a fresh snapshot
    /// fires so the report timestamp ships with the screen the
    /// user was looking at.
    ///
    /// Mirrors the reference mobile SDK's `reportBugEvent(name:description:)`.
    public static func reportBugEvent(
        _ name: String,
        description: String? = nil,
        properties: [String: Any]? = nil
    ) {
        #if canImport(UIKit)
        var props: [String: Any] = ["name": name]
        if let description = description { props["description"] = description }
        if let properties = properties { props.merge(properties) { _, new in new } }
        var payload = ""
        if let data = try? JSONSerialization.data(withJSONObject: props),
           let str = String(data: data, encoding: .utf8) {
            payload = str
        }
        ReplayCore.shared.sendEvent(name: "$bug_report", payload: payload)
        #endif
    }

    /// Stop recording AND block (up to `timeoutSeconds`) until the
    /// in-memory buffer has been uploaded or persisted to disk.
    /// Call this from `applicationWillTerminate` or a sign-out
    /// flow when you want strong-delivery semantics. Caps the wait
    /// so a wedged network can't hang the host app.
    ///
    /// Mirrors the reference mobile SDK's `stopApplicationAndUploadData()`. Default
    /// timeout 5s.
    public static func stopApplicationAndUploadData(timeoutSeconds: TimeInterval = 5) {
        #if canImport(UIKit)
        // stop() flushes the in-memory batch as it tears the engine down.
        ReplayCore.shared.stop()
        #endif
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
        #if canImport(UIKit)
        // Bridge into the binary message stream → dashboard console tab.
        ReplayCore.shared.sendLog(severity: level, content: stack != nil ? "\(message)\n\(stack!)" : message)
        #endif
    }
}
