import Foundation
import Darwin

/// Catches both Obj-C exceptions and Unix signals (SIGSEGV / SIGABRT /
/// etc.), persists a minimal crash record to disk, and surfaces it
/// as a `crash` event on the NEXT app launch.
///
/// Why next-launch rather than this-launch: a crashing process can't
/// reliably do anything async like an HTTP POST. We write the bare
/// minimum to disk SAFELY from inside the signal/exception handler,
/// then the next process startup reads it + ships normally through
/// the batch pipeline.
///
/// Signal handler constraints (per Apple's "Async-Signal-Safe
/// Functions" doc):
///   • Cannot allocate (no Swift runtime, no Foundation containers)
///   • Cannot call non-async-signal-safe APIs (printf, malloc, …)
///   • Can call: write(), _exit(), open() with O_NONBLOCK, sigaction()
///
/// We write a fixed-size ASCII record via raw write() to a pre-opened
/// file descriptor. The Swift handler runs OUTSIDE the signal path
/// (next launch) and does all the rich formatting.
///
/// We chain previous handlers so Crashlytics / Sentry / customer
/// handlers still fire — never own the handler exclusively.
final class CrashHandler {

    /// Called on next-launch with the recovered crash record. Wires
    /// up to ReplayCore which emits as an `error` event.
    private let onRecoveredCrash: (CrashRecord) -> Void

    init(onRecoveredCrash: @escaping (CrashRecord) -> Void) {
        self.onRecoveredCrash = onRecoveredCrash
    }

    /// Install handlers. Idempotent. Reads + emits any previous crash
    /// record from disk before installing new ones — guarantees a
    /// crash that happens between drainPrevious and install is still
    /// captured by the chained handler (if any).
    func install() {
        drainPrevious()
        installNSExceptionHandler()
        installSignalHandlers()
    }

    /// Drain any crash record left over from a previous process
    /// crash and forward it to ReplayCore.
    private func drainPrevious() {
        guard let url = Self.recordUrl() else { return }
        guard let data = try? Data(contentsOf: url) else { return }
        defer { try? FileManager.default.removeItem(at: url) }

        // The record is a single ASCII line:
        //   "v1|<kind>|<signal-or-name>|<unix-ts>"
        // Parse defensively — malformed records get dropped.
        guard let line = String(data: data, encoding: .utf8) else { return }
        let parts = line.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[0] == "v1" else { return }
        let kind = String(parts[1])
        let signalOrName = String(parts[2])
        let ts = Int64(parts[3]) ?? SessionRuntime.nowMs()

        let record = CrashRecord(
            kind: kind,
            detail: signalOrName,
            timestamp: ts
        )
        onRecoveredCrash(record)
    }

    // MARK: - NSException handler (catches Obj-C exceptions)

    private func installNSExceptionHandler() {
        // Chain the previous handler so Crashlytics + customer
        // handlers still fire. NSGetUncaughtExceptionHandler is the
        // mate to NSSet — same paired API for all platform-installed
        // handlers (signal, atexit, etc.).
        let previous = NSGetUncaughtExceptionHandler()
        Self.previousExceptionHandler = previous

        NSSetUncaughtExceptionHandler { exception in
            // Swift in an @convention(c) closure can call Swift stuff
            // freely (we're not in a signal handler) — the
            // Obj-C runtime walks the stack, picks our closure,
            // and calls it on the failing thread BEFORE the
            // process dies.
            let detail = "\(exception.name.rawValue):\(exception.reason ?? "")"
                .prefix(200)
                .replacingOccurrences(of: "|", with: "/")  // delimiter safety
                .replacingOccurrences(of: "\n", with: " ")
            CrashHandler.writeRecord(kind: "nsexception", detail: String(detail))
            // Chain.
            CrashHandler.previousExceptionHandler?(exception)
        }
    }

    // MARK: - Signal handlers (SIGSEGV/SIGABRT/SIGBUS/SIGFPE/SIGILL)

    private static let watchedSignals: [Int32] = [
        SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP,
    ]

    /// One slot per signal for the previous action — we chain to it
    /// after writing our record so customer handlers + Crashlytics
    /// still see the crash.
    private static var previousActions: [Int32: sigaction] = [:]

