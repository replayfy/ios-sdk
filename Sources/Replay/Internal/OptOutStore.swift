import Foundation

/// Persistent flag store for the SDK's two GDPR-style kill switches:
///
///   - **Overall opt-out** — full SDK halt. No events buffered, no
///     snapshots taken, no uploads attempted. Customer-side calls
///     to `track()` / `identify()` etc. become no-ops. This is the
///     hammer customers reach for in "Do not sell my data" /
///     "Withdraw consent" flows.
///
///   - **Schematic opt-out** — partial halt. Events keep flowing
///     (taps, network, console, lifecycle) but pixel capture stops.
///     The dashboard still shows a session timeline but the player
///     stage is empty. Useful for screens where the pixel content
///     is regulated (HIPAA-covered health data) but the interaction
///     analytics are still wanted.
///
/// Stored in UserDefaults (sync; durable across launches, lives in
/// the app's standard backup-eligible container). Defaults are
/// **opted in** for both flags — customers MUST take action to opt
/// out, matching the reference mobile SDK's semantics + most analytics SDKs.
///
/// Mirrors the reference mobile SDK's `optOutOverall(bool)` + `optOutOfSchematicRecordings(bool)`
/// APIs. Read by ``LegacyCore`` at the top of every emit / capture
/// path so flips take effect on the next event without waiting for
/// a process restart.
///
/// Mirrors the Android SDK's `OptOutStore.kt` — same key shape so
/// cross-platform debugging tools (a future "show me this device's
/// opt-out state" inspector) work uniformly.
final class OptOutStore {

    private let defaults: UserDefaults
    private static let suiteName = "com.replayfy.optout.v1"
    private static let keyOverall = "overall_optout"
    private static let keySchematic = "schematic_optout"

    /// Singleton — the public ``Replay`` API is enum-static, so the
    /// store has to be reachable without an instance.
    static let shared = OptOutStore()

    init() {
        // Suite-specific UserDefaults so we don't pollute the host
        // app's standard defaults namespace. Fall back to standard
        // if the suite init fails (theoretically possible in
        // sandboxed-share-extension contexts).
        self.defaults = UserDefaults(suiteName: OptOutStore.suiteName)
            ?? UserDefaults.standard
    }

    var overallOptOut: Bool {
        get { defaults.bool(forKey: OptOutStore.keyOverall) }
        // Writes are sync — opt-out is a privacy boundary; the
        // on-disk state must match the in-memory state by the time
        // the call returns. UserDefaults's set(_:forKey:) is
        // already synchronous; UserDefaults.synchronize() is a
        // no-op on modern iOS but doesn't hurt to call.
        set {
            defaults.set(newValue, forKey: OptOutStore.keyOverall)
        }
    }

    var schematicOptOut: Bool {
        get { defaults.bool(forKey: OptOutStore.keySchematic) }
        set {
            defaults.set(newValue, forKey: OptOutStore.keySchematic)
        }
    }
}
