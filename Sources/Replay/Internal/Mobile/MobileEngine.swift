#if canImport(UIKit)
import UIKit

/// Orchestrates the reference mobile recording engine: session start,
/// screenshot capture, binary message collection, and lifecycle.
///
/// Listeners (touch, input, screen, perf, log, crash, network) call the
/// `send*` methods, which encode a binary message and hand it to the
/// collector. Screenshots flow independently to /v1/mobile/images.
public final class MobileEngine {
    public static let shared = MobileEngine()

    private var transport: MobileTransport?
    private var collector: MobileCollector?
    private var screenshots: MobileScreenshots?
    private let touch = MobileTouchCapture()
    private var perf: MobilePerfMonitor?

    private(set) var sessionID: String?
    private(set) var startedAt: UInt64 = 0
    private var active = false

    /// Sensitive window-coordinate rects to mask in screenshots.
    /// Wired to the privacy registry by the host SDK.
    public var privacyRectsProvider: () -> [CGRect] = { [] }

    private init() {}

    public func start(projectKey: String, host: String) {
        let transport = MobileTransport(baseURL: host, projectKey: projectKey)
        self.transport = transport

        transport.start(params: MobileEngine.deviceParams(projectKey: projectKey)) { [weak self] resp in
            guard let self = self, let resp = resp else { return }
            DispatchQueue.main.async {
                self.sessionID = resp.sessionID
                self.startedAt = nowMs()

                let collector = MobileCollector(transport: transport)
                let screenshots = MobileScreenshots(transport: transport, privacyRects: { self.privacyRectsProvider() })
                screenshots.setSettings(fps: resp.fps, quality: resp.quality)
                self.collector = collector
                self.screenshots = screenshots

                collector.start()
                screenshots.start()
                self.touch.install { label, x, y, isSwipe, direction in
                    if isSwipe {
                        self.sendSwipe(label: label, x: x, y: y, direction: direction)
                    } else {
                        self.sendClick(label: label, x: x, y: y)
                    }
                }
                // Screen tracking → viewComponent messages.
                MobileScreenTracker.install { [weak self] screen, visible in
                    self?.sendScreen(screenName: screen, viewName: screen, visible: visible)
                }
                // Performance metrics → performanceEvent messages.
                let perf = MobilePerfMonitor { [weak self] name, value in
                    self?.sendPerformance(name: name, value: value)
                }
                perf.start()
                self.perf = perf
                // Uncaught-exception crash reporting.
                MobileCrashHandler.install { [weak self] name, reason, stack in
                    self?.sendCrash(name: name, reason: reason, stacktrace: stack)
                }
                self.registerLifecycle()
                self.active = true
            }
        }
    }

    public func stop() {
        active = false
        screenshots?.stop(); screenshots = nil
        collector?.stop(); collector = nil
        touch.uninstall()
        NotificationCenter.default.removeObserver(self)
        sessionID = nil
    }

    // ── Message API (called by listeners) ────────────────────────────
    func sendClick(label: String, x: UInt64, y: UInt64) {
        collector?.add(MobileWire.click(label: label, x: x, y: y, timestamp: nowMs()))
    }
    func sendSwipe(label: String, x: UInt64, y: UInt64, direction: String) {
        collector?.add(MobileWire.swipe(label: label, x: x, y: y, direction: direction, timestamp: nowMs()))
    }
    func sendInput(value: String, masked: Bool, label: String) {
        collector?.add(MobileWire.input(value: value, masked: masked, label: label, timestamp: nowMs()))
    }
    func sendPerformance(name: String, value: UInt64) {
        collector?.add(MobileWire.performance(name: name, value: value, timestamp: nowMs()))
    }
    func sendLog(severity: String, content: String) {
        collector?.add(MobileWire.log(severity: severity, content: content, timestamp: nowMs()))
    }
    func sendNetwork(type: String, method: String, url: String, request: String, response: String, status: UInt64, duration: UInt64) {
        collector?.add(MobileWire.networkCall(type: type, method: method, url: url, request: request, response: response, status: status, duration: duration, timestamp: nowMs()))
    }
    func sendCrash(name: String, reason: String, stacktrace: String) {
        collector?.add(MobileWire.crash(name: name, reason: reason, stacktrace: stacktrace, timestamp: nowMs()))
        collector?.flush()
    }
    func sendScreen(screenName: String, viewName: String, visible: Bool) {
        collector?.add(MobileWire.viewComponent(screenName: screenName, viewName: viewName, visible: visible, timestamp: nowMs()))
    }
    public func sendEvent(name: String, payload: String) {
        collector?.add(MobileWire.event(name: name, payload: payload, timestamp: nowMs()))
    }
    public func setUserID(_ id: String) {
        collector?.add(MobileWire.userID(id, timestamp: nowMs()))
    }

    // ── Lifecycle ────────────────────────────────────────────────────
    private func registerLifecycle() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(onBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(onForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }
    @objc private func onBackground() {
        sendPerformance(name: "background", value: 1)
        screenshots?.flush()
        collector?.flush()
    }
    @objc private func onForeground() {
        sendPerformance(name: "background", value: 0)
    }

    // ── /start device params ─────────────────────────────────────────
    private static func deviceParams(projectKey: String) -> [String: Any] {
        let screen = UIScreen.main.bounds
        let info = Bundle.main.infoDictionary
        return [
            "projectKey": projectKey,
            "platform": "ios",
            "trackerVersion": "2.0.0",
            "revID": (info?["CFBundleVersion"] as? String) ?? "N/A",
            "userUUID": MobileEngine.persistentUUID(),
            "userOSVersion": UIDevice.current.systemVersion,
            "userDevice": MobileEngine.deviceModel(),
            "userDeviceType": UIDevice.current.model,
            "timestamp": nowMs(),
            "deviceMemory": UInt64(ProcessInfo.processInfo.physicalMemory / 1024),
            "timezone": MobileEngine.timezone(),
            "width": Int(screen.width),
            "height": Int(screen.height),
        ]
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
