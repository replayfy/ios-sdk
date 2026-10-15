import Foundation

/// Session-start response from the backend.
struct MobileStartResponse: Decodable {
    let token: String
    let sessionID: String
    let fps: Int
    let quality: String
    let framesSupport: Bool
    let projectID: String
    let userUUID: String
    // Dashboard-controlled capture toggles (optional → default true).
    let captureConsole: Bool?
    let captureNetwork: Bool?
    // Granular network toggles — strip headers / bodies before they leave the
    // device when disabled. Optional → default true for older servers.
    let captureNetworkHeaders: Bool?
    let captureNetworkBodies: Bool?
    // false ⇒ the server's sampling gate dropped this launch; the SDK must
    // not record. Optional → default true for older servers.
    let record: Bool?
    // Dashboard privacy enforcement. Optional: older servers don't send it.
    let privacy: MobileStartPrivacy?
}

/// The `privacy` block of the session-start response.
struct MobileStartPrivacy: Decodable {
    /// The dashboard's "always mask input values": mask every text field and
    /// text view, on top of whatever the app does. It can only add masking.
    let occludeAllTextFields: Bool?
}

/// The upload half of `MobileTransport` that the frame and message buffers
/// drain into. A protocol so the drain/retry logic can be exercised against a
/// stub in tests. `completion(true)` means the server accepted the batch.
protocol MobileUploading: AnyObject {
    func sendMessages(_ gzippedBatch: Data, completion: @escaping (Bool) -> Void)
    func sendLateMessages(_ batch: Data, completion: @escaping (Bool) -> Void)
    func sendImages(_ gzippedArchive: Data, completion: @escaping (Bool) -> Void)
}

/// HTTP transport for the mobile ingest endpoints.
///
///   POST {host}/v1/mobile/start   → JSON device params, returns token
///   POST {host}/v1/mobile/i       → gzipped binary message batch
///   POST {host}/v1/mobile/late    → un-gzipped binary message batch
///   POST {host}/v1/mobile/images  → gzipped frames archive
///
/// `/start` is project-key authed (the key rides in the JSON body);
/// the data endpoints use the session token as `Authorization:
/// Bearer`. The response envelope wraps payloads in `{ data: … }`.
final class MobileTransport: MobileUploading {
    private let baseURL: String
    private let projectKey: String
    private var token: String?

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }()

    init(baseURL: String, projectKey: String) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.projectKey = projectKey
    }

    var sessionToken: String? { token }

    func start(params: [String: Any], completion: @escaping (MobileStartResponse?) -> Void) {
        guard let url = URL(string: baseURL + "/v1/mobile/start"),
              let bodyData = try? JSONSerialization.data(withJSONObject: params) else {
            completion(nil); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData
        session.dataTask(with: req) { [weak self] data, resp, _ in
            guard let data = data,
                  let code = (resp as? HTTPURLResponse)?.statusCode, (200...299).contains(code),
                  let unwrapped = MobileTransport.unwrap(data),
                  let parsed = try? JSONDecoder().decode(MobileStartResponse.self, from: unwrapped) else {
                completion(nil); return
            }
            self?.token = parsed.token
            completion(parsed)
        }.resume()
    }

    func sendMessages(_ gzippedBatch: Data, completion: @escaping (Bool) -> Void) {
        post(path: "/v1/mobile/i", body: gzippedBatch, completion: completion)
    }

    func sendLateMessages(_ batch: Data, completion: @escaping (Bool) -> Void) {
        post(path: "/v1/mobile/late", body: batch, completion: completion)
    }

    func sendImages(_ gzippedArchive: Data, completion: @escaping (Bool) -> Void) {
        post(path: "/v1/mobile/images", body: gzippedArchive, completion: completion)
    }

    /// Best-effort "drop this session" signal — POST /v1/mobile/cancel with the
    /// session bearer token and a JSON `{ sessionId }`. Fire-and-forget:
    /// cancelSession tears down locally regardless of the outcome.
    func cancel(sessionID: String, completion: ((Bool) -> Void)? = nil) {
        guard let token = token, let url = URL(string: baseURL + "/v1/mobile/cancel"),
              let body = try? JSONSerialization.data(withJSONObject: ["sessionId": sessionID]) else {
            completion?(false); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = body
        session.dataTask(with: req) { _, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            completion?((200...299).contains(code))
        }.resume()
    }

    private func post(path: String, body: Data, completion: @escaping (Bool) -> Void) {
        guard let token = token, let url = URL(string: baseURL + path) else {
            completion(false); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = body
        session.dataTask(with: req) { _, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            completion((200...299).contains(code))
        }.resume()
    }

    /// Pull `data` out of the `{ ok, data, meta }` response envelope.
    private static func unwrap(_ data: Data) -> Data? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inner = obj["data"] else { return nil }
        return try? JSONSerialization.data(withJSONObject: inner)
    }
}
