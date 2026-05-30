import Foundation

/// Mobile-relevant subset of the dashboard's `/v1/sdk/config`
/// response. The full backend response carries fields meaningful
/// only for the web SDK (canvas / iframe / blockSelectors); we
/// drop them on parse.
///
/// **Override semantics.** This config ALWAYS wins over the
/// customer-passed ``ReplayConfig``. The customer's baseline
/// becomes a fallback used only when the remote fetch hasn't
/// completed yet (cold-launch first-fetch race) AND no cached
/// prior response exists.
///
/// Mirrors Android's `RemoteConfig.kt` — same field shape so
/// cross-platform debug tools (a future "show me this device's
/// effective config" inspector) work uniformly.
struct RemoteConfig: Codable {

    let workspaceId: Int?

    let captureConsole: Bool
    let captureNetwork: Bool
    let captureNetworkHeaders: Bool
    let captureNetworkBodies: Bool
    let captureErrors: Bool
    let capturePerformance: Bool
    let minDurationMs: Int

    let samplingRate: Double
    let samplingAlwaysRecordErrors: Bool
    let samplingAlwaysRecordIdentified: Bool

    let privacyMaskAllInputs: Bool
    let privacyRedactUrlPatterns: [String]

    let retentionDays: Int

    /// Wall-clock millis when the fetch landed. Surfaced on cached
    /// reads so the caller can tell how stale the value is.
    let fetchedAtMs: Int64

    /// Parse the JSON body returned by `GET /v1/sdk/config`.
    /// Tolerant of missing fields — each property falls back to a
    /// sensible default so an old-version backend doesn't break the
    /// SDK.
    static func parse(_ data: Data, fetchedAtMs: Int64) -> RemoteConfig? {
        guard let root = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any]
        else { return nil }
        let capture = root["capture"] as? [String: Any] ?? [:]
        let sampling = root["sampling"] as? [String: Any] ?? [:]
        let privacy = root["privacy"] as? [String: Any] ?? [:]
        return RemoteConfig(
            workspaceId: root["workspaceId"] as? Int,
            captureConsole: capture["console"] as? Bool ?? true,
            captureNetwork: capture["network"] as? Bool ?? false,
            captureNetworkHeaders: capture["networkHeaders"] as? Bool ?? false,
            captureNetworkBodies: capture["networkBodies"] as? Bool ?? false,
            captureErrors: capture["errors"] as? Bool ?? true,
            capturePerformance: capture["performance"] as? Bool ?? true,
            minDurationMs: max(0, (capture["minDurationMs"] as? Int) ?? 5_000),
            samplingRate: min(
                1.0,
                max(0.0, (sampling["rate"] as? Double) ?? 1.0)
            ),
            samplingAlwaysRecordErrors:
                sampling["alwaysRecordErrors"] as? Bool ?? true,
            samplingAlwaysRecordIdentified:
                sampling["alwaysRecordIdentified"] as? Bool ?? true,
            privacyMaskAllInputs:
                privacy["maskAllInputs"] as? Bool ?? false,
            privacyRedactUrlPatterns:
                (privacy["redactUrlPatterns"] as? [String]) ?? [],
            retentionDays: root["retentionDays"] as? Int ?? 30,
            fetchedAtMs: fetchedAtMs
        )
    }
}
