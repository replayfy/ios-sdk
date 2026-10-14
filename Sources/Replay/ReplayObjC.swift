import Foundation
#if canImport(UIKit)
import UIKit
#endif

// ObjC-callable bridge over the Swift `Replay` enum + `ReplayConfig`
// struct.
//
// Why this file exists:
//   1. Pure-Objective-C apps can't see Swift enums, structs, or
//      throwing inits. To call our SDK from an `.m` file you need
//      methods on a NSObject subclass annotated with `@objc(...)`.
//   2. React Native's iOS bridge is conventionally Objective-C
//      (`RCT_EXPORT_MODULE`, `RCT_EXTERN_METHOD`). The future
//      `react-native-replay` package could either define its own
//      ObjC wrapper around our Swift API OR import these bridges
//      directly — second path is one less file to maintain.
//
// Why a separate file rather than `@objc` on Replay itself:
//   - `Replay` is a Swift `enum` (used as a namespace). Enums can't
//     be exposed to ObjC. Conversion to a class would change the
//     Swift API.
//   - Keeping the Swift surface idiomatic (enum + struct) is
//     important for Swift consumers — auto-completion, lower
//     allocation overhead, no NSObject inheritance.
//   - Bridge classes (`ReplayBridge` / `ReplayConfigBridge`) carry
//     `@objc(name)` so they appear in generated -Swift.h with the
//     unqualified Objective-C names `Replay` / `ReplayConfig`.
//
// What stays Swift-only:
//   - `Result`-returning APIs (no ObjC equivalent)
//   - Async/await methods (use the @objc completion-handler form)
//   - Generic methods
//
// All of the current public API uses simple primitives so the bridge
// covers 100% of the surface today.

/// ObjC-visible mirror of ``ReplayConfig`` (Swift struct).
///
/// Mutable class with `@objc init(...)` so ObjC code can construct
/// it; Swift code should still prefer `ReplayConfig(apiKey:..., apiHost:...)`.
@objc(ReplayConfig)
@objcMembers
public final class ReplayConfigBridge: NSObject {

    public var apiKey: String
    public var apiHost: String

    /// All optional / default-valued config knobs as plain stored
    /// properties so ObjC can twiddle them. Defaults match
    /// ``ReplayConfig``'s Swift init.
    public var projectId: String?
    public var distinctId: String?
    public var flushInterval: TimeInterval = 5
    public var maxBufferSize: Int = 500
    public var captureConsole: Bool = true
    public var captureNetwork: Bool = false
    public var captureErrors: Bool = true
    public var captureHeaders: Bool = false
    public var maxBodyBytes: Int = 4_096
    public var captureSnapshotPixels: Bool = true
    public var snapshotInterval: TimeInterval = 0.5
    public var autoScreenName: Bool = true
    public var disableWebViewMasking: Bool = false

    /// Minimal ObjC-callable init. ObjC consumers tweak optional
    /// properties after construction:
    ///
    ///   ReplayConfig *cfg = [[ReplayConfig alloc] initWithApiKey:@"…"
    ///                                                    apiHost:@"…"];
    ///   cfg.captureNetwork = YES;
    @objc public init(apiKey: String, apiHost: String) {
        self.apiKey = apiKey
        self.apiHost = apiHost
        super.init()
    }

    /// Convert to the Swift `ReplayConfig` struct used internally.
    /// Kept `fileprivate`-ish (internal) — never called from outside.
    func toSwift() -> ReplayConfig {
        return ReplayConfig(
            apiKey: apiKey,
            apiHost: apiHost,
            projectId: projectId,
            distinctId: distinctId,
            flushInterval: flushInterval,
            maxBufferSize: maxBufferSize,
            captureConsole: captureConsole,
            captureNetwork: captureNetwork,
            captureErrors: captureErrors,
            captureHeaders: captureHeaders,
            maxBodyBytes: maxBodyBytes,
            captureSnapshotPixels: captureSnapshotPixels,
            snapshotInterval: snapshotInterval,
            autoScreenName: autoScreenName,
            disableWebViewMasking: disableWebViewMasking
        )
    }
}

/// ObjC-visible mirror of the Swift `Replay` enum API.
///
/// Lives as a class (NSObject subclass) because enums can't expose
/// static methods to ObjC. From Swift continue to use `Replay.start(with:)`;
/// from ObjC use `[Replay startWithConfig: cfg]`.
@objc(Replay)
@objcMembers
public final class ReplayBridge: NSObject {

    /// Prevent instantiation — every method is class-level.
    private override init() { super.init() }

    /// `[Replay startWithConfig: cfg]`
    @objc(startWithConfig:)
    public static func start(with config: ReplayConfigBridge) {
        Replay.start(with: config.toSwift())
    }

