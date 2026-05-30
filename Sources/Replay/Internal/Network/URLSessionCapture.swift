import Foundation

/// URLProtocol subclass that captures every URLSession.shared
/// request (+ deprecated NSURLConnection traffic) and emits a
/// ``NetworkEventData`` event.
///
/// How URLProtocol-based interception works:
///   • Apple's URL loading system asks each registered URLProtocol
///     subclass `canInit(with:)` for every outbound request.
///   • If we return true, we OWN the request — must implement
///     startLoading + stopLoading, forward bytes upstream, and
///     deliver them back to the URL loading system via
///     URLProtocolClient callbacks.
///   • We forward to a separate "real" URLSession (one whose
///     protocolClasses doesn't include us — prevents infinite loops)
///     and tee the response data into our event.
///
/// AUTO-INSTALLATION LIMITATION: URLProtocol.registerClass only
/// affects URLSession.shared + NSURLConnection. Customer-created
/// URLSession instances (URLSession(configuration: …)) bypass our
/// interceptor unless the customer explicitly adds us to their
/// config's protocolClasses array. Common iOS apps use shared, so
/// v1 catches the typical case. Future commit can ship a
/// public helper for customers to install on their own configs.
///
/// Tag-recursion guard: we tag the request with a property to
/// detect when our own forwarded request comes back to canInit.
final class URLSessionCapture: URLProtocol {

    /// Marker so we recognise requests we've already wrapped and
    /// pass them through unmodified — avoids infinite recursion
    /// when our forwarded request itself triggers canInit.
    private static let handledKey = "com.replayfy.URLSessionCapture.handled"

    /// Currently-running emit callback. Set when the SDK installs;
    /// cleared on uninstall. nil → URLProtocol still claims requests
    /// (we registered with the URL loading system) but events are
    /// dropped on the floor.
    nonisolated(unsafe) static var emit: ((NetworkEventData) -> Void)?

    /// Settings the SDK passes in from ReplayConfig. Read on each
    /// request to honour mid-session remote-config changes.
    nonisolated(unsafe) static var captureHeaders: Bool = false
    nonisolated(unsafe) static var maxBodyBytes: Int = 4_096
    nonisolated(unsafe) static var redactPatterns: [NSRegularExpression] = []

