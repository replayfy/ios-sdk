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
    public var liveMode: Bool = true
    public var captureConsole: Bool = true
    public var captureNetwork: Bool = false
    public var captureErrors: Bool = true
    public var captureHeaders: Bool = false
    public var maxBodyBytes: Int = 4_096
    public var captureSnapshotPixels: Bool = true

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
            liveMode: liveMode,
            captureConsole: captureConsole,
            captureNetwork: captureNetwork,
            captureErrors: captureErrors,
            captureHeaders: captureHeaders,
            maxBodyBytes: maxBodyBytes,
            captureSnapshotPixels: captureSnapshotPixels
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

    /// `[Replay removePrivacyView: theView]`
    @objc(removePrivacyView:)
    public static func removePrivacyView(_ view: UIView) {
        Replay.removePrivacyView(view)
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
}