    /// `[Replay identifyWithDistinctId:@"u1" properties:@{...}]`
    /// `properties` may be nil.
    @objc(identifyWithDistinctId:properties:)
    public static func identify(
        distinctId: String,
        properties: [String: Any]?
    ) {
        Replay.identify(distinctId, properties: properties)
    }

    /// `[Replay trackWithName:@"checkout_clicked" properties:@{...}]`
    @objc(trackWithName:properties:)
    public static func track(
        name: String,
        properties: [String: Any]?
    ) {
        Replay.track(name, properties: properties)
    }

    /// `[Replay stop]`
    @objc public static func stop() {
        Replay.stop()
    }

    /// `BOOL recording = [Replay isRecording];`
    @objc public static var isRecording: Bool {
        Replay.isRecording
    }

    /// `[Replay tagScreenName: @"Checkout"]`
    @objc(tagScreenName:)
    public static func tagScreenName(_ name: String) {
        Replay.tagScreenName(name)
    }

    #if canImport(UIKit)
    /// `[Replay addPrivacyView: theView]`
    @objc(addPrivacyView:)
    public static func addPrivacyView(_ view: UIView) {
        Replay.addPrivacyView(view)
    }

    /// `[Replay addPrivacyView: theView blockGestures: YES]`
    @objc(addPrivacyView:blockGestures:)
    public static func addPrivacyView(_ view: UIView, blockGestures: Bool) {
        Replay.addPrivacyView(view, blockGestures: blockGestures)
    }

    /// `[Replay removePrivacyView: theView]`
    @objc(removePrivacyView:)
    public static func removePrivacyView(_ view: UIView) {
        Replay.removePrivacyView(view)
    }

    /// `[Replay addObservedInput: theTextField]`
    @objc(addObservedInput:)
    public static func addObservedInput(_ field: UITextField) {
        Replay.addObservedInput(field)
    }

    /// `[Replay occludeAllTextFields: YES]`
    @objc(occludeAllTextFields:)
    public static func occludeAllTextFields(_ occlude: Bool) {
        Replay.occludeAllTextFields(occlude)
    }

    /// `[Replay occludeAllTextView: YES]`
    @objc(occludeAllTextView:)
    public static func occludeAllTextView(_ occlude: Bool) {
        Replay.occludeAllTextView(occlude)
    }

    /// `[Replay occludeSensitiveScreen: YES]` — gestures are hidden with the
    /// screen.
    @objc(occludeSensitiveScreen:)
    public static func occludeSensitiveScreen(_ occlude: Bool) {
        Replay.occludeSensitiveScreen(occlude)
    }

    /// `[Replay occludeSensitiveScreen: YES hideGestures: NO]`
    @objc(occludeSensitiveScreen:hideGestures:)
    public static func occludeSensitiveScreen(_ occlude: Bool, hideGestures: Bool) {
        Replay.occludeSensitiveScreen(occlude, hideGestures: hideGestures)
    }

    /// `[Replay applyOcclusionForClass: [MyCustomView class]]`
    /// ObjC bridge — accepts AnyClass + checks it's a UIView
    /// subclass before forwarding. Silent no-op on non-UIView
    /// classes so misuse from ObjC can't crash the host app.
    @objc(applyOcclusionForClass:)
    public static func applyOcclusion(_ cls: AnyClass) {
        if let viewCls = cls as? UIView.Type {
            Replay.applyOcclusion(viewCls)
        }
    }

    /// `[Replay removeOcclusionForClass: [MyCustomView class]]`
    @objc(removeOcclusionForClass:)
    public static func removeOcclusion(_ cls: AnyClass) {
        if let viewCls = cls as? UIView.Type {
            Replay.removeOcclusion(viewCls)
        }
    }

    /// `[Replay occludeRectsOnNextFrame: @[[NSValue valueWithCGRect:r1], …]]`
    ///
    /// ObjC has no native [CGRect] array — RN / Cordova bridges pass
    /// boxed NSValue. We unwrap via cgRectValue.
    @objc(occludeRectsOnNextFrame:)
    public static func occludeRectsOnNextFrame(_ rects: [NSValue]) {
        let unboxed = rects.map { $0.cgRectValue }
        Replay.occludeRectsOnNextFrame(unboxed)
    }