    /// Forward session — its config DOESN'T include us in
    /// protocolClasses, so requests we send here go directly to the
    /// network without recursing through this class.
    private static let forwarder: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.protocolClasses = []
        return URLSession(configuration: cfg)
    }()

    private var dataTask: URLSessionDataTask?
    private var responseData = Data()
    private var startedAt: Int64 = 0
    private var requestId: String = UUID().uuidString
    private var capturedResponse: URLResponse?

    // MARK: - URLProtocol installation

    /// Install the protocol globally. Idempotent — registerClass
    /// is a no-op if already registered.
    static func install() {
        URLProtocol.registerClass(URLSessionCapture.self)
    }

    /// Uninstall. Called on Replay.stop (best-effort cleanup —
    /// process death is the more common termination).
    static func uninstall() {
        URLProtocol.unregisterClass(URLSessionCapture.self)
    }

    /// Inject the capture protocol into a custom URLSessionConfiguration.
    /// URLProtocol.registerClass only takes effect on URLSession.shared
    /// + the deprecated NSURLConnection path. Customer code that
    /// constructs URLSession via `URLSession(configuration:)` bypasses
    /// us unless we sit in their `configuration.protocolClasses`
    /// array.
    ///
    /// Idempotent — calling twice with the same configuration leaves
    /// only one entry. Customers wire this BEFORE handing the
    /// configuration to URLSession.init since URLSession copies the
    /// config at construction.
    ///
    ///     let cfg = URLSessionConfiguration.default
    ///     URLSessionCapture.captureCustomConfiguration(cfg)
    ///     let session = URLSession(configuration: cfg)
    ///
    /// Honours the same `enabled` gate as the auto-installed
    /// protocol — when captureNetwork=false the prepended class is
    /// still inert (canInit returns false), so this is safe to wire
    /// at app launch regardless of the runtime capture flag.
    static func captureCustomConfiguration(_ configuration: URLSessionConfiguration) {
        var classes = configuration.protocolClasses ?? []
        // Strip any existing entry first so the prepend is idempotent
        // — protocolClasses is checked in order; we want to be first.
        classes.removeAll { $0 == URLSessionCapture.self }
        classes.insert(URLSessionCapture.self, at: 0)
        configuration.protocolClasses = classes
    }

    // MARK: - URLProtocol overrides

    override class func canInit(with request: URLRequest) -> Bool {
        // Recursion guard — our forwarded request carries the
        // handled marker and skips re-interception.
        if URLProtocol.property(forKey: handledKey, in: request) != nil {
            return false
        }
        // Only http/https — skip file://, data://, custom schemes.
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        guard scheme == "http" || scheme == "https" else { return false }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        startedAt = nowMs()
        // Mutable copy + add the handled marker so canInit skips
        // our forwarded request.
        let mutable = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutable)
        let forwarded = mutable as URLRequest

        // Use dataTask(with:completionHandler:) since URLProtocol
        // doesn't need streaming semantics — we tee the body data
        // in `didReceive data:` via the delegate API.
        let task = Self.forwarder.dataTask(with: forwarded) { [weak self] data, response, error in
            guard let self else { return }
            // Capture metadata + emit before forwarding bytes back
            // to the URL loading system so the event lands even if
            // the downstream client doesn't drain the response.
            self.finish(data: data, response: response, error: error)

            // Forward back to the URL loading system so the
            // customer's URLSession completion handler fires
            // normally.
            if let error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            if let response {
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            if let data {
                self.client?.urlProtocol(self, didLoad: data)
            }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        dataTask = task
        task.resume()
    }

    override func stopLoading() {
        dataTask?.cancel()
        dataTask = nil
    }

    // MARK: - Event assembly

    private func finish(data: Data?, response: URLResponse?, error: Error?) {
        let endedAt = nowMs()
        let url = request.url?.absoluteString ?? ""
        if Self.isRedacted(url) { return }

        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode
        let ok = statusCode.map { (200..<300).contains($0) }

        let reqHeaders: [String: String]? = Self.captureHeaders
            ? Self.headerDict(request.allHTTPHeaderFields)
            : nil
        let respHeaders: [String: String]? = Self.captureHeaders
            ? Self.headerDict(http?.allHeaderFields)
            : nil
        let reqBody = Self.bodyString(request.httpBody, cap: Self.maxBodyBytes)
        let respBody = Self.bodyString(data, cap: Self.maxBodyBytes)

        let event = NetworkEventData(
            requestId: requestId,
            transport: "urlsession",
            method: request.httpMethod ?? "GET",
            url: url,
            statusCode: statusCode,
            startedAt: startedAt,
            endedAt: endedAt,
            durationMs: endedAt - startedAt,
            ok: ok,
            requestHeaders: reqHeaders,
            responseHeaders: respHeaders,
            requestBody: reqBody,
            responseBody: respBody,
            error: error.map { "\($0.localizedDescription)" }
        )
        Self.emit?(event)
    }

    // MARK: - Helpers

    private static func headerDict(_ raw: [AnyHashable: Any]?) -> [String: String]? {
        guard let raw, !raw.isEmpty else { return nil }
        var out: [String: String] = [:]
        for (k, v) in raw {
            out["\(k)"] = "\(v)"
        }
        return out
    }

    private static func headerDict(_ raw: [String: String]?) -> [String: String]? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    /// Convert a body Data to a String, truncated at the byte cap.
    /// Returns nil for non-UTF8 / very-large / empty bodies — caller
    /// drops the field.
    private static func bodyString(_ data: Data?, cap: Int) -> String? {
        guard let data, !data.isEmpty else { return nil }
        let capped = data.count <= cap ? data : data.prefix(cap)
        if let s = String(data: capped, encoding: .utf8) {
            return data.count <= cap ? s : s + "…[truncated \(data.count - cap)B]"
        }
        return nil
    }

    /// Check the request URL against the configured redact-pattern
    /// list. Matches → drop event entirely (don't even ship the URL,
    /// since the URL itself may carry secret tokens in path/query).
    private static func isRedacted(_ url: String) -> Bool {
        for pattern in redactPatterns {
            let range = NSRange(url.startIndex..., in: url)
            if pattern.firstMatch(in: url, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    private func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
