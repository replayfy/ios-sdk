#if canImport(UIKit)
import UIKit
import SystemConfiguration

/// Orchestrates the reference mobile recording engine: session start,
/// screenshot capture, binary message collection, and lifecycle.
///
/// Listeners (touch, input, screen, perf, log, crash, network) call the
/// `send*` methods, which encode a binary message and hand it to the
/// collector. Screenshots flow independently to /v1/mobile/images.
public final class ReplayCore {
    public static let shared = ReplayCore()

    /// Wrapper-SDK tag (e.g. "react-native") added to the /start payload so
    /// the dashboard can show "Captured by …" while the platform stays
    /// ios/android. Set before start().
    static var framework: String?

    private var transport: MobileTransport?
    private var collector: MobileCollector?
    private var screenshots: MobileScreenshots?
    private let touch = MobileTouchCapture()
    // Opt-in text-input observation (Replay.addObservedInput). Retained so the
    // observed fields' editing-end targets stay live for the engine's lifetime.
    private let input = MobileInputCapture()
    private var perf: MobilePerfMonitor?
    // PLCrashReporter handler for signal/EXC crashes — recorded in-process and
    // recovered + emitted through the live wire on the NEXT launch. Retained so
    // it (and the underlying reporter) isn't released.
    private var crashHandler: CrashHandler?
    private(set) var sessionID: String?
    private(set) var startedAt: UInt64 = 0
    private var active = false
    // Project key + ingest host for the HTTP transport.
    private var projectKey: String?
    // Readable by the facade (Replay.swift) to build dashboard deep-links.
    private(set) var host: String?
    // Last identified distinct id (identify → setUserID), sent on the wire.
    // Readable by the facade for urlForCurrentUser().
    private(set) var distinctId: String?

    // Dashboard-controlled capture toggles, set from the /start response and
    // refreshed mid-session by applyRemoteConfig (see below).
    private var captureConsole = true
    private var captureNetwork = true
    private var captureNetworkHeaders = true
    private var captureNetworkBodies = true

    /// Re-apply dashboard config mid-session. The periodic RemoteConfigFetcher
    /// (owned by LegacyCore) pushes here on every refresh, so a customer
    /// flipping a capture toggle on the dashboard takes effect on the live
    /// mobile session without an app restart — not just at /start. Only the
    /// toggles the mobile engine reads at capture time.
    func applyRemoteConfig(_ cfg: RemoteConfig) {
        captureConsole = cfg.captureConsole
        captureNetwork = cfg.captureNetwork
        captureNetworkHeaders = cfg.captureNetworkHeaders
        captureNetworkBodies = cfg.captureNetworkBodies
    }

    /// Messages emitted before the async `/start` round-trip completes
    /// (the launch screen's viewComponent, or an `identify` / `track` /
    /// `log` made at app launch) are queued here and drained into the
    /// collector once the session token arrives. The reference tracker
    /// buffers pre-start messages the same way — without this they'd be
    /// dropped because `collector` is still nil. Bounded so a
    /// never-completing `/start` can't grow it without limit.
    private let preStartLock = NSLock()
    private var preStart: [Data] = []
    private var ready = false
    private var starting = false
    // Config retained from the first start() so startNewSession() can restart.
    private var lastConfig: ReplayConfig?
    // Runtime auto screen-name toggle (set from config; flipped by
    // setAutomaticScreenNameTagging).
    private var autoScreenName = true

    /// Screens the host has opted OUT of recording ("don't record this screen").
    /// Matched case-insensitively against the auto-tagged / manually-tagged screen
    /// name. While an excluded screen is foreground the FRAME loop is paused
    /// (taps / network / console / perf keep flowing, mirroring pauseRecording);
    /// it resumes on any non-excluded screen. Seeded from
    /// ReplayConfig.excludedScreens and mutable at runtime via the facade.
    private var excludedScreens: Set<String> = []
    /// Whether the frame loop is currently paused BECAUSE of screen exclusion, so
    /// we only pause/resume + log on an actual enter/leave transition.
    private var framesExcluded = false
    /// The host paused frames (pauseRecording). Survives backgrounding and
    /// session rotation; a process restart resets it. The schematic opt-out is
    /// a hold of its own, persisted in OptOutStore (see setSchematicOptOut).
    private var hostPaused = false
    /// Frames must not be captured or accepted right now, for any reason.
    private var framesHeld: Bool {
        framesExcluded || hostPaused || OptOutStore.shared.schematicOptOut
    }
    /// The app is in the background: between onBackground and onForeground,
    /// or from a session going live there (attachFrames) to onForeground.
    /// Not a hold (nothing to lift), but no frame is taken meanwhile: the
    /// background task keeps the app running for a while, and frames of a
    /// screen nobody sees would only push the session's last upload later.
    /// Changed on the main thread, like the holds (see onMain).
    private var inBackground = false
    /// The app's state as UIKit reports it, read as a session goes live.
    /// Internal so tests can stand in for UIKit: the test runner can't be
    /// sent to the background.
    var applicationState: () -> UIApplication.State = { UIApplication.shared.applicationState }