    /// `[Replay occludeRectsOnNextFrame: rects styles: styles]` — per-rect
    /// render styles (0 blur, 1 overlay, 2 pixelate), parallel to `rects`.
    /// RN / Flutter pass boxed NSValue rects + NSNumber styles so each masked
    /// widget keeps its own style in a single one-shot set. A missing or
    /// unknown style falls back to the global mask style.
    @objc(occludeRectsOnNextFrame:styles:)
    public static func occludeRectsOnNextFrame(_ rects: [NSValue],
                                               styles: [NSNumber]) {
        let global = PrivacyRegistry.shared.maskStyle
        let maskRects = rects.enumerated().map { i, boxed -> MaskRect in
            let style = i < styles.count ? (ReplayMaskStyle(rawValue: styles[i].intValue) ?? global) : global
            return MaskRect(rect: boxed.cgRectValue, style: style)
        }
        PrivacyRegistry.shared.setPendingFrameRects(maskRects)
    }

    /// `[Replay setMaskStyle: 1]` — 0 blur, 1 overlay (the default),
    /// 2 pixelate. An unknown value selects overlay.
    @objc(setMaskStyle:)
    public static func setMaskStyle(_ style: Int) {
        Replay.setMaskStyle(ReplayMaskStyle(rawValue: style) ?? .overlay)
    }
    #endif

    /// `[Replay pauseRecording]`
    @objc public static func pauseRecording() {
        Replay.pauseRecording()
    }

    /// `[Replay resumeRecording]`
    @objc public static func resumeRecording() {
        Replay.resumeRecording()
    }

    /// `[Replay cancelSession]`
    @objc public static func cancelSession() {
        Replay.cancelSession()
    }

    /// `[Replay logWithLevel:@"warn" message:@"…" stack:nil]`
    @objc(logWithLevel:message:stack:)
    public static func log(
        level: String,
        message: String,
        stack: String?
    ) {
        Replay.log(level: level, message: message, stack: stack)
    }

    /// `[Replay setUserProperty:@"plan" value:@"pro"]`
    @objc(setUserProperty:value:)
    public static func setUserProperty(_ key: String, value: Any?) {
        Replay.setUserProperty(key, value: value)
    }

    /// `[Replay setSessionProperty:@"ab_variant" value:@"B"]`
    @objc(setSessionProperty:value:)
    public static func setSessionProperty(_ key: String, value: Any?) {
        Replay.setSessionProperty(key, value: value)
    }

    /// `[Replay setAutomaticScreenNameTagging: NO]`
    @objc(setAutomaticScreenNameTagging:)
    public static func setAutomaticScreenNameTagging(_ enabled: Bool) {
        Replay.setAutomaticScreenNameTagging(enabled)
    }

    /// `[Replay setPushNotificationToken:@"abc..." platform:@"apns"]`
    @objc(setPushNotificationToken:platform:)
    public static func setPushNotificationToken(_ token: String, platform: String) {
        Replay.setPushNotificationToken(token, platform: platform)
    }

    /// `[Replay markSessionAsFavorite]`
    @objc public static func markSessionAsFavorite() {
        Replay.markSessionAsFavorite()
    }

    /// `[Replay addTagWithProperties:@"holiday_flow" properties:@{...}]`
    @objc(addTagWithProperties:properties:)
    public static func addTagWithProperties(_ name: String, properties: [String: Any]?) {
        Replay.addTagWithProperties(name, properties: properties)
    }

    /// `[Replay startNewSession]`
    @objc public static func startNewSession() {
        Replay.startNewSession()
    }

    /// `[Replay reportBugEventWithName:@"crash_at_checkout" description:@"…" properties:@{…}]`
    @objc(reportBugEventWithName:description:properties:)
    public static func reportBugEvent(
        name: String,
        description: String?,
        properties: [String: Any]?
    ) {
        Replay.reportBugEvent(name, description: description, properties: properties)
    }

    /// `[Replay setAppVersion:@"2.4.1" build:@"412"]`
    @objc(setAppVersion:build:)
    public static func setAppVersion(_ version: String?, build: String?) {
        Replay.setAppVersion(version, build: build)
    }

    /// `[Replay captureURLSessionConfiguration: cfg]`
    @objc(captureURLSessionConfiguration:)
    public static func captureURLSessionConfiguration(_ configuration: URLSessionConfiguration) {
        Replay.captureURLSessionConfiguration(configuration)
    }

    /// `[Replay enableAdvancedGestureRecognizer: YES]`
    @objc(enableAdvancedGestureRecognizer:)
    public static func enableAdvancedGestureRecognizer(_ enabled: Bool) {
        Replay.enableAdvancedGestureRecognizer(enabled)
    }

    /// `[Replay allowShortBreakForAnotherApp: YES windowSeconds: 30.0]`
    @objc(allowShortBreakForAnotherApp:windowSeconds:)
    public static func allowShortBreakForAnotherApp(
        _ allow: Bool,
        windowSeconds: TimeInterval
    ) {
        Replay.allowShortBreakForAnotherApp(allow, windowSeconds: windowSeconds)
    }

