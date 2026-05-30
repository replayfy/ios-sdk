import Foundation

/// Periodically fetches the dashboard's `/v1/sdk/config` response,
/// caches it to UserDefaults, and applies it to the SDK's runtime
/// state.
///
/// # Lifecycle
///
///   1. **Cold launch** — load LAST CACHED response (if any) from
///      UserDefaults + apply immediately. Offline first-launch
///      flows get last-known-good behaviour rather than the
///      customer-passed `ReplayConfig` baseline.
///   2. **Async first fetch** — fires within the first ~2s of
///      `start()` returning. Successful response overwrites the
///      cache + reapplies the runtime state. Network failure
///      leaves the cached config in place and re-tries on the next
///      cycle.
///   3. **Periodic re-fetch** — every ``refreshInterval`` (default
///      15 min). Customers flipping toggles in the dashboard see
///      the change in at most one fetch cycle.
///
/// # Override semantics
///
/// The dashboard response ALWAYS wins over the customer-passed
/// ``ReplayConfig``. The customer's baseline becomes a fallback
/// used only when:
///   - The cold-launch cache is empty AND the first fetch hasn't
///     completed.
///   - The customer set `useRemoteConfig: false` (escape hatch).
///
/// Mirrors Android's `RemoteConfigFetcher.kt` step-for-step so the
/// cross-platform fetch + apply semantics are uniform.
final class RemoteConfigFetcher {

    private let config: ReplayConfig
    private let onApply: (RemoteConfig) -> Void

    /// UserDefaults suite — separate namespace from the SDK's
    /// opt-out store so cleanup logic stays decoupled.
    private static let suiteName = "com.replayfy.remoteconfig.v1"
    private static let keyPayload = "payload_json"
    private static let keyFetchedAt = "fetched_at_ms"

    private let defaults: UserDefaults

    /// 15 min — matches Android + balances "customers see flips
    /// reasonably fast" against "we don't hammer the backend".
    private let refreshInterval: TimeInterval = 15 * 60

    /// Repeating timer; nil before start() and after stop().
    private var timer: Timer?
    private let queue = DispatchQueue(
        label: "com.replayfy.remote-config-fetcher",
        qos: .utility
    )

    /// Last applied config — surfaced so the apply handler can
    /// short-circuit "did anything change?" checks without holding
    /// its own reference.
    private(set) var current: RemoteConfig?

    init(
        config: ReplayConfig,
        onApply: @escaping (RemoteConfig) -> Void
    ) {
        self.config = config
        self.onApply = onApply
        self.defaults =
            UserDefaults(suiteName: RemoteConfigFetcher.suiteName)
            ?? UserDefaults.standard
    }

    /// Apply the cached response IMMEDIATELY (cold-launch path),
    /// then kick off the periodic fetch loop. Idempotent — repeat
    /// calls re-apply but don't double-schedule.
    func start() {
        // Cold-launch apply.
        if let cached = loadCached() {
            current = cached
            onApply(cached)
        }
        // First fetch fires on a background queue so the customer's
        // start() returns immediately. Subsequent fetches use the
        // Timer set up below.
        queue.async { [weak self] in self?.fetchOnce() }
        // Schedule periodic refresh on the main runloop so Timer
        // semantics are correct across iOS versions. The handler
        // hops back to the background queue.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.timer?.invalidate()
            self.timer = Timer.scheduledTimer(
                withTimeInterval: self.refreshInterval,
                repeats: true
            ) { [weak self] _ in
                self?.queue.async { self?.fetchOnce() }
            }
        }
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            self?.timer?.invalidate()
            self?.timer = nil
        }
    }

    /// Single fetch + parse. Applies + saves to cache on success.
    private func fetchOnce() {
        let host = config.apiHost.hasSuffix("/")
            ? String(config.apiHost.dropLast())
            : config.apiHost
        guard let url = URL(string: "\(host)/v1/sdk/config") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue(config.apiKey, forHTTPHeaderField: "x-replay-api-key")
        req.setValue(buildUserAgent(), forHTTPHeaderField: "user-agent")

        let task = URLSession.shared.dataTask(with: req) {
            [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                // Network failure — keep the cached config in place,
                // next cycle retries.
                ReplayLog.warn(
                    "RemoteConfig fetch failed: \(error.localizedDescription)"
                )
                return
            }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data = data
            else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                ReplayLog.warn("RemoteConfig fetch HTTP \(code) — keeping cached")
                return
            }
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            guard let cfg = RemoteConfig.parse(data, fetchedAtMs: now) else {
                ReplayLog.warn("RemoteConfig parse failed")
                return
            }
            self.current = cfg
            self.saveCached(cfg, raw: data)
            // Apply on the main thread — handlers toggle subsystems
            // that may touch UIKit (autoScreenName, occludeAll*),
            // safer to keep on main.
            DispatchQueue.main.async { self.onApply(cfg) }
        }
        task.resume()
    }

    private func loadCached() -> RemoteConfig? {
        guard let json = defaults.data(forKey: RemoteConfigFetcher.keyPayload),
              let cfg = RemoteConfig.parse(
                json,
                fetchedAtMs: Int64(defaults.double(forKey: RemoteConfigFetcher.keyFetchedAt))
              )
        else { return nil }
        return cfg
    }

    /// Cache the raw response body verbatim — RemoteConfig.parse is
    /// cheap, so storing the JSON rather than the decoded struct
    /// gives us forward-compat with future field additions.
    private func saveCached(_ cfg: RemoteConfig, raw: Data) {
        defaults.set(raw, forKey: RemoteConfigFetcher.keyPayload)
        defaults.set(
            Double(cfg.fetchedAtMs),
            forKey: RemoteConfigFetcher.keyFetchedAt
        )
    }

    private func buildUserAgent() -> String {
        return "\(BuildInfo.sdkName)/\(BuildInfo.sdkVersion) (ios)"
    }
}
