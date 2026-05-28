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

    /// Max captured body size per network event. Bodies above are
    /// truncated with a "[truncated]" marker.
    public let maxBodyBytes: Int

    /// Capture full-screen pixel bytes alongside the view tree on
    /// each snapshot. Off → wireframe-only playback, still useful
    /// but visually plain. On → pixel-accurate via the asset endpoint.
    public let captureSnapshotPixels: Bool

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
        maxBodyBytes: Int = 4_096,
        captureSnapshotPixels: Bool = true
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
        self.maxBodyBytes = maxBodyBytes
        self.captureSnapshotPixels = captureSnapshotPixels
    }
}
