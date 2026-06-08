import Foundation
#if canImport(CrashReporter)
import CrashReporter
#endif

/// Crash capture for iOS — replaces the previous hand-rolled
/// NSException + sigaction handler with PLCrashReporter (Microsoft's
/// fork of the original Plausible Labs library).
///
/// What PLCrashReporter buys over the hand-rolled approach:
///
///   1. **Mach exception server** — catches `EXC_BAD_ACCESS`,
///      `EXC_BAD_INSTRUCTION`, `EXC_CRASH` BEFORE they're translated
///      to BSD signals. Catches crashes that sigaction misses
///      (e.g. zombie object access on ARM64).
///
///   2. **Async-signal-safe crash dump** — uses pre-allocated
///      buffers + non-locking I/O so the in-process handler can't
///      crash inside itself. Our previous code was best-effort
///      safe but a sigaction handler doing `_ = write(fd, …)` from
///      Swift is borderline (the Swift runtime isn't formally
///      async-signal-safe even though it usually works).
///
///   3. **Stack trace + symbol info** — captures every thread's
///      register state at crash time, walks the stack, formats a
///      report we can ship to the dashboard.
///
///   4. **Battle-tested** — the reference mobile SDK, HockeyApp, AppCenter,
///      Microsoft's own crash reporter all ship this. Edge cases
///      across iOS versions, swift runtime, ARM64e are handled.
///
/// Same disk-write + next-launch-emit pattern as before. The Mach
/// server runs in-process but writes the report synchronously to
/// disk before letting the OS produce its normal crash dialog.
/// Next launch: we ask PLCrashReporter for any pending report, ship
/// it as a `kind:"crash"` error event, and purge.
///
/// Falls back to a no-op when CrashReporter isn't linked (e.g.
/// `swift build` on macOS without the package resolved). The
/// fallback path still drains legacy v1 records from the previous
/// hand-rolled handler so customers upgrading don't lose their
/// pending crash on first launch with the new SDK.
final class CrashHandler {

    /// Called on next-launch with the recovered crash record. Wires
    /// up to LegacyCore which emits as an `error` event.
    private let onRecoveredCrash: (CrashRecord) -> Void

    init(onRecoveredCrash: @escaping (CrashRecord) -> Void) {
        self.onRecoveredCrash = onRecoveredCrash
    }

    /// Install. Idempotent — repeated calls within the same process
    /// are no-ops because PLCrashReporter.enable() is itself
    /// idempotent.
    func install() {
        drainLegacyRecord()
        #if canImport(CrashReporter)
        installPLCrashReporter()
        #endif
    }

    // MARK: - PLCrashReporter path

    #if canImport(CrashReporter)

    /// Singleton reporter — installed once per process. PLCrashReporter
    /// itself is also a singleton internally; keeping our reference
    /// avoids garbage-collecting it.
    private static var reporter: PLCrashReporter?

    private func installPLCrashReporter() {
        // Drain ANY pending report BEFORE enabling. If we crashed last
        // launch, PLCrashReporter wrote the report; ship it as a
        // crash event on this launch's session.
        let config = PLCrashReporterConfig(
            // .mach is the strongest mode — catches EXC_BAD_ACCESS
            // via the Mach exception server BEFORE the signal
            // translation, which the BSD-signal-only mode would
            // miss in some corner cases (e.g. failed message sends
            // on dead objects).
            //
            // Apple's review guidelines USED to disallow Mach
            // exception handlers in App Store apps. That changed
            // years ago; Sentry, Crashlytics, AppCenter all ship
            // .mach now. We follow suit.
            signalHandlerType: .mach,
            symbolicationStrategy: .all
        )
        guard let reporter = PLCrashReporter(configuration: config) else {
            ReplayLog.warn("PLCrashReporter init failed — crash capture disabled this launch")
            return
        }

        if reporter.hasPendingCrashReport() {
            do {
                let data = try reporter.loadPendingCrashReportDataAndReturnError()
                if let report = try? PLCrashReport(data: data) {
                    let formatted = PLCrashReportTextFormatter.stringValue(
                        for: report,
                        with: PLCrashReportTextFormatiOS
                    )
                    let oneLineSummary = summarize(report: report)
                    onRecoveredCrash(CrashRecord(
                        kind: "crash",
                        detail: oneLineSummary,
                        stack: formatted,
                        timestamp: Int64(report.systemInfo.timestamp.timeIntervalSince1970 * 1_000)
                    ))
                }
            } catch {
                ReplayLog.warn("PLCrashReporter loadPending failed: \(error)")
            }
            // Purge so we don't re-ship the same crash on every
            // subsequent launch.
            try? reporter.purgePendingCrashReportAndReturnError()
        }

        // Now enable for THIS session. Any crash from this point
        // forward will be recorded + drained on the NEXT launch.
        do {
            try reporter.enableAndReturnError()
            Self.reporter = reporter
        } catch {
            ReplayLog.warn("PLCrashReporter enable failed: \(error)")
        }
    }

