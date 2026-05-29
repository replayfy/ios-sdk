import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Internal orchestrator. The public ``Replay`` enum delegates here;
/// every state mutation lives in this singleton.
///
/// Owns:
///   - the active ``SessionRuntime`` (rotates on background→foreground)
///   - the ``BatchSender`` (one per process)
///   - the periodic flush ``Task``
///   - the ``LifecycleObserver`` registration
///
/// iOS bootstrap is single-phase: the host app calls
/// ``Replay/start(with:)`` from `didFinishLaunching`, and that's the
/// first opportunity we have to do anything (iOS has no
/// ContentProvider equivalent — UIApplication's load order doesn't
/// guarantee SDK initialization before user code, so we don't try).
///
/// All state is gated by a serial DispatchQueue rather than an actor
/// because the public API is sync from any thread — making methods
/// `await`-able would force every call site to bridge through Task,
/// which would surprise existing Obj-C codebases.
final class ReplayCore {

    static let shared = ReplayCore()

    private let queue = DispatchQueue(label: "com.replayfy.ios.core", qos: .userInitiated)

    private var initialized = false
    private var config: ReplayConfig?
    private var runtime: SessionRuntime?
    private var sender: BatchSender?
    private var uploader: BatchUploader?
    private var lifecycle: LifecycleObserver?
    private var flushTask: Task<Void, Never>?
    private var tapTracker: TapTracker?
    private var snapshotCapture: SnapshotCapture?
    private var perfMetrics: PerfMetricsManager?
    private var crashHandler: CrashHandler?
    private var consoleCapture: ConsoleCapture?

    /// Events captured before the first foreground (== before
    /// `runtime` exists). iOS has no equivalent of Android's
    /// ContentProvider auto-bootstrap that runs before
    /// `Application.onCreate`, so the gap between `Replay.start`
    /// and the first `UIApplication.didBecomeActiveNotification`
    /// can swallow any event call made from `viewDidLoad` / `init`
    /// OR from collector boot-time emits (ThermalMonitor.start
    /// immediately emits the baseline thermal_state; BatteryMonitor
    /// the baseline battery state; both fire from inside
    /// `perfMetrics.start()` which runs DURING Replay.start before
    /// onAppForegrounded creates the runtime).
    ///
    /// These buffers preserve them; flushed in `startNewSessionLocked`
    /// once the runtime materialises. 200-event cap each to prevent
    /// runaway accumulation if foreground never fires.
    private var pendingTracks: [CustomEventData] = []
    private var pendingConsole: [ConsoleEventData] = []
    private var pendingPerf: [PerformanceEventData] = []

