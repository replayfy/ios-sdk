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
            let (_, response) = try await session.data(for: request)
            // Backend returns 200 even on R2-disabled dev (the
            // response body has ok:false). We don't bother
            // parsing — best-effort, dashboard falls back to a
            // blank card if the URL never lands on Session.
            _ = response
        } catch {
            // Network error — flip the flag back so next snapshot
            // retries the thumbnail upload.
            lock.withLock { _alreadySent = false }
            ReplayLog.verbose("thumbnail upload failed: \(error.localizedDescription)")
        }
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