    // ── Short break ("allow another app briefly") ────────────────────
    /// When `allowShortBreak` is true a background gap ≤ `shortBreakWindow`
    /// keeps the SAME session; a longer gap (or `allow=false`) rotates to a
    /// fresh session on return, so a long absence can't inflate one multi-hour
    /// session — the mobile analogue of the web SDK's inactivity rotation.
    /// Default tolerates up to 30 min so brief/medium app-switches don't
    /// fragment sessions. Set via `allowShortBreakForAnotherApp`.
    private var allowShortBreak = true
    private var shortBreakWindow: TimeInterval = 1800
    /// Wall-clock (not monotonic — CACurrentMediaTime pauses while suspended)
    /// timestamp of the last background, used to measure the break on return.
    private var backgroundedAt: TimeInterval = 0
    /// One per background cycle, held until that cycle's frame + message
    /// drains settle. Without it iOS may suspend the app as soon as
    /// didEnterBackground returns, cancelling those uploads. Per cycle so an
    /// earlier cycle's completion can't end a task a later cycle still needs.
    /// Main thread only.
    private var backgroundTasks = Set<UIBackgroundTaskIdentifier>()

    // ── Multi-session gate (record one session, or many) ─────────────
    /// `enabled` → every rotation opens a new session (default). `notStarted`
    /// → the current/next session is still allowed, then no more. `disabled`
    /// → refuse to open any further session this process. Evaluated at the one
    /// session-start chokepoint (`start()`), mirroring the reference's 3-state
    /// model — cleaner than a "sessions so far" counter. Set via
    /// `setMultiSessionRecord`.
    private enum MultiSessionState { case enabled, notStarted, disabled }
    private var multiSessionState: MultiSessionState = .enabled
    // Onboarding/verification callbacks, fired when /start succeeds.
    private var verificationListeners: [UUID: () -> Void] = [:]

    /// Sensitive window-coordinate rects (each with its render style) to mask
    /// in screenshots. Wired to the privacy registry by the host SDK.
    public var privacyRectsProvider: () -> [MaskRect] = { [] }

    /// Additional host-supplied rects, composed into `privacyRectsProvider`
    /// by `start`. Unlike `privacyRectsProvider` (which `start` assigns once
    /// the session opens), this is owned by the host and never overwritten —
    /// the integration point for hosts that compute occlusion off the UIKit
    /// tree (React Native / Flutter, which feed it window-point rects pulled
    /// from JS/Dart). Empty by default.
    public var externalPrivacyRectsProvider: () -> [MaskRect] = { [] }

    private init() {}

