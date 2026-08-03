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
        starting = true
        let projectKey = config.apiKey
        let host = config.apiHost
        self.projectKey = projectKey
        self.host = host
        self.lastConfig = config
        self.autoScreenName = config.autoScreenName
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
                let screenshots = MobileScreenshots(transport: transport, privacyRects: { self.privacyRectsProvider() })
                screenshots.setSettings(fps: resp.fps, quality: resp.quality)
                self.collector = collector
                self.screenshots = screenshots

                collector.start()
                // captureSnapshotPixels=false → events only, no frames archive.
                if config.captureSnapshotPixels { screenshots.start() }
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

    public func stop() {
        active = false
        starting = false
        screenshots?.stop(); screenshots = nil
        collector?.stop(); collector = nil
        touch.uninstall()
        NotificationCenter.default.removeObserver(self)
        sessionID = nil
        preStartLock.lock(); preStart.removeAll(); ready = false; preStartLock.unlock()
    }

    // ── Lifecycle controls (facade re-homes, #119) ───────────────────
    /// Pause periodic screenshot capture; events keep flowing.
    func pauseCapture() { screenshots?.pause() }

    /// Resume periodic screenshot capture.
    func resumeCapture() { screenshots?.resume() }

    /// Toggle auto screen-name tagging at runtime.
    func setAutoScreenName(_ enabled: Bool) { autoScreenName = enabled }

    /// End the current session and immediately start a fresh one using the
    /// config retained from the first start(). No-op before start() runs.
    func startNewSession() {
        guard let cfg = lastConfig else { return }
        stop()
        start(config: cfg)
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
    public func reportInteraction(kind: String, label: String, x: UInt64, y: UInt64, direction: String) {
        switch kind {
        case "swipe": sendSwipe(label: label, x: x, y: y, direction: direction)
        case "tap": sendClick(label: label, x: x, y: y)
        default:
            // long_press / double_tap / pinch → distinct gesture event.
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
        let global = PrivacyRegistry.shared.maskStyle
        let maskRects = rects.enumerated().map { i, r -> MaskRect in
            let style = i < styles.count ? (ReplayMaskStyle(rawValue: styles[i]) ?? global) : global
            return MaskRect(rect: r, style: style)
        }
        screenshots?.submitFrame(png, rects: maskRects)
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
    private func registerLifecycle() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(onBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(onForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }
    @objc private func onBackground() {
        sendPerformance(name: "background", value: 1)
        // Pause capture while backgrounded so we don't inflate the archive
        // with invisible-window frames; pause() flushes what's pending.
        screenshots?.pause()
        collector?.flush()
    }
    @objc private func onForeground() {
        sendPerformance(name: "background", value: 0)
        screenshots?.resume()
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