    /// `[Replay setMultiSessionRecord: YES]`
    @objc(setMultiSessionRecord:)
    public static func setMultiSessionRecord(_ enabled: Bool) {
        Replay.setMultiSessionRecord(enabled)
    }

    /// `NSUUID *token = [Replay addVerificationListener:^{ … }];`
    ///
    /// ObjC bridge: forwards the closure to Swift + returns the
    /// UUID token wrapped as NSUUID for `removeVerificationListener:`.
    @objc(addVerificationListener:)
    public static func addVerificationListener(_ listener: @escaping () -> Void) -> UUID {
        return Replay.addVerificationListener(listener)
    }

    /// `[Replay removeVerificationListener: token];`
    @objc(removeVerificationListener:)
    public static func removeVerificationListener(_ token: UUID) {
        Replay.removeVerificationListener(token)
    }

    /// `[Replay stopApplicationAndUploadDataWithTimeout: 5.0]`
    @objc(stopApplicationAndUploadDataWithTimeout:)
    public static func stopApplicationAndUploadData(timeoutSeconds: TimeInterval) {
        Replay.stopApplicationAndUploadData(timeoutSeconds: timeoutSeconds)
    }

    /// `[Replay optOutOverall: YES]`
    @objc(optOutOverall:)
    public static func optOutOverall(_ optOut: Bool) {
        Replay.optOutOverall(optOut)
    }

    /// `BOOL out = [Replay isOptedOutOverall];`
    @objc public static var isOptedOutOverall: Bool {
        Replay.isOptedOutOverall
    }

    /// `[Replay optOutOfSchematicRecordings: YES]`
    @objc(optOutOfSchematicRecordings:)
    public static func optOutOfSchematicRecordings(_ optOut: Bool) {
        Replay.optOutOfSchematicRecordings(optOut)
    }

    /// `BOOL out = [Replay isOptedOutOfSchematicRecordings];`
    @objc public static var isOptedOutOfSchematicRecordings: Bool {
        Replay.isOptedOutOfSchematicRecordings
    }

    /// `NSString *url = [Replay urlForCurrentSession];` — nullable.
    @objc public static func urlForCurrentSession() -> String? {
        Replay.urlForCurrentSession()
    }

    /// `NSString *url = [Replay urlForCurrentUser];` — nullable.
    @objc public static func urlForCurrentUser() -> String? {
        Replay.urlForCurrentUser()
    }

    // -----------------------------------------------------------------
    //  Live-engine passthroughs for the React Native bridge.
    //
    //  These forward straight to the live `ReplayCore` engine (the one
    //  `Replay.start` drives) rather than the legacy facade methods, so
    //  RN sessions get real metadata / network / session-id / teardown
    //  even before the LegacyCore consolidation (TODO #119) lands. They
    //  live here because ReplayObjC is in-module and can reach
    //  ReplayCore's internal surface; an external bridge pod cannot.
    // -----------------------------------------------------------------

    // ReplayCore is UIKit-gated; these forwarders must compile out on
    // non-UIKit hosts (e.g. the macOS `swift build`) the same way.
#if canImport(UIKit)
    /// Live sticky metadata (single key/value). Distinct from
    /// `setUserProperty`, which is the legacy session-property path.
    @objc(recordMetadata:value:)
    public static func recordMetadata(_ key: String, value: String) {
        ReplayCore.shared.sendMetadata(key: key, value: value)
    }

    /// Forward one captured RN network call to the live engine. Bodies
    /// (`request` / `response`) are JSON strings assembled JS-side.
    @objc(recordNetworkURL:method:request:response:status:duration:)
    public static func recordNetwork(
        url: String,
        method: String,
        request: String,
        response: String,
        status: Int,
        duration: Int
    ) {
        ReplayCore.shared.sendNetwork(
            type: "fetch",
            method: method,
            url: url,
            request: request,
            response: response,
            status: UInt64(max(0, status)),
            duration: UInt64(max(0, duration))
        )
    }

    /// Active live-engine session id (nil when not recording).
    @objc public static func currentSessionId() -> String? {
        ReplayCore.shared.sessionID
    }

    /// Tag this session's wrapper SDK (e.g. "react-native"). Sent on /start so
    /// the dashboard shows "Captured by …" while platform stays ios/android.
    /// Call before `Replay.start`.
    @objc(setFramework:)
    public static func setFramework(_ name: String) {
        ReplayCore.framework = name
    }

    /// Stop the live recording engine + flush.
    @objc public static func stopEngine() {
        ReplayCore.shared.stop()
    }
#endif
}