    public func start(config: ReplayConfig) {
        // Idempotent: a second start() must not wire a second collector /
        // screenshot timer / perf sampler onto the same singleton.
        if starting { return }
        // GDPR: honour an overall opt-out on the LIVE engine — never open a
        // session while opted out (the legacy facade checked this; the live
        // engine didn't).
        if OptOutStore.shared.overallOptOut { return }
        // Multi-session gate — the single place a session opens. `notStarted`
        // allows exactly this one (then flips to `disabled`); `disabled` refuses.
        switch multiSessionState {
        case .disabled: return
        case .notStarted: multiSessionState = .disabled
        case .enabled: break
        }
        starting = true
        let projectKey = config.apiKey
        let host = config.apiHost
        self.projectKey = projectKey
        self.host = host
        self.lastConfig = config
        self.autoScreenName = config.autoScreenName
        self.excludedScreens = Set(config.excludedScreens.map { $0.lowercased() })
        PrivacyRegistry.shared.webViewMaskingEnabled = !config.disableWebViewMasking
        let transport = MobileTransport(baseURL: host, projectKey: projectKey)
        self.transport = transport

        transport.start(params: ReplayCore.deviceParams(projectKey: projectKey, distinctID: distinctId)) { [weak self] resp in
            guard let self = self else { return }
            guard let resp = resp else { self.starting = false; return } // allow retry
            // Server sampling gate dropped this launch — don't record. Leave
            // `starting` true so we don't re-roll on a spurious re-init.
            if resp.record == false { return }
            DispatchQueue.main.async {
                self.sessionID = resp.sessionID
                self.startedAt = nowMs()
                // Client config is the default; remote-config (the /start
                // response) overrides it when the server specifies a value.
                self.captureConsole = resp.captureConsole ?? config.captureConsole
                self.captureNetwork = resp.captureNetwork ?? config.captureNetwork
                // API value wins when present; otherwise fall back to local
                // config (so clients can remote-configure from the dashboard,
                // but local config still applies when the server is silent).
                self.captureNetworkHeaders = resp.captureNetworkHeaders ?? config.captureHeaders
                self.captureNetworkBodies = resp.captureNetworkBodies ?? config.captureBodies
                // The dashboard's "always mask input values" switch, applied
                // before the first frame. ORed with the app's own
                // occludeAllTextFields, so it can only add masking; a server
                // that doesn't send it clears it, and it applies whatever
                // useRemoteConfig says.
                PrivacyRegistry.shared.remoteOccludeAllTextFields = resp.privacy?.occludeAllTextFields ?? false

                // Wire screenshot privacy masking to the PrivacyRegistry — the
                // same source the legacy capture path consults. Without this
                // the frames screenshotter masks nothing: addPrivacyView,
                // occludeAll*, applyOcclusion, occludeSensitiveScreen and
                // secure text fields all register correctly but never reach
                // the JPEGs. Resolved once per frame on the capture (main)
                // thread, so the UIKit view-tree walk is safe.
                self.privacyRectsProvider = {
                    PrivacyRegistry.shared.windowPrivacyBounds()
                        + self.externalPrivacyRectsProvider()
                }

                let collector = MobileCollector(transport: transport)
                let screenshots = MobileScreenshots(
                    transport: transport,
                    nativeCapture: config.captureSnapshotPixels,
                    privacyRects: { self.privacyRectsProvider() },
                    // Looks up the password inputs inside web views before
                    // each native capture.
                    prepareFrame: { PrivacyRegistry.shared.prepareFrame($0) }
                )
                screenshots.setSettings(fps: resp.fps, quality: resp.quality)
                self.collector = collector

                collector.start()
                // captureSnapshotPixels=false → events only, no frames archive.
                self.attachFrames(screenshots, nativeCapture: config.captureSnapshotPixels)
                // Flutter hosts pass captureTouch:false — the Dart layer
                // reports taps with the real widget label via reportInteraction
                // (the native view-tree only ever sees the one FlutterView).
                if config.captureTouch {
                    self.touch.install { label, x, y, kind, direction in
                        // kind ∈ tap / swipe / long_press — routed to click /
                        // swipe / gesture by reportInteraction.
                        self.reportInteraction(kind: kind, label: label, x: x, y: y, direction: direction)
                    }
                }
                // Text-input observation is opt-in per field (via
                // Replay.addObservedInput); wire the sink so observed fields
                // report their value on editing-end.
                self.input.onInput = { [weak self] value, masked, label in
                    self?.sendInput(value: value, masked: masked, label: label)
                }
                // Screen tracking → viewComponent messages. Gated at emission
                // (not install) so setAutomaticScreenNameTagging can toggle it
                // at runtime.
                MobileScreenTracker.install { [weak self] screen, visible in
                    guard self?.autoScreenName == true else { return }
                    self?.sendScreen(screenName: screen, viewName: screen, visible: visible)
                }
                // Performance metrics → performanceEvent messages.
                let perf = MobilePerfMonitor { [weak self] name, value in
                    self?.sendPerformance(name: name, value: value)
                }
                perf.start()
                self.perf = perf
                // Crash reporting. Two complementary handlers:
                //   1. PLCrashReporter (signal/EXC: SIGSEGV, EXC_BAD_ACCESS,
                //      force-unwrap, fatalError, …) — recorded in-process,
                //      drained + emitted through the live wire on the NEXT
                //      launch. NSException-derived reports carry exceptionInfo
                //      and are skipped here, because:
                //   2. MobileCrashHandler catches uncaught NSExceptions
                //      in-process THIS session (installed last so it owns the
                //      ObjC uncaught handler). Together they cover every crash
                //      class with no duplicate.
                if config.captureErrors {
                    let crash = CrashHandler { [weak self] record in
                        // Skip the NSException path — MobileCrashHandler reports
                        // those in-process (below). PLCrashReporter also catches
                        // the resulting abort(): sometimes WITH exceptionInfo
                        // (isException), sometimes as a bare SIGABRT (detail).
                        // Skip both. Trade-off: a pure abort()/assert SIGABRT
                        // (no NSException) isn't captured; the dominant classes
                        // (SIGSEGV/SIGBUS/SIGILL/SIGTRAP/EXC_BAD_ACCESS) are.
                        guard !record.isException, record.detail != "SIGABRT"
                        else { return }
                        self?.sendCrash(name: record.detail, reason: "",
                                        stacktrace: record.stack ?? record.detail)
                    }
                    crash.install()
                    self.crashHandler = crash

                    MobileCrashHandler.install { [weak self] name, reason, stack in
                        self?.sendCrash(name: name, reason: reason, stacktrace: stack)
                    }
                }
                self.registerLifecycle()

                // Drain anything queued during the /start round-trip, then
                // go live. Holding the lock across the flip keeps a
                // concurrent enqueue() from racing past the drain.
                self.preStartLock.lock()
                for m in self.preStart { collector.add(m) }
                self.preStart.removeAll()
                self.ready = true
                self.preStartLock.unlock()

                self.active = true
                NSLog("[ReplaySdk] session live: \(resp.sessionID)")
                // Session is live — fire onboarding/verification listeners.
                for listener in self.verificationListeners.values { listener() }
            }
        }
    }