    private func installSignalHandlers() {
        for sig in Self.watchedSignals {
            var action = sigaction()
            // SA_SIGINFO so we get the rich siginfo_t — but we only
            // log the signal number to stay async-signal-safe.
            action.__sigaction_u.__sa_sigaction = { sig, _, _ in
                CrashHandler.handleSignalAsyncSafe(sig)
                // Chain to previous handler (if any) so other crash
                // reporters still see it. Then re-raise to let the
                // OS produce its normal crash report + terminate.
                if let prev = CrashHandler.previousActions[sig] {
                    // Comparing function pointers in Swift requires
                    // a bitcast to raw pointer (C function types
                    // aren't Equatable). SIG_DFL / SIG_IGN are
                    // sentinel values defined as integer constants
                    // — checking against them filters out the "no
                    // previous handler" + "previously ignored" cases
                    // before we invoke.
                    let handlerPtr = unsafeBitCast(
                        prev.__sigaction_u.__sa_handler,
                        to: UnsafeRawPointer?.self
                    )
                    let dflPtr = unsafeBitCast(SIG_DFL, to: UnsafeRawPointer?.self)
                    let ignPtr = unsafeBitCast(SIG_IGN, to: UnsafeRawPointer?.self)
                    if (prev.sa_flags & SA_SIGINFO) != 0 {
                        // Previous installer used sa_sigaction —
                        // the 3-arg form. Chain with nil info/uap;
                        // most chained handlers (Crashlytics) cope.
                        if let action = prev.__sigaction_u.__sa_sigaction {
                            action(sig, nil, nil)
                        }
                    } else if handlerPtr != nil && handlerPtr != dflPtr && handlerPtr != ignPtr {
                        if let action = prev.__sigaction_u.__sa_handler {
                            action(sig)
                        }
                    }
                }
                // Reset to default + re-raise so the OS produces
                // its normal crash report. _exit instead of raise
                // would suppress the OS report, which would break
                // App Store crash analytics.
                signal(sig, SIG_DFL)
                raise(sig)
            }
            action.sa_flags = SA_SIGINFO
            sigemptyset(&action.sa_mask)

            var previous = sigaction()
            sigaction(sig, &action, &previous)
            Self.previousActions[sig] = previous
        }
    }

    /// Signal-safe write — no allocations, no Swift runtime, no
    /// Foundation. We open the record path once at install time and
    /// stash the fd so the signal handler doesn't have to call
    /// open() (which IS async-signal-safe but slower).
    ///
    /// Format: fixed-prefix ASCII bytes written directly via write(2).
    private static func handleSignalAsyncSafe(_ sig: Int32) {
        // Pre-formatted lookup so we don't have to call snprintf —
        // most signals fit in one literal.
        let name: StaticString = {
            switch sig {
            case SIGSEGV: return "SIGSEGV"
            case SIGABRT: return "SIGABRT"
            case SIGBUS:  return "SIGBUS"
            case SIGFPE:  return "SIGFPE"
            case SIGILL:  return "SIGILL"
            case SIGTRAP: return "SIGTRAP"
            default:      return "SIGUNKNOWN"
            }
        }()
        // Best-effort write via open() + write() + close() —
        // open() with O_WRONLY|O_CREAT|O_TRUNC is async-signal-safe.
        // Build the path lazily on each invocation; signal handlers
        // are rare enough that the per-byte cost doesn't matter.
        guard let pathCString = recordPathCString() else { return }
        let fd = open(pathCString, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return }
        let prefix: StaticString = "v1|signal|"
        prefix.withUTF8Buffer { buf in
            _ = write(fd, buf.baseAddress, buf.count)
        }
        name.withUTF8Buffer { buf in
            _ = write(fd, buf.baseAddress, buf.count)
        }
        _ = write(fd, "|0", 2) // timestamp placeholder — Swift-side
                              // recovery uses file mtime instead.
        close(fd)
    }

    /// Path to the crash record file as a null-terminated C string,
    /// owned by a static buffer so the signal handler can read it
    /// without allocating. nil on first call from a process that
    /// never installed (defensive).
    private static var pathBuffer: [CChar]?
    private static func recordPathCString() -> UnsafePointer<CChar>? {
        if pathBuffer == nil, let url = recordUrl() {
            pathBuffer = url.path.cString(using: .utf8) ?? []
        }
        return pathBuffer?.withUnsafeBufferPointer { $0.baseAddress }
    }

    // MARK: - Record path + Swift-side serialization

    /// File where we persist crash records between launches.
    /// Application Support is the right home — survives backups +
    /// uninstall, never iCloud-synced. Returns nil if we can't
    /// resolve the directory (very rare on iOS).
    private static func recordUrl() -> URL? {
        let fm = FileManager.default
        guard let support = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let dir = support.appendingPathComponent("replay", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("last-crash.txt")
    }

    /// Swift-side record writer for NSException — NOT signal-safe,
    /// but doesn't need to be (NSException handler runs in normal
    /// Swift context).
    private static func writeRecord(kind: String, detail: String) {
        guard let url = recordUrl() else { return }
        let ts = SessionRuntime.nowMs()
        let line = "v1|\(kind)|\(detail)|\(ts)"
        try? line.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    /// Held statically so the C-style handler closure can chain
    /// without capturing self.
    private static var previousExceptionHandler: (@convention(c) (NSException) -> Void)?
}

/// A crash record recovered on next launch — passed to ReplayCore
/// for emission as an `error` event with `kind:"crash"`.
struct CrashRecord {
    /// "signal" or "nsexception"
    let kind: String
    /// Signal name ("SIGSEGV") or NSException name + reason.
    let detail: String
    /// Wall-clock ms at crash time. May be 0 for signal records
    /// (signal handler couldn't format a timestamp safely); in that
    /// case the recovered timestamp is "next launch", which is
    /// good enough for the dashboard's "session ended in crash"
    /// view.
    let timestamp: Int64
}
