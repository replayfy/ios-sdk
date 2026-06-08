import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(WebKit)
import WebKit
#endif

/// Async-but-feels-sync WKWebView snapshot cache.
///
/// **Why this exists**
///
/// `UIView.drawHierarchy(in:afterScreenUpdates:)` — the snapshot API
/// the rest of `BitmapCapture` uses — does not reliably capture
/// `WKWebView` content. WebKit composites its page on a separate
/// process (`com.apple.WebKit.WebContent`) and the rendered pixels
/// reach the host process via an IOSurface that `drawHierarchy`
/// touches only when WebKit has finished its current paint cycle.
/// In practice the WebView region of every captured snapshot ends
/// up either blank, partial, or showing the page in its previous
/// loaded state.
///
/// The canonical fix is `WKWebView.takeSnapshot(with:completionHandler:)`
/// — an Apple-blessed bridge into the WebContent process that
/// returns the actual rendered IOSurface as a `UIImage`. The catch:
/// it's asynchronous. Our `BitmapCapture` runs synchronously inside
/// a `UIGraphicsImageRenderer` block so it can't `await` the
/// completion.
///
/// **The cycle**
///
///   1. `BitmapCapture` detects every visible WKWebView in the
///      view tree (cheap class-name walk, same machinery as
///      `HardwareLayerCapture`).
///   2. During the current snapshot, BitmapCapture asks this cache
///      for whatever image it has cached for each WebView and
///      composites it at the WebView's root-relative frame. First-
///      time WebViews show the iOS placeholder (gray-ish blank)
///      for ONE capture cycle.
///   3. After the snapshot finishes encoding + uploading,
///      ``SnapshotCapture`` calls `refresh(webView:)` on every
///      detected WebView. Those async snapshots complete on main
///      and update the cache for the NEXT capture cycle.
///
/// This 1-frame-behind staleness is acceptable: snapshots fire
/// every ~1 second (idle) or on screen-change. The lag matches
/// what the reference mobile SDK ships.
///
/// **Storage**
///
/// `NSMapTable.weakToStrong` with WKWebView as the key. WKWebView
/// is a UIView subclass (reference-counted) so the weak key
/// semantics fire when the customer's view controller deallocates
/// — the cached UIImage is then GC'd along with it. No retain
/// cycles. Plays well with embedded-WebView use cases where the
/// customer creates + destroys WebViews dynamically (e.g. a
/// product-detail modal).
///
/// **Thread safety**
///
/// All mutation under `lock`. `cachedImage(for:)` returns a copied
/// reference (UIImage is value-equivalent for our use). `refresh`
/// must be called from main — `WKWebView.takeSnapshot` requires it.
final class WebViewSnapshotCache {

    static let shared = WebViewSnapshotCache()

    #if canImport(UIKit) && canImport(WebKit)
    /// Weak WKWebView keys → strong UIImage values. NSMapTable lets
    /// us configure the key/value retention semantics directly;
    /// Swift's WeakRef wrappers would need a hash on a class type
    /// we don't fully control.
    private let table: NSMapTable<WKWebView, UIImage> = {
        // weakMemory on keys → entries auto-evict when the WebView
        // dealloc'd. strongMemory on values → cached image survives
        // until either explicit removal or the key drops out.
        NSMapTable(keyOptions: [.weakMemory, .objectPointerPersonality],
                   valueOptions: [.strongMemory])
    }()
    private let lock = NSLock()

    /// Fetch the most-recently-snapshotted image for [webView].
    /// Returns nil when we haven't captured this WebView yet —
    /// caller (BitmapCapture) skips compositing for this cycle and
    /// the region falls back to whatever drawHierarchy painted.
    func cachedImage(for webView: WKWebView) -> UIImage? {
        return lock.withLock { table.object(forKey: webView) }
    }

    /// Kick off an async WKWebView snapshot. Must be called from
    /// main thread (WKWebView requirement). Updates the cache when
    /// the snapshot lands; old image stays in place if WebKit
    /// returns an error (so we never go from "have image" → "no
    /// image" because of a transient failure).
    ///
    /// Idempotent — calling refresh() while a prior call is still
    /// in-flight is harmless, the latest completion wins.
    func refresh(_ webView: WKWebView) {
        // Snapshot config — full content area, no rect cropping,
        // afterScreenUpdates: true so we get the latest paint.
        let config = WKSnapshotConfiguration()
        // iOS 13+: capture the FULL scrollable content not just the
        // visible region. We want what the user sees right now,
        // which is bounds — but explicitly setting it documents
        // the choice (and avoids a future iOS default change).
        if #available(iOS 13.0, *) {
            config.rect = webView.bounds
            config.snapshotWidth = NSNumber(value: Double(webView.bounds.width))
        }

        webView.takeSnapshot(with: config) { [weak self, weak webView] image, _ in
            // Discard errors silently — the most common cause is
            // a navigation in-flight. Keep the prior cached image
            // so the next capture cycle still has something to
            // composite.
            guard let self = self,
                  let webView = webView,
                  let image = image else { return }
            self.lock.withLock { self.table.setObject(image, forKey: webView) }
        }
    }

    /// Drop the cached image for [webView]. Called when SDK stop()
    /// runs so we don't carry stale snapshots into the next session.
    func clear(_ webView: WKWebView) {
        lock.withLock { table.removeObject(forKey: webView) }
    }

    /// Wipe all entries — invoked from ``Replay.stop()`` and the
    /// session-rotation path so a new session starts with a clean
    /// WebView snapshot state.
    func clearAll() {
        lock.withLock { table.removeAllObjects() }
    }
    #endif
}