    /// Hand a message to the collector if the session is live, otherwise
    /// buffer it until start()'s drain runs. Bounded at 1000 to cap the
    /// worst case where `/start` never returns.
    private func enqueue(_ msg: Data) {
        preStartLock.lock(); defer { preStartLock.unlock() }
        if ready, let c = collector {
            c.add(msg)
        } else if preStart.count < 1000 {
            preStart.append(msg)
        }
    }

    /// Messages waiting for the session to go live. For tests.
    var preStartMessages: [Data] {
        preStartLock.lock(); defer { preStartLock.unlock() }
        return preStart
    }

    /// Hand the live session its frame buffer, and start native capture
    /// unless a hold that began before the session went live says not yet (an
    /// excluded screen tagged during the async /start round-trip, a host
    /// pause, a persisted opt-out) or the app is in the background; capture
    /// then starts when the hold lifts or the app returns.
    /// Internal so tests can drive the engine's holds against a stub upload
    /// path, without the /start round-trip.
    func attachFrames(_ screenshots: MobileScreenshots, nativeCapture: Bool) {
        self.screenshots = screenshots
        // The lifecycle observers come and go with the session, so they never
        // saw a background that began before this session went live: one
        // restarted there (startNewSession, stop + start), or opened by a
        // background launch (a silent push or background fetch running
        // didFinishLaunching). Ask UIKit. The observers are registered in this
        // same main-thread pass, so the return can't slip in between.
        inBackground = applicationState() == .background
        if nativeCapture && !framesHeld && !inBackground { screenshots.start() }
    }

    public func stop() {
        active = false
        starting = false
        framesExcluded = false
        screenshots?.stop(); screenshots = nil
        collector?.stop(); collector = nil
        touch.uninstall()
        NotificationCenter.default.removeObserver(self)
        sessionID = nil
        preStartLock.lock(); preStart.removeAll(); ready = false; preStartLock.unlock()
    }

    // ── Lifecycle controls (facade re-homes, #119) ───────────────────
    /// Host pause (pauseRecording): stop frames until resumeCapture(); events
    /// keep flowing. Holds across background/foreground.
    func pauseCapture() {
        onMain {
            self.hostPaused = true
            self.screenshots?.pause()
        }
    }

    /// Host resume. Frames restart unless something else still holds them
    /// (an excluded screen in front, a persisted schematic opt-out) or the app
    /// is in the background (onForeground restarts them).
    func resumeCapture() {
        onMain {
            self.hostPaused = false
            if !self.framesHeld && !self.inBackground { self.screenshots?.resume() }
        }
    }

