import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Uploads snapshot bitmaps to `POST /v1/replay/assets/:hash` and
/// returns the resolved URL the player fetches at render time.
///
/// Content-addressed: the same image bytes always produce the same
/// hash, so we cache `hash → URL` locally and skip the round-trip
/// on subsequent snapshots that contain the same image (recurring
/// icons, loading spinners, app chrome).
///
/// Mirrors Android's `AssetUploader.kt`.
final class AssetUploader {

    private let config: ReplayConfig
    private let session: URLSession

    /// LRU cache — hash → URL (or nil on permanent failure, so we
    /// don't retry forever on a broken hash). Capped at maxCached
    /// entries with simple FIFO eviction; recency tracked via the
    /// order-of-insertion + a remove-on-hit re-insert.
    private var cache: [String: String?] = [:]
    private var cacheOrder: [String] = []
    private let cacheLock = NSLock()
    private let maxCached = 256

    init(config: ReplayConfig) {
        self.config = config
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 30
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    /// Upload the asset and return its resolved URL. Returns the
    /// cached URL when the hash has been seen before; uploads
    /// fresh otherwise.
    ///
    /// Returns nil when:
    ///   - upload failed (network error, non-2xx response,
    ///     malformed body)
    ///   - storage is disabled on the backend (returns ok:false)
    /// In any null case the snapshot ships without imageRef and the
    /// player falls back to wireframe rendering for that frame.
    func uploadOrCached(_ asset: BitmapCapture.EncodedAsset) async -> String? {
        if let cached = readCache(asset.hash) {
            return cached
        }
        let url = await doUpload(asset)
        writeCache(asset.hash, url: url)
        return url
    }

    private func doUpload(_ asset: BitmapCapture.EncodedAsset) async -> String? {
        let body: Data
        do {
            let payload = ["dataUrl": buildDataUrl(asset)]
            body = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            return nil
        }

        let host = config.apiHost.trimmingCharacters(in: ["/"])
        guard let url = URL(string: "\(host)/v1/replay/assets/\(asset.hash)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-replay-api-key")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return nil
            }
            return parseUrl(data)
        } catch {
            ReplayLog.verbose("asset upload failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Backend's endpoint accepts base64 data URLs (same shape as
    /// the existing thumbnail endpoint). Base64 adds ~33% vs binary
    /// multipart — fine for snapshot-sized payloads (30-200 KB),
    /// saves the backend from needing a separate multipart parser.
    private func buildDataUrl(_ asset: BitmapCapture.EncodedAsset) -> String {
        let b64 = asset.bytes.base64EncodedString(options: [])
        return "data:\(asset.contentType);base64,\(b64)"
    }

    /// Response shape: { ok, data: { ok, url, hash } }. We pull
    /// `data.url` when present. Defensive parse — never throw on
    /// a misshapen response.
    private func parseUrl(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return nil
        }
        guard let inner = json["data"] as? [String: Any] else { return nil }
        let ok = (inner["ok"] as? Bool) ?? false
        guard ok else { return nil }
        let url = inner["url"] as? String
        return url?.isEmpty == false ? url : nil
    }

    // MARK: - LRU cache

    private func readCache(_ hash: String) -> String?? {
        cacheLock.withLock {
            guard cache.keys.contains(hash) else { return nil }
            // Re-insert key at the end of order so it becomes
            // most-recently-used.
            if let idx = cacheOrder.firstIndex(of: hash) {
                cacheOrder.remove(at: idx)
            }
            cacheOrder.append(hash)
            return cache[hash]
        }
    }

    private func writeCache(_ hash: String, url: String?) {
        cacheLock.withLock {
            cache[hash] = url
            if let idx = cacheOrder.firstIndex(of: hash) {
                cacheOrder.remove(at: idx)
            }
            cacheOrder.append(hash)
            // Evict oldest when over capacity.
            while cacheOrder.count > maxCached {
                let evicted = cacheOrder.removeFirst()
                cache.removeValue(forKey: evicted)
            }
        }
    }
}
