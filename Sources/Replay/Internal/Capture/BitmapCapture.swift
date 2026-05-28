import Foundation
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

/// Best-effort whole-screen bitmap capture.
///
/// Uses ``UIView.drawHierarchy(in:afterScreenUpdates:)`` — the
/// modern Apple API for snapshotting a rendered view. Same call
/// the OS uses for share-sheet thumbnails, AirDrop previews, etc.
/// Handles SwiftUI host views, hardware-accelerated layers, video
/// content, WKWebView — all out of the box (UXCam doesn't have to
/// composite SurfaceViews separately the way Android does).
///
/// Sync, main-thread. Encode + hash happen on background dispatch
/// off the captured UIImage's pixel bytes.
///
/// Mirrors Android's `BitmapCapture.kt` so the dashboard treats
/// both platforms' image bytes identically.
enum BitmapCapture {

    /// Cap on the longest edge. Above this we downsample at capture
    /// time so PNG-encode + upload stays bounded.
    private static let maxDimension: CGFloat = 1024

    #if canImport(UIKit)
    /// Capture the view's rendered contents as a UIImage. Returns
    /// nil on failure (zero-size view, OOM, view marked as secure).
    static func capture(_ view: UIView) -> UIImage? {
        let bounds = view.bounds
        if bounds.width <= 0 || bounds.height <= 0 { return nil }

        // Compute the downsample factor.
        let scale = downsampleScale(for: bounds.size)
        let targetSize = CGSize(
            width: bounds.width * scale,
            height: bounds.height * scale
        )

        // UIGraphicsImageRenderer manages bitmap context + memory
        // automatically. We use UIScreen.main.scale × downsample so
        // the rendered image is at device-pixel density (matches
        // ViewTreeSerializer's pixel bounds for clean overlay).
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = view.window?.screen.scale ?? UIScreen.main.scale
        format.opaque = view.isOpaque
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)

        // Collect privacy-view bounds BEFORE entering the renderer
        // block — keeps the block focused on draw operations. The
        // registry call walks the weak table once.
        let privacyRects = PrivacyRegistry.shared.sensitiveBounds(within: view)

        return renderer.image { ctx in
            if scale != 1 {
                ctx.cgContext.scaleBy(x: scale, y: scale)
            }
            // afterScreenUpdates: false — capture the current frame.
            // Setting it to true triggers a layout + render pass on
            // every call which causes frame drops on the UI.
            view.drawHierarchy(in: bounds, afterScreenUpdates: false)

            // Paint a noise-pattern overlay over each privacy view's
            // bounds. Drawn AFTER drawHierarchy so it sits on top of
            // the captured pixels, AND only present in the saved
            // bitmap — never visible on the user's screen.
            if !privacyRects.isEmpty {
                paintPrivacyOverlay(rects: privacyRects, in: ctx.cgContext)
            }
        }
    }

    /// Diagonal-stripe pattern over privacy regions. Cheaper than a
    /// real noise pattern (no per-pixel cost) and visually obvious
    /// in playback — viewers immediately recognise the "this region
    /// was hidden" signal.
    private static func paintPrivacyOverlay(rects: [CGRect], in ctx: CGContext) {
        for rect in rects {
            // Solid dark base so any pixel that leaked through
            // drawHierarchy is overwritten.
            ctx.setFillColor(UIColor(white: 0.15, alpha: 1.0).cgColor)
            ctx.fill(rect)

            // Diagonal stripes at 45° spaced 8pt apart. Clip to the
            // rect so strokes don't bleed.
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.setStrokeColor(UIColor(white: 0.35, alpha: 1.0).cgColor)
            ctx.setLineWidth(2)
            let spacing: CGFloat = 8
            let diag = rect.width + rect.height
            var x = rect.minX - rect.height
            while x < rect.minX + diag {
                ctx.move(to: CGPoint(x: x, y: rect.minY))
                ctx.addLine(to: CGPoint(x: x + rect.height, y: rect.maxY))
                ctx.strokePath()
                x += spacing
            }
            ctx.restoreGState()
        }
    }

    /// Encode the image to PNG bytes + compute SHA-256 hash.
    static func encodeAndHash(_ image: UIImage) -> EncodedAsset? {
        guard let bytes = image.pngData() else { return nil }
        let digest = SHA256.hash(data: bytes)
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return EncodedAsset(bytes: bytes, hash: hash, contentType: "image/png")
    }

    private static func downsampleScale(for size: CGSize) -> CGFloat {
        let longest = max(size.width, size.height)
        if longest <= maxDimension { return 1 }
        return maxDimension / longest
    }
    #endif

    /// Output of `encodeAndHash` — wire-ready bytes + content-addressed
    /// hash + MIME for the asset upload endpoint.
    ///
    /// Declared OUTSIDE the UIKit guard because it carries no
    /// UIKit-dependent types — Data + String. The AssetUploader
    /// references it from non-UIKit-guarded code so it must compile
    /// on the macOS validation build too.
    struct EncodedAsset {
        let bytes: Data
        let hash: String
        let contentType: String
    }
}