    /// Schematic opt-out (Replay.optOutOfSchematicRecordings): persisted, and
    /// applied to the live engine like pauseCapture / resumeCapture. Not the
    /// same hold: opting back in must not lift a pauseRecording still in
    /// effect (a consent sync on every launch would restart frames on a PIN
    /// screen).
    func setSchematicOptOut(_ optOut: Bool) {
        // Written at once, on the caller's thread: host-fed frames are refused
        // from here on, and isOptedOutOfSchematicRecordings reads it back as
        // soon as the call returns. Whether it changed is only visible before
        // the write, hence the write here rather than by the caller.
        let changed = OptOutStore.shared.schematicOptOut != optOut
        OptOutStore.shared.schematicOptOut = optOut
        // Act only on an actual change, so a repeated call doesn't flush a
        // partial archive.
        guard changed else { return }
        onMain {
            // Another hold keeps frames paused either way.
            guard !self.framesExcluded, !self.hostPaused else { return }
            if optOut {
                self.screenshots?.pause()
            } else if !self.inBackground {
                self.screenshots?.resume()
            }
        }
    }

    /// Changes to the holds and to `inBackground` happen on the main thread,
    /// where the lifecycle observers and the capture timer run. A host may
    /// call from any thread (the React Native bridge calls from its own module
    /// queue). Off main, a resume that saw the app in front could restart
    /// capture just after onBackground had stopped it. On main the work runs
    /// inline, so a frame reported right after a pause is refused. Off main
    /// it is queued, in call order. (stop() and cancelSession() still run on
    /// the caller's thread.)
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// Toggle auto screen-name tagging at runtime.
    func setAutoScreenName(_ enabled: Bool) { autoScreenName = enabled }

    // ── Screen exclusion ("don't record this screen") ────────────────
    /// Replace the excluded-screens denylist.
    func setExcludedScreens(_ names: [String]) {
        excludedScreens = Set(names.map { $0.lowercased() })
    }
    /// Add one screen to the excluded set.
    func excludeScreen(_ name: String) { excludedScreens.insert(name.lowercased()) }
    /// Remove one screen from the excluded set (recording resumes next time it shows).
    func unexcludeScreen(_ name: String) { excludedScreens.remove(name.lowercased()) }

    // ── Advanced gestures / short break / multi-session ──────────────
    /// Toggle pinch/rotate correlation in the touch capture.
    func setAdvancedGestures(_ enabled: Bool) { MobileTouchCapture.advancedGesturesEnabled = enabled }

    /// Configure the short-break policy (see `allowShortBreak`). A zero/negative
    /// window keeps the current default rather than disabling the window.
    func setAllowShortBreak(_ allow: Bool, windowSeconds: TimeInterval) {
        allowShortBreak = allow
        if windowSeconds > 0 { shortBreakWindow = windowSeconds }
    }

    /// Turn multi-session recording on/off. Off → the current/next session is
    /// still allowed, then no further sessions open this process.
    func setMultiSessionRecord(_ enabled: Bool) {
        multiSessionState = enabled ? .enabled : .notStarted
    }

    /// Discard the current session WITHOUT uploading. Our engine streams
    /// batches live every ~5s, so (unlike a deferred-upload model where cancel
    /// is a pure local delete) we must signal the backend to DROP what already
    /// landed, then clear the in-memory buffers and tear down — never flushing.
    /// A fresh session can start afterward (the multi-session gate is untouched).
    public func cancelSession() {
        // Backend drop first, while the session token is still valid.
        if let sid = sessionID { transport?.cancel(sessionID: sid) }
        active = false
        starting = false
        framesExcluded = false
        // discard() = the stop() counterpart that clears buffers WITHOUT flushing.
        screenshots?.discard(); screenshots = nil
        collector?.discard(); collector = nil
        touch.uninstall()
        NotificationCenter.default.removeObserver(self)
        sessionID = nil
        preStartLock.lock(); preStart.removeAll(); ready = false; preStartLock.unlock()
    }

    /// End the current session and immediately start a fresh one using the
    /// config retained from the first start(). No-op before start() runs.
    func startNewSession() {
        guard let cfg = lastConfig else { return }
        // A rotation doesn't change what is on screen: keep the exclusions set
        // at runtime (start() re-seeds them from the config) and whether an
        // excluded screen is in front, so its frames stay paused in the new
        // session until the user leaves it.
        let screens = excludedScreens
        let excluded = framesExcluded
        stop()
        start(config: cfg)
        excludedScreens = screens
        framesExcluded = excluded
    }

    /// Register an onboarding/verification callback fired when /start
    /// succeeds. Returns a token for removal.
    func addVerificationListener(_ listener: @escaping () -> Void) -> UUID {
        let id = UUID()
        verificationListeners[id] = listener
        return id
    }

