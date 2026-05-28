import Foundation

/// POSTs envelopes to `/v1/replay/batch` via URLSession.
///
/// Uses URLSession's async `data(for:)` API (iOS 15+). Synchronous
/// wrapper for the queue worker — they fire from background tasks
/// and don't have a structured-concurrency context.
///
/// Errors are best-effort logged via `os_log`. The persistent-queue
/// layer (future commit) will catch failed sends and stage them to
/// disk for retry by a background URLSession.
final class BatchSender {

    private let config: ReplayConfig
    private let session: URLSession

    /// Currently-known identity, attached to every outgoing batch.
    /// Lock around mutation so identify() can change it while a
    /// flush is mid-flight without tearing.
    private var _identity: IdentifyPayload?
    private let identityLock = NSLock()

    var identity: IdentifyPayload? {
        get { identityLock.withLock { _identity } }
        set { identityLock.withLock { _identity = newValue } }
    }

    init(config: ReplayConfig) {
        self.config = config
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        cfg.waitsForConnectivity = false
        // No HTTP cookies — replay batches are stateless POSTs.
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpShouldSetCookies = false
        self.session = URLSession(configuration: cfg)
    }

    /// Send the envelope. Returns true on HTTP 2xx, false otherwise.
    /// Async — caller awaits on a background Task.
    @discardableResult
    func send(_ envelope: ReplayBatchEnvelope) async -> Bool {
        let body: Data
        do {
            body = try serialize(envelope: envelope, identity: identity)
        } catch {
            ReplayLog.warn("serialize failed: \(error)")
            return false
        }
        return await sendJson(body, sdkName: envelope.sdk.name, sdkVersion: envelope.sdk.version)
    }

    /// Send a pre-serialized JSON body. Used by the on-disk queue
    /// worker that drains persisted batches without re-serializing.
    @discardableResult
    func sendJson(_ body: Data, sdkName: String, sdkVersion: String) async -> Bool {
        var request = URLRequest(url: makeUrl())
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-replay-api-key")
        request.setValue("\(sdkName)/\(sdkVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            ReplayLog.verbose("batch send failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Public for the queue layer — serialize without sending so the
    /// queue can persist the body before attempting the live POST.
    /// Identity captured at serialize-time, frozen in the bytes.
    func serialize(envelope: ReplayBatchEnvelope, identity: IdentifyPayload?) throws -> Data {
        let body = IngestRequest(
            envelope: envelope,
            identify: identity,
            fingerprint: nil
        )
        let encoder = JSONEncoder()
        // Match the web SDK's wire format — no pretty-printing in
        // production batches, ms timestamps as integers (the default
        // for Int64 fields).
        encoder.outputFormatting = []
        return try encoder.encode(body)
    }

    private func makeUrl() -> URL {
        let host = config.apiHost.trimmingCharacters(in: ["/"])
        // swiftlint:disable:next force_unwrapping
        return URL(string: "\(host)/v1/replay/batch")!
    }
}

// MARK: - Logging helper

/// Centralised logging. Routes through `os_log` so the host app's
/// console + Console.app both see the SDK's messages. Verbose is
/// off by default; flip via `Replay.setVerboseLogging(true)` (future).
enum ReplayLog {
    static func verbose(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[Replay] \(message())")
        #endif
    }

    static func warn(_ message: @autoclosure () -> String) {
        print("[Replay] ⚠️ \(message())")
    }

    static func info(_ message: @autoclosure () -> String) {
        print("[Replay] \(message())")
    }
}

// MARK: - NSLock convenience

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
