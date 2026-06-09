#if canImport(UIKit)
import UIKit

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
    private var perf: MobilePerfMonitor?
    // PLCrashReporter handler for signal/EXC crashes — recorded in-process and
    // recovered + emitted through the live wire on the NEXT launch. Retained so
    // it (and the underlying reporter) isn't released.
    private var crashHandler: CrashHandler?
    // Live-presence socket (mirrors the web SDK's presence.ts): keeps this
    // session on the dashboard's online list for its lifetime; the backend
    // LiveGateway flips the EndUser online on connect / offline ~10s after
    // disconnect. Best-effort — never blocks capture.
    private var presence: MobilePresence?

    private(set) var sessionID: String?
    private(set) var startedAt: UInt64 = 0
    private var active = false
    // Project key + ingest host kept so the presence socket authenticates
    // with the same credentials as the HTTP transport.
    private var projectKey: String?
    private var host: String?
    // Last identified distinct id (identify → setUserID). Passed to the
    // presence socket so the dashboard attaches the session to the right user.
    private var distinctId: String?

    // Dashboard-controlled capture toggles, set from the /start response.
    private var captureConsole = true
    private var captureNetwork = true

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

                // Open the live-presence socket now we have a session id. Uses
                // the distinct id known so far (identify() before /start
                // completed sets it); identify() afterwards calls
                // updateDistinctId.
                let presence = MobilePresence()
                presence.start(host: host, projectKey: projectKey, sessionID: resp.sessionID, distinctID: self.distinctId)
                self.presence = presence

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
                self.touch.install { label, x, y, isSwipe, direction in
                    if isSwipe {
                        self.sendSwipe(label: label, x: x, y: y, direction: direction)
                    } else {
                        self.sendClick(label: label, x: x, y: y)
                    }
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
        presence?.stop(); presence = nil
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
    func sendInput(value: String, masked: Bool, label: String) {
        enqueue(MobileWire.input(value: value, masked: masked, label: label, timestamp: nowMs()))
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
        enqueue(MobileWire.networkCall(type: type, method: method, url: url, request: request, response: response, status: status, duration: duration, timestamp: nowMs()))
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
        enqueue(MobileWire.event(name: name, payload: payload, timestamp: nowMs()))
    }
    public func setUserID(_ id: String) {
        distinctId = id
        presence?.updateDistinctID(id)
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
            "userUUID": ReplayCore.persistentUUID(),
            "userOSVersion": UIDevice.current.systemVersion,
            "userDevice": ReplayCore.deviceModel(),
            "userDeviceType": UIDevice.current.model,
            "timestamp": nowMs(),
            "deviceMemory": UInt64(ProcessInfo.processInfo.physicalMemory / 1024),
            "timezone": ReplayCore.timezone(),
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
}
#endif
