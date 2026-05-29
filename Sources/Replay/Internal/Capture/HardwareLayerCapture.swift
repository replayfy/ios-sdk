import Foundation
#if canImport(UIKit)
import UIKit
import QuartzCore
#if canImport(WebKit)
import WebKit
#endif

/// iOS counterpart of Android's per-SurfaceView PixelCopy composite.
///
/// `UIView.drawHierarchy(in:afterScreenUpdates:)` is the modern Apple
/// snapshot API and handles most views correctly — but it has known
/// blind spots around hardware-composited layers that render OUTSIDE
/// the standard view-paint pipeline:
///
///   • `MTKView` / any `CAMetalLayer`-hosting view — Metal-rendered
///     content (games, GPU visualizers, custom shaders, MapKit
///     internals on modern iOS).
///   • `AVPlayerLayer` — video playback layers (AVKit, AVPlayer-based
///     UIs).
///   • `GLKView` — legacy OpenGL ES (deprecated but still common).
///   • `WKWebView` — web content. Special-cased: a separate
///     ``WebViewSnapshotCache`` keeps the latest async
///     `takeSnapshot(with:)` result per WebView. The composite
///     step paints the cached UIImage instead of calling
///     `layer.render(in:)` (which silently produces blanks for
///     WebContent's IOSurface).
///
/// Strategy:
///   1. Walk the view hierarchy on the main thread (caller already
///      runs there) and collect every hardware-surface view together
///      with its frame in root coordinates.
///   2. After the main `drawHierarchy` pass populates the bitmap,
///      iterate the collected plans and `layer.render(in:)` each one
///      into the same CGContext at its root-relative frame. For Metal
///      and Video layers, `CALayer.render(in:)` walks the layer-
///      private rendering callbacks that Core Animation maintains —
///      different code path from `view.drawHierarchy` which only
///      hits view-level paint methods.
///
/// `CALayer.render(in:)` is not a perfect Metal capture on every iOS
/// version — Apple's reference implementation skips
/// hardware-accelerated layer contents in some build configurations.
/// When it returns empty pixels the region stays as `drawHierarchy`
/// left it (transparent), same fallback behavior as Android's
/// per-SurfaceView path when the secondary PixelCopy fails.
///
/// Mirrors the Android SDK's
/// `PixelCopyCapturePipeline.captureSurfaceViewsAndComposite`.
enum HardwareLayerCapture {

    /// Window-relative bounds of one hardware-surface view to overlay
    /// on the main bitmap. Captured on main BEFORE any background
    /// work — view metrics aren't safe to read off-main.
    struct LayerPlan {
        let view: UIView
        let frameInRoot: CGRect
    }

    /// Walk [root]'s subtree depth-first. Returns one [LayerPlan] per
    /// visible non-zero hardware-surface view, with frame converted
    /// to root coordinates so the composite step can place it
    /// directly into the same CGContext that drew the main view
    /// hierarchy.
    static func collect(in root: UIView) -> [LayerPlan] {
        var out: [LayerPlan] = []
        walk(root, root: root, out: &out)
        return out
    }

    private static func walk(_ view: UIView, root: UIView, out: inout [LayerPlan]) {
        guard !view.isHidden,
              view.alpha > 0.01,
              view.bounds.width > 0,
              view.bounds.height > 0 else { return }
        if isHardwareSurface(view) {
            let frame = view.convert(view.bounds, to: root)
            out.append(LayerPlan(view: view, frameInRoot: frame))
            // Don't recurse into hardware-surface views — their
            // content is opaque (rendered to the GPU) and any
            // UIKit subviews layered on top would be drawn by
            // drawHierarchy's main pass anyway.
            return
        }
        for sub in view.subviews {
            walk(sub, root: root, out: &out)
        }
    }

    /// Returns true when [view] hosts content rendered outside the
    /// regular view-paint pipeline that `drawHierarchy` may miss.
    /// Uses class-name string comparison for MTKView / GLKView /
    /// AVPlayerLayer so we don't have to link MetalKit / GLKit /
    /// AVKit (keeps the SDK's binary surface small + transitive
    /// dependency-free).
    private static func isHardwareSurface(_ view: UIView) -> Bool {
        #if canImport(WebKit)
        // WKWebView is a hardware-surface in our sense: its
        // content lives in a separate process and drawHierarchy
        // doesn't capture it reliably. composite() routes it to
        // the WebViewSnapshotCache path rather than layer.render(in:).
        if view is WKWebView { return true }
        #endif
        let className = String(describing: type(of: view))
        if className == "MTKView" || className == "GLKView" { return true }
        // Layer-based detection — covers custom UIView subclasses
        // whose +layerClass is CAMetalLayer / AVPlayerLayer / etc.
        let layerName = String(describing: type(of: view.layer))
        if layerName == "CAMetalLayer" { return true }
        if layerName == "AVPlayerLayer" { return true }
        // CAEAGLLayer = legacy OpenGL ES backing layer.
        if layerName == "CAEAGLLayer" { return true }
        return false
    }

    /// Composite each plan's layer content into [ctx] at its
    /// root-relative frame. Caller MUST have already applied any
    /// scale transform to [ctx] before invoking this — we paint in
    /// root-pixel coords expecting the context to already map them
    /// to bitmap pixels.
    ///
    /// Pure side-effect: returns nothing, mutates the context.
    static func composite(plans: [LayerPlan], into ctx: CGContext) {
        for plan in plans {
            ctx.saveGState()
            ctx.translateBy(x: plan.frameInRoot.origin.x,
                            y: plan.frameInRoot.origin.y)
            #if canImport(WebKit)
            if let webView = plan.view as? WKWebView {
                // WKWebView path: use the cached snapshot from the
                // PRIOR async takeSnapshot(with:). One-frame-behind
                // staleness vs the rest of the capture — acceptable
                // since pages don't change between consecutive
                // snapshots (1s+ apart) often enough to matter, and
                // capture is correctness-critical here vs
                // layer.render's blanks.
                if let cached = WebViewSnapshotCache.shared.cachedImage(for: webView),
                   let cg = cached.cgImage {
                    // UIImage's coordinate system is flipped vs
                    // CGContext's so we have to invert Y when
                    // drawing via cgImage. UIGraphicsImageRenderer's
                    // context already accounts for this when
                    // `UIImage.draw(at:)` is used, but we have the
                    // raw CGContext here.
                    let rect = CGRect(origin: .zero, size: plan.frameInRoot.size)
                    ctx.saveGState()
                    ctx.translateBy(x: 0, y: rect.height)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(cg, in: rect)
                    ctx.restoreGState()
                }
                // If no cached image yet (first time this WebView
                // appears) the region stays as drawHierarchy left
                // it — blank or partial. Next snapshot picks it up
                // once SnapshotCapture's refresh pass fires.
                ctx.restoreGState()
                continue
            }
            #endif
            // `render(in:)` walks the layer's own draw callbacks —
            // different from `view.drawHierarchy` which calls
            // -drawRect: on each view. For CAMetalLayer / AVPlayerLayer
            // the layer-callback path is what actually has access to
            // the hardware-rendered content.
            plan.view.layer.render(in: ctx)
            ctx.restoreGState()
        }
    }

    #if canImport(WebKit)
    /// Kick off async snapshots for every WebView in [plans]. Called
    /// AFTER the main capture lands so the refreshed image is ready
    /// for the next snapshot cycle.
    static func refreshWebViews(plans: [LayerPlan]) {
        for plan in plans {
            if let webView = plan.view as? WKWebView {
                WebViewSnapshotCache.shared.refresh(webView)
            }
        }
    }
    #endif
}
#endif