    /// Mirrors the Android SDK's `init` — sets up sender, lifecycle
    /// observer, periodic flush, fires session_start.
    func start(config: ReplayConfig) {
        queue.sync {
            guard !initialized else {
                ReplayLog.warn("Replay.start called twice — ignoring second call")
                return
            }
            initialized = true
            self.config = config
            let sender = BatchSender(config: config)
            self.sender = sender
            // Wrap with the persistent-queue uploader. flushNow goes
            // through this so failed batches land on disk and get
            // drained on next foreground.
            self.uploader = BatchUploader(config: config, sender: sender)
            // One-shot drain attempt to pick up any batches queued
            // during a previous process lifetime. Fire-and-forget;
            // don't block start.
            let initialUploader = self.uploader
            Task.detached(priority: .utility) {
                await initialUploader?.drain()
            }

            if let distinctId = config.distinctId {
                sender.identity = IdentifyPayload(
                    distinctId: distinctId,
                    email: nil, name: nil, plan: nil, customProps: nil
                )
            }

            let observer = LifecycleObserver(
                onForeground: { [weak self] in self?.onAppForegrounded() },
                onBackground: { [weak self] in self?.onAppBackgrounded() }
            )
            self.lifecycle = observer
            observer.attach()

            // Tap tracker — injects a UIGestureRecognizer on every
            // window. Captures across modals/alerts/popovers without
            // interfering with the host app's own gestures.
            let tracker = TapTracker { [weak self] tap in
                self?.emitTap(tap)
            }
            tracker.attach()
            self.tapTracker = tracker

            // Snapshot pipeline. Bitmap capture + asset upload are
            // wired now that we have an apiKey / apiHost. captureBitmaps
            // defaults to config.captureSnapshotPixels (true unless
            // disabled by customer or future remote config).
            let snapshot = SnapshotCapture { [weak self] snap in
                self?.emitSnapshot(snap)
            }
            snapshot.assetUploader = AssetUploader(config: config)
            snapshot.thumbnailUploader = ThumbnailUploader(config: config)
            snapshot.captureBitmaps = config.captureSnapshotPixels
            // Provide current sessionId at snapshot time — ensures
            // the thumbnail upload targets the live session even
            // after background→foreground rotations.
            snapshot.sessionIdProvider = { [weak self] in
                self?.queue.sync { self?.runtime?.sessionId }
            }
            self.snapshotCapture = snapshot

            // Native perf metrics — cold_start_ms, frame_drop_pct,
            // frozen_frame_count, memory_rss_mb, thermal_state.
            // Cold start is reported separately from onAppForegrounded
            // so we capture the cold-launch → user-sees-app delay,
            // not just process spin-up.
            let perf = PerfMetricsManager { [weak self] event in
                self?.emitPerformance(event)
            }
            perf.start()
            self.perfMetrics = perf

            // Crash handler — install last so previous-launch crash
            // records get drained AFTER the runtime is up but
            // BEFORE the periodic flush task starts (so the
            // recovered crash event lands in the first batch).
            // Only install when the customer hasn't opted out via
            // config.captureErrors.
            if config.captureErrors {
                let crash = CrashHandler { [weak self] record in
                    self?.emitRecoveredCrash(record)
                }
                crash.install()
                self.crashHandler = crash
            }

            // Console capture — STDOUT + STDERR pipe via dup2.
            // `print()` / `NSLog()` lines ship as console events.
            // Customers using `Logger` / `os_log` bridge via
            // `Replay.log(level:message:stack:)` explicitly.
            if config.captureConsole {
                let console = ConsoleCapture { [weak self] event in
                    self?.emitConsole(event)
                }
                console.start()
                self.consoleCapture = console
            }

            // Auto-detect screen names — UIViewController.viewDidAppear
            // swizzle reports the foremost VC's class name as the
            // current route. Mirrors Android's
            // TapTracker.updateRoute(activity.javaClass.simpleName).
            // Customers opt out with ReplayConfig(autoScreenName:false)
            // + drive routes manually via Replay.tagScreenName.
            //
            // Must run on the main thread (UIKit class swizzle).
            // Since Replay.start typically runs from
            // application(_:didFinishLaunchingWithOptions:) which IS
            // main, this is safe.
            if config.autoScreenName {
                ScreenAutoDetector.onScreenChange = { [weak self] name in
                    self?.setRoute(name)
                }
                ScreenAutoDetector.enable()
            }

            // Network capture via URLProtocol — auto-installs on
            // URLSession.shared + deprecated NSURLConnection. Off
            // by default (PII risk); flip ReplayConfig(captureNetwork:
            // true) to enable. Customer URLSession configs with
            // custom protocolClasses bypass us; documented limitation.
            if config.captureNetwork {
                URLSessionCapture.emit = { [weak self] event in
                    self?.emitNetwork(event)
                }
                URLSessionCapture.captureHeaders = config.captureHeaders
                URLSessionCapture.maxBodyBytes = config.maxBodyBytes
                // Redact patterns: ReplayConfig currently doesn't
                // expose a list (web SDK has redactUrls; iOS will
                // add an equivalent in a follow-up). Empty for now.
                URLSessionCapture.redactPatterns = []
                URLSessionCapture.install()
            }

            // Periodic flush. Cancelled on stop(). Runs detached so
            // it doesn't pin a Task tree to the caller.
            let interval = config.flushInterval
            flushTask = Task.detached(priority: .background) { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    await self?.flushNow()
                }
            }

            ReplayLog.info("Replay.start complete")
        }
    }

    // MARK: - Identity + tracks

    func identify(distinctId: String, properties: [String: Any]?) {
        queue.sync {
            guard let sender else {
                ReplayLog.warn("identify before start — dropping")
                return
            }
            sender.identity = IdentifyPayload(
                distinctId: distinctId,
                email: nil,
                name: nil,
                plan: nil,
                customProps: safeProps(properties)
            )
        }
        // Force-flush so the identity attaches as soon as possible.
        Task.detached(priority: .utility) { [weak self] in
            await self?.flushNow()
        }
    }

    func track(name: String, properties: [String: Any]?) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let safeName = String(trimmed.prefix(80))

        queue.sync {
            let data = CustomEventData(
                kind: "track",
                name: safeName,
                properties: safeProps(properties)
            )
            if let rt = runtime {
                pushLocked(rt: rt, type: "custom", data: data)
            } else {
                // Pre-runtime — buffer for replay on first session
                // start. Customer-side calls in `viewDidLoad`/`init`
                // fire BEFORE the app's first didBecomeActive
                // notification creates the runtime; without this
                // buffer those events would be silently dropped.
                pendingTracks.append(data)
            }
        }
    }

    // MARK: - Lifecycle

    private func onAppForegrounded() {
        queue.sync {
            guard config != nil else { return }
            guard runtime == nil else { return }
            startNewSessionLocked()
        }
        // Cold-start measurement — emit once per process. The
        // measurement runs ReplayCore.init → first foreground,
        // which approximates didFinishLaunching → first frame
        // visible to the user. Idempotent (returns nil after the
        // first call), so duplicate foregrounds don't re-emit.
        perfMetrics?.reportFirstForeground()
        // Foregrounding is the right moment to drain anything left
        // on disk from a previous session (live failure during the
        // last background, or a process kill). Fire-and-forget;
        // doesn't block the new session's startup.
        let uploaderSnap = queue.sync { self.uploader }
        Task.detached(priority: .utility) {
            await uploaderSnap?.drain()
        }
        // Fire a snapshot on foreground transition — mirrors the
        // Android SDK's `screen_appeared` trigger. Gives the
        // dashboard at least one snapshot per session even when the
        // customer never calls tagScreenName and the session ends
        // without any taps. ALSO drives the thumbnail-retry path:
        // if the first snapshot's thumbnail upload raced ahead of
        // the session row's creation, the second snapshot will
        // catch up.
        snapshotCapture?.captureNow(trigger: "screen_appeared")
    }

    private func onAppBackgrounded() {
        let runtimeToFlush: SessionRuntime? = queue.sync {
            guard let rt = runtime else { return nil }
            let data = SessionEndEventData(reason: "background")
            pushLocked(rt: rt, type: "session_end", data: data)
            return rt
        }
        if runtimeToFlush != nil {
            Task.detached(priority: .utility) { [weak self] in
                await self?.flushNow()
            }
        }
    }

    func stop() {
        let willFlush: Bool = queue.sync {
            guard let rt = runtime else { return false }
            pushLocked(rt: rt, type: "session_end", data: SessionEndEventData(reason: "manual"))
            return true
        }
        if willFlush {
            Task.detached(priority: .utility) { [weak self] in
                await self?.flushNow()
            }
        }
        queue.sync {
            flushTask?.cancel()
            flushTask = nil
            runtime = nil
        }
        // Stop background perf collectors — frame-link callback,
        // memory timer, thermal notification observer. Restarts on
        // next start() call.
        perfMetrics?.stop()
        perfMetrics = nil
        // Restore original STDOUT / STDERR. Best-effort — dup2
        // failures during shutdown are logged + ignored by
        // ConsoleCapture.stop().
        consoleCapture?.stop()
        consoleCapture = nil
        // Network capture cleanup — clear the emit closure so any
        // in-flight requests' completion handlers don't push events
        // into the stopped runtime. Unregister the protocol too;
        // re-registration is cheap if start() is called again.
        URLSessionCapture.emit = nil
        URLSessionCapture.uninstall()
    }

    /// Bridge for the public `Replay.log(...)` entry point.
    /// Forwards to `ConsoleCapture.emitExplicit` so customer-side
    /// loggers that don't write through STDOUT/STDERR (`Logger`,
    /// `os_log`, CocoaLumberjack, etc.) can still feed the dashboard.
    func logExplicit(level: String, message: String, stack: String?) {
        consoleCapture?.emitExplicit(level: level, message: message, stack: stack)
    }

    var isRecording: Bool {
        queue.sync { runtime != nil }
    }

    // MARK: - Stubs (engine in follow-up commits)

    func stub(_ call: String) {
        ReplayLog.verbose("stub: \(call) (engine not yet wired)")
    }

    // MARK: - Tap + snapshot relay

    private func emitTap(_ tap: TapEventData) {
        queue.sync {
            guard let rt = runtime else { return }
            pushLocked(rt: rt, type: "tap", data: tap)
        }
        // Tap → schedule an idle snapshot 500ms later to catch
        // any post-interaction state change (modal opens, list
        // scrolls). Coalesced via SnapshotCapture's generation
        // counter so rapid-fire taps collapse to ONE snapshot.
        snapshotCapture?.scheduleIdle()
    }

    /// Surface a previous-launch crash as an `error` event on the
    /// current session. We use the standard error type so the
    /// backend's existing errorCount + dashboard error filtering
    /// just works — `kind:"crash"` discriminates from regular
    /// errors when the customer wants to filter to crashes only.
    private func emitRecoveredCrash(_ record: CrashRecord) {
        // Stack from PLCrashReporter is multi-line formatted text
        // (thread states + register dumps + symbolicated frames).
        // Ship it raw — backend stores as TEXT and the dashboard's
        // Crashes panel renders it inside a <pre>. Legacy records
        // from the previous SDK lifecycle carry stack=nil.
        let data = CrashEventData(
            kind: "crash",
            message: record.detail,
            stack: record.stack
        )
        // `async` for the same reason as emitPerformance: this is
        // called inline from CrashHandler.install (during start) which
        // may already be on the core queue. Avoid the re-entrant
        // dispatch-deadlock.
        queue.async {
            guard let rt = self.runtime else { return }
            self.pushLocked(rt: rt, type: "error", data: data)
        }
    }

    private func emitNetwork(_ event: NetworkEventData) {
        queue.async {
            guard let rt = self.runtime else { return }
            self.pushLocked(rt: rt, type: "network", data: event)
        }
    }

    /// Console output captured from STDOUT / STDERR (or explicit
    /// `Replay.log` calls). `async` for the same re-entrancy reason
    /// as emitPerformance — the customer's print() could fire from
    /// any thread, including one already inside queue.sync. Pre-
    /// runtime events buffer in `pendingConsole` + replay in
    /// `startNewSessionLocked`.
    private func emitConsole(_ event: ConsoleEventData) {
        queue.async {
            if let rt = self.runtime {
                self.pushLocked(rt: rt, type: "console", data: event)
            } else {
                self.pendingConsole.append(event)
                // Cap the pre-runtime buffer at 200 events so an
                // app that hangs forever before foreground (rare,
                // but possible during cold launches with heavy
                // splash logic) doesn't accumulate megabytes of
                // dropped log lines.
                if self.pendingConsole.count > 200 {
                    self.pendingConsole.removeFirst(self.pendingConsole.count - 200)
                }
            }
        }
    }

    /// Use `async` not `sync` here because perf collectors may emit
    /// during `Replay.start` itself (e.g. `ThermalMonitor.start()` /
    /// `BatteryMonitor.start()` both immediately emit baselines) —
    /// that path holds the `queue.sync` lock already, so a nested
    /// `queue.sync` would dispatch-deadlock (libdispatch traps with
    /// "Abort Cause" 27021769562915074). Async re-entry just
    /// enqueues and runs after the current sync block completes;
    /// serial queue preserves ordering.
    ///
    /// Pre-runtime events buffer in `pendingPerf` and replay in
    /// `startNewSessionLocked` — same pattern as track + console.
    /// Without this buffer the very first cold_start_ms +
    /// thermal_state + battery_state emits get silently dropped
    /// because they fire during Replay.start, BEFORE the first
    /// `UIApplication.didBecomeActiveNotification` creates the
    /// runtime.
    private func emitPerformance(_ perf: PerformanceEventData) {
        queue.async {
            if let rt = self.runtime {
                self.pushLocked(rt: rt, type: "performance", data: perf)
            } else {
                self.pendingPerf.append(perf)
                if self.pendingPerf.count > 200 {
                    self.pendingPerf.removeFirst(self.pendingPerf.count - 200)
                }
            }
        }
    }

    private func emitSnapshot(_ snap: NativeSnapshotEventData) {
        queue.async {
            guard let rt = self.runtime else { return }
            self.pushLocked(rt: rt, type: "native_snapshot", data: snap)
        }
    }

    /// Wired by `Replay.tagScreenName`. Updates the tracker's route
    /// so subsequent taps carry the new screen name in uiId. Also
    /// fires an immediate snapshot so the dashboard sees the tagged
    /// screen with its new identity.
    func setRoute(_ route: String) {
        queue.sync {
            tapTracker?.currentRoute = route
        }
        snapshotCapture?.captureNow(trigger: "manual")
    }

    // MARK: - Locked helpers (call from `queue.sync` only)

    private func startNewSessionLocked() {
        guard let config else { return }
        let rt = SessionRuntime(
            config: config,
            deviceContext: DeviceContext.build()
        )
        runtime = rt
        // Reset the once-per-session thumbnail flag so the new
        // session's first snapshot fires a fresh upload (not
        // de-duped by the previous session's hash).
        snapshotCapture?.thumbnailUploader?.reset()
        // Emit session_start with the synthesized URL — the
        // tagScreenName engine (follow-up commit) will overwrite
        // the trailing segment when the customer or auto-tagger
        // identifies the real screen.
        let data = SessionStartEventData(
            href: rt.deviceContext.url,
            path: rt.deviceContext.url.replacingOccurrences(of: "replay://app", with: ""),
            referrer: ""
        )
        pushLocked(rt: rt, type: "session_start", data: data)

        // Replay any track / console events that fired BEFORE the
        // runtime existed (viewDidLoad / init calls that ran before
        // the first didBecomeActive notification). Order preserved
        // via FIFO drain. Once flushed the pending buffers stay
        // empty for the rest of this process lifetime.
        if !pendingTracks.isEmpty {
            for ev in pendingTracks {
                pushLocked(rt: rt, type: "custom", data: ev)
            }
            pendingTracks.removeAll()
        }
        if !pendingConsole.isEmpty {
            for ev in pendingConsole {
                pushLocked(rt: rt, type: "console", data: ev)
            }
            pendingConsole.removeAll()
        }
        if !pendingPerf.isEmpty {
            for ev in pendingPerf {
                pushLocked(rt: rt, type: "performance", data: ev)
            }
            pendingPerf.removeAll()
        }
    }

    private func pushLocked<T: Encodable>(rt: SessionRuntime, type: String, data: T) {
        let now = SessionRuntime.nowMs()
        let event = ReplayEvent(
            id: rt.makeEventId(),
            ts: now,
            offsetMs: now - rt.startedAt,
            type: type,
            source: Platform.ios,
            data: data
        )
        rt.push(event)
        if rt.shouldForceFlush {
            Task.detached(priority: .utility) { [weak self] in
                await self?.flushNow()
            }
        }
    }

    /// Drain + POST via the queue-aware uploader. Failed live sends
    /// are persisted to disk and drained on next foreground.
    private func flushNow() async {
        let (rt, uploader, projectId): (SessionRuntime?, BatchUploader?, String?) = queue.sync {
            (self.runtime, self.uploader, self.config?.projectId)
        }
        guard let rt, let uploader else { return }
        let events = rt.drain()
        guard !events.isEmpty else { return }
        let envelope = ReplayBatchEnvelope(
            sessionId: rt.sessionId,
            segmentId: rt.segmentId,
            sequence: rt.nextSequence(),
            sentAt: SessionRuntime.nowMs(),
            sdk: rt.sdk,
            page: rt.deviceContext,
            events: events,
            projectId: projectId
        )
        await uploader.upload(envelope)
    }

    /// Coerce arbitrary track-property values into JSON-safe shapes.
    /// Cap at 20 keys, 200 chars per string. Mirrors the Android +
    /// web SDK `safeProps` implementations.
    private func safeProps(_ props: [String: Any]?) -> [String: AnyEncodable]? {
        guard let props, !props.isEmpty else { return nil }
        var out: [String: AnyEncodable] = [:]
        out.reserveCapacity(min(props.count, 20))
        var i = 0
        for (k, v) in props {
            if i >= 20 { break }
            i += 1
            switch v {
            case let s as String:
                out[k] = AnyEncodable(String(s.prefix(200)))
            case is NSNumber, is Bool, is Int, is Double, is Float:
                out[k] = AnyEncodable(v)
            case let arr as [Any]:
                let capped: [Any] = arr.prefix(20).map { val in
                    if let s = val as? String { return String(s.prefix(200)) as Any }
                    return val
                }
                out[k] = AnyEncodable(capped)
            default:
                out[k] = AnyEncodable(String(describing: v).prefix(200).description)
            }
        }
        return out
    }
}
