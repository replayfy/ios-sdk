import Foundation

/// Detects main-thread hangs — periods where the iOS run loop is
/// blocked long enough that the user perceives the app as frozen.
/// Direct counterpart of the Android SDK's `AnrWatchdog`; same
/// emit shape so the dashboard treats both platforms uniformly.
///
/// Mechanism — heartbeat from a dedicated watchdog `Thread`:
///   1. Background `Thread` posts a sentinel `Runnable` to the
///      main `DispatchQueue` every ``pingIntervalMs``.
///   2. The sentinel, when it runs on main, stamps
///      ``lastMainRespondedAtMs``. If main is blocked, the sentinel
///      sits in the queue — ``lastMainRespondedAtMs`` grows stale.
///   3. After posting, the watchdog sleeps. On wake it checks
///      `now − lastMainRespondedAtMs`. If that exceeds
///      ``hangThresholdMs`` (default 5s — matches Apple's own input-
///      delivery hang threshold from MetricKit's hang-rate metric)
///      it emits an `anr_ms` perf event with the duration.
///   4. Debounce: a single hang doesn't fire repeatedly. We only
///      emit again after main has responded at least once (so an 8s
///      freeze fires one event, not two).
///
/// Why a dedicated `Thread` rather than a `DispatchQueue` polling
/// timer: the watchdog must be UNKILLABLE by main-thread pressure.
/// Foundation `Timer`/GCD timers on a non-main queue can be starved
/// or delayed under specific conditions. A real `Thread` with
/// `Thread.sleep` is the most boring + most reliable way to get a
/// truly independent heartbeat.
///
/// MetricKit MXHangDiagnostic is the official Apple API for the same
/// problem, but its reports arrive ASYNCHRONOUSLY up to 24 h after
/// the hang occurred — useless for live session replay where we
/// want the hang attached to the session it happened in. We mirror
/// the Android approach for parity + real-time delivery.
///
/// Stack capture: Foundation's `Thread.callStackSymbols` returns the
/// CALLING thread's stack, not arbitrary-thread state. Reading the
/// main thread's stack from a background thread requires
/// `mach_msg_trap` + `thread_get_state` — low-level, unsafe, and
/// brittle across iOS versions. For v1 we ship duration only;
/// dashboard surfaces an "ANR/Hang" event the customer can correlate
/// to their session timeline. Stack capture is a follow-up enrichment
/// (same gap Android currently has).
final class HangWatchdog {

    /// Matches Apple's own framework hang threshold (`hangsRate` in
    /// MetricKit's MXAppRunTimeMetric is computed against ~250 ms
    /// "micro-hangs"; the user-perception "frozen app" threshold the
    /// OS uses for input ANR is 5 s, same as Android).
    static let defaultHangThresholdMs: Int64 = 5_000

    /// Frequent enough that ``lastMainRespondedAtMs`` stays fresh,
    /// infrequent enough that the watchdog doesn't crowd the main
    /// run loop.
    static let defaultPingIntervalMs: Int64 = 1_000

    private let hangThresholdMs: Int64
    private let pingIntervalMs: Int64
    private let emit: (_ frozenMs: Int64) -> Void

    private let stateLock = NSLock()
    private var running: Bool = false
    private var watcher: Thread?

    /// Stamped each time the sentinel runs on the main queue. Read
    /// under ``stateLock`` from the watchdog thread.
    private var lastMainRespondedAtMs: Int64 = HangWatchdog.nowMs()

    /// True between flagging a hang and main responding again — used
    /// to debounce so a single freeze fires one event, not many.
    private var hangInProgress: Bool = false

    init(
        hangThresholdMs: Int64 = HangWatchdog.defaultHangThresholdMs,
        pingIntervalMs: Int64 = HangWatchdog.defaultPingIntervalMs,
        emit: @escaping (_ frozenMs: Int64) -> Void
    ) {
        self.hangThresholdMs = hangThresholdMs
        self.pingIntervalMs = pingIntervalMs
        self.emit = emit
    }

    func start() {
        stateLock.lock()
        if running { stateLock.unlock(); return }
        running = true
        // Prime the timestamp so a freeze immediately after start
        // doesn't get reported as a hang of "uptime so far".
        lastMainRespondedAtMs = HangWatchdog.nowMs()
        hangInProgress = false
        stateLock.unlock()

        let thread = Thread { [weak self] in self?.loop() }
        thread.name = "ReplayHangWatchdog"
        // Below default so we never starve host-app threads but
        // still wake up reliably when our sleep elapses.
        thread.qualityOfService = .utility
        watcher = thread
        thread.start()
    }

    func stop() {
        stateLock.lock()
        running = false
        stateLock.unlock()
        watcher?.cancel()
        watcher = nil
    }

    private func loop() {
        while shouldRun() {
            postSentinel()
            // `Thread.sleep` is the simplest correct primitive here —
            // unaffected by GCD pressure, unaffected by main-thread
            // pressure.
            Thread.sleep(forTimeInterval: Double(pingIntervalMs) / 1_000.0)

            stateLock.lock()
            let sinceLastMs = HangWatchdog.nowMs() - lastMainRespondedAtMs
            let alreadyFlagged = hangInProgress
            stateLock.unlock()

            if sinceLastMs >= hangThresholdMs && !alreadyFlagged {
                stateLock.lock()
                hangInProgress = true
                stateLock.unlock()
                // `emit` MUST NOT crash the watchdog — wrap.
                do {
                    emit(sinceLastMs)
                }
            }
        }
    }

    private func shouldRun() -> Bool {
        if Thread.current.isCancelled { return false }
        stateLock.lock()
        let r = running
        stateLock.unlock()
        return r
    }

    private func postSentinel() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            self.lastMainRespondedAtMs = HangWatchdog.nowMs()
            self.hangInProgress = false
            self.stateLock.unlock()
        }
    }

    /// Monotonic-ish millis since reference. We don't need true
    /// monotonicity (NTP nudges of a few ms don't affect the 5s
    /// threshold meaningfully); using Date keeps the code stdlib-
    /// only and avoids the platform-specific dance of
    /// `mach_absolute_time` + `mach_timebase_info`.
    static func nowMs() -> Int64 {
        return Int64(Date().timeIntervalSince1970 * 1_000.0)
    }
}