    func removeVerificationListener(_ token: UUID) {
        verificationListeners.removeValue(forKey: token)
    }

    // ── Message API (called by listeners) ────────────────────────────
    func sendClick(label: String, x: UInt64, y: UInt64) {
        enqueue(MobileWire.click(label: label, x: x, y: y, timestamp: nowMs()))
    }
    func sendSwipe(label: String, x: UInt64, y: UInt64, direction: String) {
        enqueue(MobileWire.swipe(label: label, x: x, y: y, direction: direction, timestamp: nowMs()))
    }
    /// Entry point for host-reported interactions (the Flutter plugin's
    /// Dart-side gesture capture). `kind` is "tap" / "long_press" / "swipe";
    /// a long-press is recorded as a click (the dashboard keys gestures off the
    /// label + coordinates), and swipes carry their direction.
    /// The single funnel for native and host-reported gestures, so hiding
    /// gestures with an occluded screen (the reference tracker's default)
    /// covers both; when an app keeps them, their labels are blanked, as the
    /// frames are.
    public func reportInteraction(kind: String, label: String, x: UInt64, y: UInt64, direction: String) {
        let privacy = PrivacyRegistry.shared
        if privacy.occludeAllScreen && privacy.hideScreenGestures { return }
        let label = privacy.occludeAllScreen ? "***" : label
        switch kind {
        case "swipe": sendSwipe(label: label, x: x, y: y, direction: direction)
        case "tap": sendClick(label: label, x: x, y: y)
        default:
            // long_press / double_tap / pinch / rotate → distinct gesture event.
            enqueue(MobileWire.gesture(kind: kind, label: label, x: x, y: y, direction: direction, timestamp: nowMs()))
        }
    }
    func sendInput(value: String, masked: Bool, label: String) {
        enqueue(MobileWire.input(value: value, masked: masked, label: label, timestamp: nowMs()))
    }
    /// Opt a `UITextField` into input recording (reports on editing-end).
    func observeInput(_ field: UITextField) {
        input.observe(field)
    }

    /// Ingest a host-captured frame + occlusion rects (Flutter's Dart-side
    /// capture). `rects` are in PNG-pixel coords; `styles[i]` is the raw
    /// `ReplayMaskStyle` index for `rects[i]`, falling back to the global style.
    func submitFrame(_ png: Data, rects: [CGRect], styles: [Int]) {
        // Host-fed frames obey the same holds as native capture: an excluded
        // screen, pauseRecording and the schematic opt-out. Nor are they taken
        // in the background: pause() stops only the native timer, and the
        // host's own (Flutter's Dart timer) keeps firing for as long as the
        // background task keeps the app running.
        guard !framesHeld, !inBackground else { return }
        let global = PrivacyRegistry.shared.maskStyle
        let maskRects = rects.enumerated().map { i, r -> MaskRect in
            let style = i < styles.count ? (ReplayMaskStyle(rawValue: styles[i]) ?? global) : global
            return MaskRect(rect: r, style: style)
        }
        // The host only reports its own mask widgets: the app's
        // occludeSensitiveScreen covers the whole frame here too.
        screenshots?.submitFrame(png, rects: maskRects, occludeAll: PrivacyRegistry.shared.occludeAllScreen)
    }
    func sendPerformance(name: String, value: UInt64) {
        enqueue(MobileWire.performance(name: name, value: value, timestamp: nowMs()))
    }
    func sendLog(severity: String, content: String) {
        guard captureConsole else { return }
        enqueue(MobileWire.log(severity: severity, content: content, timestamp: nowMs()))
    }
    func sendNetwork(type: String, method: String, url: String, request: String, response: String, status: UInt64, duration: UInt64) {
        guard captureNetwork else { return }
        // Honour the workspace's granular toggles here — the single chokepoint
        // for both native (URLSessionCapture) and RN (recordNetwork) traffic —
        // so disabled headers/bodies never leave the device.
        let req = filterNetSide(request)
        let resp = filterNetSide(response)
        enqueue(MobileWire.networkCall(type: type, method: method, url: url, request: req, response: resp, status: status, duration: duration, timestamp: nowMs()))
    }

