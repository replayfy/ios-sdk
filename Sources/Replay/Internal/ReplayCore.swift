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
    private var lifecycle: LifecycleObserver?
    private var flushTask: Task<Void, Never>?
    private var tapTracker: TapTracker?
    private var snapshotCapture: SnapshotCapture?

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
            snapshot.captureBitmaps = config.captureSnapshotPixels
            self.snapshotCapture = snapshot

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
            guard let rt = runtime else {
                ReplayLog.warn("track before start — dropping '\(safeName)'")
                return
            }
            let data = CustomEventData(
                kind: "track",
                name: safeName,
                properties: safeProps(properties)
            )
            pushLocked(rt: rt, type: "custom", data: data)
        }
    }

    // MARK: - Lifecycle

    private func onAppForegrounded() {
        queue.sync {
            guard config != nil else { return }
            guard runtime == nil else { return }
            startNewSessionLocked()
        }
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

    private func emitSnapshot(_ snap: NativeSnapshotEventData) {
        queue.sync {
            guard let rt = runtime else { return }
            pushLocked(rt: rt, type: "native_snapshot", data: snap)
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

    /// Drain + POST. Async to support `URLSession.data(for:)`.
    /// Locks briefly to snapshot the runtime + sender refs, then
    /// runs the network call outside the lock.
    private func flushNow() async {
        let (rt, sender, projectId): (SessionRuntime?, BatchSender?, String?) = queue.sync {
            (self.runtime, self.sender, self.config?.projectId)
        }
        guard let rt, let sender else { return }
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
        await sender.send(envelope)
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
