import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Posts the FIRST captured bitmap of each session to
/// `POST /v1/replay/thumbnail` — populates the dashboard's
/// Recordings list thumbnail for native sessions.
///
/// The thumbnail endpoint already exists (used by the web SDK's
/// rrweb-rendered first-frame thumbnail). For native we just need
/// to call it once per session with a downsized JPEG of the first
/// snapshot bitmap.
///
/// Once-per-session: a `Bool` flag flips after the first successful
/// upload; subsequent snapshots in the same session skip this path.
/// New session = fresh ThumbnailUploader instance (or reset the
/// flag — we expose ``reset()`` for that).
final class ThumbnailUploader {

    private let config: ReplayConfig
    private let session: URLSession

    private var _alreadySent = false
    private let lock = NSLock()

    /// Target longest-edge for the thumbnail. Matches the web SDK's
    /// recordings-list rendering size (cards are ~160-320 wide on
    /// most viewports), keeps payload tiny.
    private let targetLongestEdge: CGFloat = 320

    /// JPEG quality (0..1). Thumbnails don't need lossless; JPEG
    /// at 0.7 yields ~5-10 KB per thumbnail vs ~50 KB for PNG.
    private let jpegQuality: CGFloat = 0.7

    init(config: ReplayConfig) {
        self.config = config
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 20
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    /// Reset the once-per-session flag — called by ReplayCore when
    /// a new session starts (background→foreground rotation).
    func reset() {
        lock.withLock { _alreadySent = false }
    }

    /// Send the bitmap as the session's thumbnail. No-op if a
    /// thumbnail was already sent for this session, or if `image`
    /// is unsuitable.
    ///
    /// Caller passes the source UIImage from BitmapCapture
    /// (full-screen). We downsize + JPEG-encode here so the upload
    /// pipeline doesn't waste bandwidth on a full-res PNG.
    #if canImport(UIKit)
    func sendIfFirst(image: UIImage, sessionPublicId: String) async {
        let shouldSend: Bool = lock.withLock {
            if _alreadySent { return false }
            _alreadySent = true
            return true
        }
        guard shouldSend else { return }

        guard let bytes = thumbnailJpeg(from: image) else {
            // Revert the flag — if we couldn't encode, we want the
            // NEXT snapshot to retry.
            lock.withLock { _alreadySent = false }
            return
        }

        let b64 = bytes.base64EncodedString(options: [])
        let dataUrl = "data:image/jpeg;base64,\(b64)"
        let payload: [String: Any] = [
            "sessionPublicId": sessionPublicId,
            "dataUrl": dataUrl,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            lock.withLock { _alreadySent = false }
            return
        }

        let host = config.apiHost.trimmingCharacters(in: ["/"])
        guard let url = URL(string: "\(host)/v1/replay/thumbnail") else {
            lock.withLock { _alreadySent = false }
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-replay-api-key")

        do {
            let (responseBody, response) = try await session.data(for: request)
            // Backend returns HTTP 200 even on logical failure
            // (R2 not configured, session row not yet created on
            // the server because the first snapshot raced ahead of
            // the session_start batch, etc.) — the real success
            // signal lives in the JSON body's nested `data.ok`.
            // Parse + only mark sent when ok=true AND a real URL
            // came back, otherwise flip the flag back so the next
            // snapshot retries.
            //
            // Mirrors the Android SDK's ThumbnailUploader.kt fix
            // (commit 839f7da). Closes the same race where iOS
            // sessions never got thumbnails.
            let ok = isHttpSuccess(response) && responseBodyOk(responseBody)
            if !ok {
                lock.withLock { _alreadySent = false }
            }
        } catch {
            // Network error — flip the flag back so next snapshot
            // retries the thumbnail upload.
            lock.withLock { _alreadySent = false }
            ReplayLog.verbose("thumbnail upload failed: \(error.localizedDescription)")
        }
    }

    /// HTTP 2xx success — extracted for testability.
    private func isHttpSuccess(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        return (200...299).contains(http.statusCode)
    }

    /// Parse the standard ingest envelope `{ok, data: {ok, url?}, meta}`.
    /// The inner `data.ok` is the authoritative signal for THIS
    /// endpoint — outer `ok` only confirms the request was routed.
    /// Returns true when the endpoint actually stored a thumbnail URL.
    private func responseBodyOk(_ body: Data) -> Bool {
        guard !body.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return false }
        // Standard ingest shape: { ok, data: { ok, url, ... }, meta }
        if let inner = json["data"] as? [String: Any] {
            let innerOk = inner["ok"] as? Bool ?? false
            let urlStr = inner["url"] as? String
            return innerOk && (urlStr?.isEmpty == false)
        }
        // Plain `{ ok, url }` shape — also accept.
        let outerOk = json["ok"] as? Bool ?? false
        let urlStr = json["url"] as? String
        return outerOk && (urlStr?.isEmpty == false)
    }

    /// Downsize the captured UIImage to thumbnail dimensions and
    /// re-encode as JPEG. Preserves aspect ratio.
    private func thumbnailJpeg(from image: UIImage) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let longest = max(size.width, size.height)
        let scale = min(1, targetLongestEdge / longest)
        let target = CGSize(
            width: size.width * scale,
            height: size.height * scale
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1 // Already accounting for screen scale in the source UIImage
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: jpegQuality)
    }
    #endif
}