    /// Strip `headers` and/or `body` from a `{headers, body}` JSON side per the
    /// workspace toggles. No-op (returns the original) when both are enabled.
    private func filterNetSide(_ json: String) -> String {
        if captureNetworkHeaders && captureNetworkBodies { return json }
        guard let data = json.data(using: .utf8),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return json }
        if !captureNetworkHeaders { obj["headers"] = [String: String]() }
        if !captureNetworkBodies { obj["body"] = NSNull() }
        if let out = try? JSONSerialization.data(withJSONObject: obj),
           let s = String(data: out, encoding: .utf8) {
            return s
        }
        return json
    }
    func sendCrash(name: String, reason: String, stacktrace: String) {
        enqueue(MobileWire.crash(name: name, reason: reason, stacktrace: stacktrace, timestamp: nowMs()))
        // Synchronous — the process is about to die.
        collector?.flushBlocking()
    }
    func sendScreen(screenName: String, viewName: String, visible: Bool) {
        enqueue(MobileWire.viewComponent(screenName: screenName, viewName: viewName, visible: visible, timestamp: nowMs()))
        // "Don't record this screen": pause the frame loop when we ENTER an
        // excluded screen and resume when we LEAVE it (transition-gated so we
        // don't churn pause/resume on every tag). Leaving one doesn't restart
        // frames another hold keeps, nor in the background (onForeground
        // restarts them). Everything else (this event, taps, network, console,
        // perf) keeps flowing.
        guard visible else { return }
        let excluded = excludedScreens.contains(screenName.lowercased())
        onMain {
            guard excluded != self.framesExcluded else { return }
            self.framesExcluded = excluded
            if excluded {
                self.screenshots?.pause()
                NSLog("[ReplaySdk] screen-exclude: PAUSED frames on '\(screenName)'")
            } else if !self.framesHeld && !self.inBackground {
                self.screenshots?.resume()
                NSLog("[ReplaySdk] screen-exclude: RESUMED frames on '\(screenName)'")
            }
        }
    }
    public func sendEvent(name: String, payload: String) {
        // RN/Flutter forward console logs as the reserved `$console` event, so
        // honour the API's captureConsole toggle here too (sendLog already does
        // for native logs). Custom events and `$exception` still flow.
        if name == "$console" && !captureConsole { return }
        enqueue(MobileWire.event(name: name, payload: payload, timestamp: nowMs()))
    }
    public func setUserID(_ id: String) {
        distinctId = id
        enqueue(MobileWire.userID(id, timestamp: nowMs()))
    }
    public func sendMetadata(key: String, value: String) {
        enqueue(MobileWire.metadata(key: key, value: value, timestamp: nowMs()))
    }

    // ── Lifecycle ────────────────────────────────────────────────────
    /// Internal so tests can wire it and post the notifications themselves.
    func registerLifecycle() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(onBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(onForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }
    @objc private func onBackground() {
        inBackground = true
        sendPerformance(name: "background", value: 1)
        // Stamp the break start (wall clock) so onForeground can size the gap.
        backgroundedAt = Date().timeIntervalSince1970
        // Upload everything buffered before iOS suspends the app, holding a
        // background task until both drains settle. Frames upload only once a
        // batch fills, so without this every frame captured since the last
        // full batch was lost whenever the app was suspended or killed in the
        // background. pause() also stops capture so we don't inflate the
        // archive with invisible-window frames. Neither drain discards
        // anything: what misses the window goes out on onForeground.
        let task = beginBackgroundTask()
        let drains = DispatchGroup()
        if let screenshots {
            drains.enter()
            screenshots.pause { drains.leave() }
        }
        if let collector {
            drains.enter()
            collector.drain { drains.leave() }
        }
        drains.notify(queue: .main) { [weak self] in self?.endBackgroundTask(task) }
    }
    @objc private func onForeground() {
        inBackground = false
        let elapsed = backgroundedAt > 0 ? (Date().timeIntervalSince1970 - backgroundedAt) : 0
        backgroundedAt = 0
        // Short-break policy: a gap longer than the tolerated window (or short
        // breaks disallowed) rotates to a fresh session so a long absence can't
        // extend one session for hours. startNewSession() is itself gated by the
        // multi-session state machine, so a disabled multi-session simply ends
        // recording instead of rotating.
        if !allowShortBreak || elapsed > shortBreakWindow {
            NSLog("[ReplaySdk] short-break: gap \(Int(elapsed))s > window \(Int(shortBreakWindow))s — rotating session")
            startNewSession()
            return
        }
        sendPerformance(name: "background", value: 0)
        // Push what the background window could not get out (suspension
        // cancels in-flight uploads), rather than waiting for the next full
        // batch or timer tick. An excluded screen still in front keeps its
        // frames paused, as does a host pause or opt-out; only leftovers go.
        if framesHeld {
            screenshots?.flush(all: true)
        } else {
            screenshots?.resume()
        }
        collector?.flush()
    }

    private func beginBackgroundTask() -> UIBackgroundTaskIdentifier {
        var task: UIBackgroundTaskIdentifier = .invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "ReplayfyUpload") { [weak self] in
            // Out of background time: in-flight uploads fail and re-queue
            // themselves, so ending the task here loses nothing.
            self?.endBackgroundTask(task)
        }
        if task != .invalid { backgroundTasks.insert(task) }
        return task
    }

    /// Reached from the drain completion and from the expiration handler, so
    /// hop to main: UIApplication is main-thread-only, and the set makes a
    /// second end of the same task a no-op.
    private func endBackgroundTask(_ task: UIBackgroundTaskIdentifier) {
        let end = {
            guard self.backgroundTasks.remove(task) != nil else { return }
            UIApplication.shared.endBackgroundTask(task)
        }
        if Thread.isMainThread { end() } else { DispatchQueue.main.async(execute: end) }
    }

    // ── /start device params ─────────────────────────────────────────
    private static func deviceParams(projectKey: String, distinctID: String?) -> [String: Any] {
        let screen = UIScreen.main.bounds
        let info = Bundle.main.infoDictionary
        var params: [String: Any] = [
            "projectKey": projectKey,
            "platform": "ios",
            "trackerVersion": "2.0.0",
            "revID": (info?["CFBundleVersion"] as? String) ?? "N/A",
            // Marketing version (e.g. "1.4.2") — the human release identifier
            // Release Intelligence prefers, over the build number in revID.
            "appVersion": (info?["CFBundleShortVersionString"] as? String) ?? "",
            "userUUID": ReplayCore.persistentUUID(),
            "userOSVersion": UIDevice.current.systemVersion,
            "userDevice": ReplayCore.deviceModel(),
            "userDeviceType": UIDevice.current.model,
            "timestamp": nowMs(),
            "deviceMemory": UInt64(ProcessInfo.processInfo.physicalMemory / 1024),
            "timezone": ReplayCore.timezone(),
            "connectionType": ReplayCore.connectionType(),
            "width": Int(screen.width),
            "height": Int(screen.height),
        ]
        // If identify() ran before start, send the id so the sampling gate can
        // honour alwaysRecordIdentified.
        if let d = distinctID, !d.isEmpty { params["distinctId"] = d }
        if let fw = framework, !fw.isEmpty { params["framework"] = fw }
        return params
    }

    private static func persistentUUID() -> String {
        let key = "io.replayfy.userUUID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let uuid = UUID().uuidString
        UserDefaults.standard.set(uuid, forKey: key)
        return uuid
    }
    private static func deviceModel() -> String {
        // On the Simulator, utsname.machine is the host arch (arm64/x86_64).
        // The real device identifier we map to a marketing name lives in this
        // env var, so prefer it when present.
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"],
           !sim.isEmpty {
            return sim
        }
        var sysinfo = utsname(); uname(&sysinfo)
        let mirror = Mirror(reflecting: sysinfo.machine)
        let id = mirror.children.compactMap { ($0.value as? Int8).flatMap { $0 == 0 ? nil : String(UnicodeScalar(UInt8($0))) } }.joined()
        return id.isEmpty ? "iPhone" : id
    }
    private static func timezone() -> String {
        let offset = TimeZone.current.secondsFromGMT()
        let sign = offset >= 0 ? "+" : "-"
        return String(format: "UTC%@%02d:%02d", sign, abs(offset) / 3600, (abs(offset) % 3600) / 60)
    }

    /// Transport the device is on at session start — "wifi" / "cellular" /
    /// "none". Same values the reference's NWPathMonitor yields, read
    /// synchronously (no thread-blocking wait) so it can ride the /start
    /// payload. iOS rarely has wired ethernet, so non-cellular reachable
    /// resolves to "wifi".
    private static func connectionType() -> String {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        guard let reach = withUnsafePointer(to: &addr, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                SCNetworkReachabilityCreateWithAddress(nil, $0)
            }
        }) else { return "unknown" }
        var flags = SCNetworkReachabilityFlags()
        guard SCNetworkReachabilityGetFlags(reach, &flags) else { return "unknown" }
        if !flags.contains(.reachable) { return "none" }
        return flags.contains(.isWWAN) ? "cellular" : "wifi"
    }
}
#endif
