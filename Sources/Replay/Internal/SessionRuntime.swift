import Foundation

/// Owns the current session's in-memory state: id, segment id,
/// sequence counter, event buffer, start timestamp, SDK descriptor.
///
/// One ``SessionRuntime`` per active session. The lifecycle observer
/// rotates the instance on background→foreground transitions when
/// the gap exceeded the multi-session-record threshold.
///
/// Thread-safe — events get pushed from main (lifecycle, taps,
/// snapshots) AND background threads (network capture, performance
/// observers). Buffer + counters use serial-queue synchronization.
///
/// Mirrors the Android SDK's `SessionRuntime.kt` so cross-platform
/// behavior stays symmetric from the backend's perspective.
final class SessionRuntime {

    let sessionId: String
    private(set) var segmentId: String
    let startedAt: Int64
    let sdk: ReplaySdkDescriptor
    let deviceContext: ReplayPageContext

    private var sequence: Int = 0
    private var eventCounter: Int64 = 0
    private var buffer: [ReplayEvent] = []
    private let queue = DispatchQueue(
        label: "com.replayfy.ios.session-runtime",
        qos: .utility
    )

    private let config: ReplayConfig

    init(
        config: ReplayConfig,
        deviceContext: ReplayPageContext,
        appVersion: String? = nil,
        appBuild: String? = nil
    ) {
        self.config = config
        self.deviceContext = deviceContext
        self.sessionId = "ses_" + UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
            .prefix(16)
            .description
        self.segmentId = Self.makeSegmentId()
        self.startedAt = Self.nowMs()
        self.sdk = ReplaySdkDescriptor(
            name: BuildInfo.sdkName,
            version: BuildInfo.sdkVersion,
            platform: Platform.ios,
            appVersion: appVersion,
            appBuild: appBuild
        )
        self.buffer.reserveCapacity(128)
    }

    /// Append an event. Returns the buffer size post-append so the
    /// caller can decide whether to force-flush.
    @discardableResult
    func push(_ event: ReplayEvent) -> Int {
        queue.sync {
            buffer.append(event)
            return buffer.count
        }
    }

    /// Drain the buffer atomically. Caller owns the returned array.
    func drain() -> [ReplayEvent] {
        queue.sync {
            guard !buffer.isEmpty else { return [] }
            let out = buffer
            buffer.removeAll(keepingCapacity: true)
            return out
        }
    }

    /// Current buffer size — for force-flush decisions.
    var bufferSize: Int {
        queue.sync { buffer.count }
    }

    /// Generate the next event id. Format: `evt_<session-suffix>_<n>`.
    func makeEventId() -> String {
        queue.sync {
            eventCounter += 1
            return "evt_\(String(sessionId.dropFirst(4)))_\(eventCounter)"
        }
    }

    /// Advance the segment sequence + rotate the segment id.
    func nextSequence() -> Int {
        queue.sync {
            segmentId = Self.makeSegmentId()
            sequence += 1
            return sequence
        }
    }

    /// Whether the buffer should be force-flushed based on size cap.
    var shouldForceFlush: Bool {
        bufferSize >= config.maxBufferSize
    }

    /// Current wall-clock milliseconds — matches the JS web SDK's
    /// `Date.now()` so timestamps compare directly across platforms.
    static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private static func makeSegmentId() -> String {
        "seg_" + UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
            .prefix(16)
            .description
    }
}

/// SDK build identifiers — bumped in tandem with git tags. Centralised
/// here so BatchSender + SessionRuntime + DeviceContext all read the
/// same values without duplicating string literals.
enum BuildInfo {
    static let sdkName = "@replay/ios-sdk"
    static let sdkVersion = "0.0.5"
}