    /// One-line dashboard summary from the PLCrashReport. Includes
    /// the signal/exception name + the deepest non-system frame's
    /// symbol so the dashboard's recordings list can show a useful
    /// label without expanding the full stack.
    private func summarize(report: PLCrashReport) -> String {
        // Signal info — fast path. `report.signalInfo` carries the
        // BSD signal name even when caught via Mach exceptions
        // (PLCrashReporter translates internally).
        let signalName = report.signalInfo.name ?? "unknown"
        let exceptionName = report.exceptionInfo?.exceptionName ?? ""
        let reason = report.exceptionInfo?.exceptionReason ?? ""

        if !exceptionName.isEmpty {
            // Obj-C-style exception (NSException etc.) — show the
            // class name + reason. Truncate reason to keep summary
            // dashboard-row-friendly.
            let trimmedReason = String(reason.prefix(160))
            return "\(exceptionName): \(trimmedReason)"
        }
        return signalName
    }

    #endif // canImport(CrashReporter)

    // MARK: - Legacy v1 record drain (pre-PLCrashReporter)

    /// One-shot migration helper: if the previous SDK version's
    /// hand-rolled handler left a `last-crash.txt` v1 record on disk,
    /// ship it on this launch before the v2 path takes over. After
    /// the first run on the new SDK this file never reappears.
    private func drainLegacyRecord() {
        guard let url = Self.legacyRecordUrl() else { return }
        guard let data = try? Data(contentsOf: url) else { return }
        defer { try? FileManager.default.removeItem(at: url) }

        guard let line = String(data: data, encoding: .utf8) else { return }
        let parts = line.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[0] == "v1" else { return }
        let kind = String(parts[1])
        let signalOrName = String(parts[2])
        let ts = Int64(parts[3]) ?? SessionRuntime.nowMs()

        onRecoveredCrash(CrashRecord(
            kind: kind,
            detail: signalOrName,
            stack: nil,
            timestamp: ts
        ))
    }

    /// Legacy path — kept ONLY for the one-shot v1→v2 migration drain
    /// above. PLCrashReporter manages its own report dir under
    /// `~/Library/Caches/<bundle-id>/com.plausiblelabs.crashreporter.data`.
    private static func legacyRecordUrl() -> URL? {
        let fm = FileManager.default
        guard let support = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return nil }
        return support
            .appendingPathComponent("replay", isDirectory: true)
            .appendingPathComponent("last-crash.txt")
    }
}

/// A crash record recovered on next launch — passed to LegacyCore
/// for emission as an `error` event with `kind:"crash"`.
struct CrashRecord {
    /// "crash" (PLCrashReporter) or legacy "signal" / "nsexception".
    let kind: String
    /// One-line summary suitable for the dashboard row label —
    /// signal name OR `<ExceptionName>: <reason>`.
    let detail: String
    /// Full formatted stack trace from PLCrashReporter (multi-line,
    /// human-readable, includes thread states). nil for legacy
    /// records that predate PLCrashReporter integration.
    let stack: String?
    /// Wall-clock ms at crash time.
    let timestamp: Int64
}
