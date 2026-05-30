import Foundation
#if canImport(MetricKit)
import MetricKit
#endif

/// Subscribes to Apple's MetricKit MXHangDiagnostic stream so we
/// can attach real main-thread stacks to the SDK's `anr_ms`
/// performance events.
///
/// **Why this exists**
///
/// ``HangWatchdog`` detects hangs in real-time (~250 ms latency)
/// from a background watchdog thread, but it can't safely walk the
/// main thread's stack from there — `mach_msg_trap` +
/// `thread_get_state` is brittle across iOS versions, and Apple
/// explicitly doesn't bless that pattern. So the live event ships
/// with `details: nil`.
///
/// MetricKit fills that gap: Apple records hang diagnostics
/// system-side + delivers them to a subscriber on the NEXT app
/// launch (or up to 24 h later when the OS schedules background
/// metric delivery). The diagnostic carries an `MXCallStackTree`
/// — the actual main-thread stack at hang time, symbolicated
/// against Apple's frameworks.
///
/// We subscribe at SDK start, queue every delivered hang, and emit
/// a secondary `perf` event with `metric = "anr_ms_metrickit"` and
/// `details` populated. The dashboard correlates by timestamp
/// (within ±5 minutes of the live `anr_ms` event) so support
/// engineers see both the live signal and the later-arriving
/// rich stack on the same session.
///
/// **iOS version gate**
///
/// MXHangDiagnostic requires iOS 14.0+. Older devices keep the
/// live-detection-only path. We don't crash on unsupported
/// platforms — the subscriber is a no-op.
///
/// **Background-delivery caveat**
///
/// MetricKit delivers reports once per day, asynchronously. A hang
/// the user just experienced may not arrive for many hours.
/// Dashboard rendering treats the live event as primary; the
/// MetricKit follow-up is an enrichment that lights up when it
/// arrives.

#if canImport(MetricKit) && canImport(UIKit)

@available(iOS 14.0, *)
final class MetricKitHangSubscriber: NSObject, MXMetricManagerSubscriber {

    /// Emitter — wired by ``ReplayCore`` to push a `perf` event
    /// with the captured stack as `details`. Pre-runtime buffered
    /// hangs (delivered before start() ran) are dropped; MetricKit
    /// re-delivers on next launch so we'll see them then.
    var emit: ((_ durationMs: Int64, _ stack: String) -> Void)?

    /// Install. Idempotent across SDK restarts — MXMetricManager
    /// dedupes subscribers by instance identity.
    func install() {
        MXMetricManager.shared.add(self)
    }

    /// Uninstall. Best-effort on Replay.stop; the next launch's
    /// install() re-adds us.
    func uninstall() {
        MXMetricManager.shared.remove(self)
    }

    // MARK: - MXMetricManagerSubscriber

    /// Diagnostic payloads — these are the per-hang reports
    /// (MetricKit also delivers separate metric-aggregate payloads
    /// via didReceive(metrics:) which we ignore — they're
    /// counters, not stacks).
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            // Hang diagnostics only. Crash + disk-write + CPU-
            // exception payloads exist on the same delivery — we
            // already cover crashes via PLCrashReporter.
            guard let hangs = payload.hangDiagnostics, !hangs.isEmpty else { continue }
            for hang in hangs {
                // hangDuration is an MXDuration (Foundation Measurement
                // of UnitDuration). Convert to ms — same unit shape
                // the live HangWatchdog ships.
                let durationMs = Int64(hang.hangDuration.converted(to: .milliseconds).value)
                let stack = renderStack(hang.callStackTree)
                emit?(durationMs, stack)
            }
        }
    }

    /// MetricKit's regular metrics delivery — we don't use it,
    /// but the protocol requires the method to exist. Kept
    /// empty so MetricKit can chain delivery efficiently.
    func didReceive(_ payloads: [MXMetricPayload]) {
        // Intentionally empty.
    }

    // -----------------------------------------------------------------
    //  MXCallStackTree → human-readable string
    // -----------------------------------------------------------------

    /// Render a call-stack tree as a multi-line string suitable
    /// for `PerformanceEventData.details`. Caps the output at
    /// 8 KB so a deep tree can't blow the batch envelope (same cap
    /// the live ANR path uses on Android).
    private func renderStack(_ tree: MXCallStackTree) -> String {
        // MXCallStackTree exposes JSON via jsonRepresentation();
        // we could ship the raw JSON for the dashboard to parse
        // structurally, but plain-text matches the Android shape
        // + is human-readable in the timeline view. Pick the
        // first call stack as the "primary" thread (MetricKit
        // groups by stack signature; the first entry is the
        // most-representative).
        guard let data = try? jsonFromTree(tree),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stacks = json["callStacks"] as? [[String: Any]],
              let first = stacks.first,
              let frames = first["callStackRootFrames"] as? [[String: Any]] else {
            return "MXHangDiagnostic (no parsable stack)"
        }
        var lines: [String] = []
        lines.append("MetricKit MXHangDiagnostic main-thread stack:")
        appendFrames(frames, lines: &lines, indent: 0)
        let joined = lines.joined(separator: "\n")
        return String(joined.prefix(8_000))
    }

    /// MXCallStackTree → JSON Data. Swift's auto-bridging on
    /// MXCallStackTree gives us `jsonRepresentation()` directly
    /// since iOS 14; wrap so we can swap to a more efficient
    /// path on future iOS releases.
    private func jsonFromTree(_ tree: MXCallStackTree) throws -> Data {
        return tree.jsonRepresentation()
    }

    /// Pretty-print MXCallStackTree's nested frame tree.
    /// MetricKit's binary-symbol field is the address; we render it
    /// as a hex pointer matching the format the Android NDK signal
    /// handler ships, so the dashboard's stack viewer parses both
    /// platforms identically.
    private func appendFrames(
        _ frames: [[String: Any]],
        lines: inout [String],
        indent: Int
    ) {
        let prefix = String(repeating: "  ", count: indent + 1)
        for frame in frames {
            let binary = frame["binaryName"] as? String ?? "?"
            let offset = frame["offsetIntoBinaryTextSegment"] as? UInt64 ?? 0
            let address = frame["address"] as? UInt64 ?? 0
            // Format mirrors PLCrashReporter / Crashlytics output:
            //   "  at <binary> 0x<address> + <offset>"
            lines.append(String(format: "%@at %@ 0x%016llx + %llu", prefix, binary, address, offset))
            if let children = frame["subFrames"] as? [[String: Any]], !children.isEmpty {
                appendFrames(children, lines: &lines, indent: indent + 1)
            }
        }
    }
}

#endif
