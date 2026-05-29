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
        // Force opaque=true + an explicit color renderer. Without this
        // UIKit's auto-format heuristic picked grayscale when the
        // initial frame had no vivid pixels, producing 8-bit grayscale
        // PNGs (~17KB) on first launch. Snapshots MUST be RGB so the
        // dashboard renders colour reliably across both platforms.
        format.opaque = true
        if #available(iOS 12.0, *) {
            format.preferredRange = .standard  // sRGB-equivalent
        }
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)

        // Collect privacy-view bounds BEFORE entering the renderer
        // block — keeps the block focused on draw operations. The
        // registry call walks the weak table once.
        //
        // UXCam-parity bulk-privacy semantics:
        //   - occludeAllScreen overrides everything: a single full-
        //     bounds rect → the whole snapshot gets the stripe
        //     overlay so no customer pixels survive.
        //   - Otherwise: per-view marks + bulk class-based matches
        //     (UITextField / UITextView / UILabel) merged into one
        //     list and painted together.
        let privacyRects: [CGRect] = {
            if PrivacyRegistry.shared.occludeAllScreen {
                // Drain pending bridge rects even on full-screen path
                // so they don't carry into the NEXT (non-full-screen)
                // snapshot. Result discarded.
                _ = PrivacyRegistry.shared.consumePendingFrameRects()
                return [view.bounds]
            }
            return PrivacyRegistry.shared.sensitiveBounds(within: view) +
                   PrivacyRegistry.shared.bulkBounds(within: view) +
                   PrivacyRegistry.shared.consumePendingFrameRects()
        }()

        // Hardware-surface plans: MTKView / CAMetalLayer /
        // AVPlayerLayer / CAEAGLLayer / GLKView. Their content is
        // composited outside view.drawHierarchy's reach, so we
        // overlay each one via CALayer.render(in:) after the main
        // paint pass. iOS analog of Android's per-SurfaceView
        // PixelCopy composite.
        let hardwarePlans = HardwareLayerCapture.collect(in: view)

        return renderer.image { ctx in
            if scale != 1 {
                ctx.cgContext.scaleBy(x: scale, y: scale)
            }
            // afterScreenUpdates: true — forces a layout + render
            // pass before snapshot. Costs ~1 frame of UI latency but:
            //   1. Captures Metal/CAMetalLayer/AVPlayer content that
            //      the false path silently misses.
            //   2. Avoids the "empty grayscale capture" failure mode
            //      where snapshots fire before the first paint
            //      completes (observed on first-launch capture
            //      yielding a 17KB grayscale blob).
            // Snapshots are sparse (1 per screen change + idle) so
            // the perf cost is negligible vs the correctness win.
            view.drawHierarchy(in: bounds, afterScreenUpdates: true)

            // Composite hardware surfaces ON TOP of the view-paint
            // result. layer.render(in:) walks layer-private callbacks
            // (different code path from drawHierarchy) so Metal +
            // Video content lands here.
            if !hardwarePlans.isEmpty {
                HardwareLayerCapture.composite(plans: hardwarePlans, into: ctx.cgContext)
            }

            // Paint a diagonal-stripe overlay over each privacy
            // view's bounds. Drawn LAST so it sits on top of the
            // captured pixels AND any hardware-surface composite —
            // sensitive Metal content (e.g. game state with a
            // username overlay) gets occluded properly.
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
