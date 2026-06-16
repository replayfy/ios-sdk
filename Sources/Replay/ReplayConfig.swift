import Foundation

/// Configuration passed to `Replay.start(with:)`.
///
/// Defaults favour shipping useful data: console + errors on, network
/// off (PII risk), schematic recording on. Customer can flip via the
/// dashboard's `/v1/sdk/config` endpoint mid-session — backend pushes
/// updates that the SDK applies without re-init.
public struct ReplayConfig {

    /// Project API key from the dashboard. Required.
    public let apiKey: String

    /// Base URL of the ingest API — e.g. `https://ingest.replayfy.io`.
    public let apiHost: String

    /// Optional project id — only used when one key covers multiple
    /// projects on the same workspace.
    public let projectId: String?

    /// Distinct user id, if known at start time. Anonymous sessions
    /// (no `distinctId`) get a generated install-stable id derived
    /// from `UIDevice.identifierForVendor`.
    public let distinctId: String?

    /// Seconds between auto-flushes of the in-memory batch.
    public let flushInterval: TimeInterval

    /// Cap on events buffered in-memory before a flush is forced.
    public let maxBufferSize: Int

    /// When false, the live-mode WebSocket (future) is skipped.
    public let liveMode: Bool

    /// Capture `os_log` / `NSLog` / `print` output at runtime.
    public let captureConsole: Bool

    /// Capture URLSession requests via `URLProtocol` swizzle.
    public let captureNetwork: Bool

    /// Capture uncaught NSExceptions + signal-handler crashes.
    public let captureErrors: Bool

    /// Include request/response headers in network capture. PII risk.
    public let captureHeaders: Bool

    /// Include request/response bodies in network capture (capped at
    /// `maxBodyBytes`). PII risk. The dashboard's `captureNetworkBodies`
    /// overrides this when the server specifies it.
    public let captureBodies: Bool

    /// Max captured body size per network event. Bodies above are
    /// truncated with a "[truncated]" marker.
    public let maxBodyBytes: Int

    /// Capture full-screen pixel bytes alongside the view tree on
    /// each snapshot. Off → wireframe-only playback, still useful
    /// but visually plain. On → pixel-accurate via the asset endpoint.
    public let captureSnapshotPixels: Bool

    /// Cadence of the continuous snapshot loop, in seconds.
    ///
    /// Matches the reference mobile SDK's default ~2 FPS (0.5 s). Lower values mean
    /// smoother playback at the cost of CPU + upload bandwidth.
    /// Floor is clamped to 0.2 s inside
    /// ``Replay/Internal/Capture/SnapshotCapture/startPeriodic()``.
    public let snapshotInterval: TimeInterval

    /// Auto-detect screen names by swizzling
    /// `UIViewController.viewDidAppear`. When true (default),
    /// the current route is automatically the class name of the
    /// foremost VC — no need to call `Replay.tagScreenName` per
    /// screen. Manual `tagScreenName(...)` calls still take
    /// precedence until the next auto-detected change.
    ///
    /// Mirrors Android's same-named flag (default-on). Apps using
    /// custom container hierarchies that don't extend the standard
    /// UIViewController lifecycle should opt out here + call
    /// `tagScreenName` explicitly.
    public let autoScreenName: Bool

    /// Pull configuration from the dashboard's `/v1/sdk/config`
    /// endpoint and let it OVERRIDE the values supplied here. When
    /// true (default), every customer-passed field that maps to a
    /// dashboard setting becomes a fallback used only during the
    /// cold-launch first-fetch race. After the first successful
    /// fetch the dashboard always wins — including subsequent
    /// flips while the session is running (15-min refresh cycle).
    ///
    /// Set to false ONLY when the customer intentionally wants
    /// hard-coded behaviour (kiosk apps, smoke tests, white-label
    /// builds whose dashboard isn't theirs).
    public let useRemoteConfig: Bool

    /// Install the native view-tree touch capture. Default true. The Flutter
    /// plugin sets this false: a Flutter app is a single `FlutterView`, so the
    /// native hit-test can only ever label taps "FlutterView" — the Dart layer
    /// captures taps with the real widget label instead and reports them via
    /// `reportInteraction`, so native capture would only double-count.
    public let captureTouch: Bool

    public init(
        apiKey: String,
        apiHost: String,
        projectId: String? = nil,
        distinctId: String? = nil,
        flushInterval: TimeInterval = 5,
        maxBufferSize: Int = 500,
        liveMode: Bool = true,
        captureConsole: Bool = true,
        captureNetwork: Bool = false,
        captureErrors: Bool = true,
        captureHeaders: Bool = false,
        captureBodies: Bool = true,
        maxBodyBytes: Int = 4_096,
        captureSnapshotPixels: Bool = true,
        snapshotInterval: TimeInterval = 0.5,
        autoScreenName: Bool = true,
        useRemoteConfig: Bool = true,
        captureTouch: Bool = true
    ) {
        self.apiKey = apiKey
        self.apiHost = apiHost
        self.projectId = projectId
        self.distinctId = distinctId
        self.flushInterval = flushInterval
        self.maxBufferSize = maxBufferSize
        self.liveMode = liveMode
        self.captureConsole = captureConsole
        self.captureNetwork = captureNetwork
        self.captureErrors = captureErrors
        self.captureHeaders = captureHeaders
        self.captureBodies = captureBodies
        self.maxBodyBytes = maxBodyBytes
        self.captureSnapshotPixels = captureSnapshotPixels
        self.snapshotInterval = snapshotInterval
        self.autoScreenName = autoScreenName
        self.useRemoteConfig = useRemoteConfig
        self.captureTouch = captureTouch
    }
}
