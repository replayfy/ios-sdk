#if canImport(UIKit)
import UIKit
import CoreImage

/// Periodic screenshot capture → frames archive upload.
///
/// Mirrors the reference capture path: a timer fires at `1/fps`,
/// renders the key window via `drawHierarchy` at a reduced scale,
/// JPEG-compresses it, accumulates frames, and uploads a gzipped
/// frames archive once `batchSize` frames have been collected.
final class MobileScreenshots {
    private let transport: MobileTransport
    private let privacy: () -> [MaskRect] // sensitive rects + style, window coords

    private var timer: Timer?
    private let lock = NSLock()
    private var pending: [(data: Data, ts: UInt64)] = []

    // Server-tunable via setSettings.
    private var captureInterval: TimeInterval = 1.0 / 3.0 // 3 fps default
    private var jpegQuality: CGFloat = 0.5
    private let screenScale: CGFloat = 1.25
    private let batchSize = 20
    private let maxBuffered = 500

    init(transport: MobileTransport, privacyRects: @escaping () -> [MaskRect]) {
        self.transport = transport
        self.privacy = privacyRects
    }

    func setSettings(fps: Int, quality: String) {
        let f = min(max(fps, 1), 30)
        captureInterval = 1.0 / Double(f)
        switch quality.lowercased() {
        case "low": jpegQuality = 0.4
        case "high": jpegQuality = 0.6
        default: jpegQuality = 0.5
        }
    }

    func start() {
        DispatchQueue.main.async {
            self.capture()
            self.timer = Timer.scheduledTimer(withTimeInterval: self.captureInterval, repeats: true) { [weak self] _ in
                self?.capture()
            }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        flush()
    }

    /// Suspend capture while backgrounded — shooting an invisible window
    /// just inflates the archive. Flushes what's pending.
    func pause() {
        DispatchQueue.main.async {
            self.timer?.invalidate(); self.timer = nil
            self.flush()
        }
    }

    /// Resume capture on return to the foreground.
    func resume() {
        DispatchQueue.main.async {
            guard self.timer == nil else { return }
            self.capture()
            self.timer = Timer.scheduledTimer(withTimeInterval: self.captureInterval, repeats: true) { [weak self] _ in
                self?.capture()
            }
        }
    }

    private func capture() {
        autoreleasepool {
            guard let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) else { return }
            let size = window.bounds.size
            guard size.width > 0, size.height > 0 else { return }

            UIGraphicsBeginImageContextWithOptions(size, false, screenScale)
            defer { UIGraphicsEndImageContext() }
            guard let ctx = UIGraphicsGetCurrentContext() else { return }
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)

            // Mask sensitive regions per their style — `.blur` Gaussian-blurs
            // the underlying pixels, `.overlay` paints a solid box. Grab the
            // clean render once so every blur samples the real pixels, not a
            // region we already masked this pass.
            let rects = privacy()
            if !rects.isEmpty,
               let rendered = UIGraphicsGetImageFromCurrentImageContext()?.cgImage {
                maskRegions(rects, from: rendered, in: ctx)
            }

            guard let image = UIGraphicsGetImageFromCurrentImageContext(),
                  let jpeg = image.jpegData(compressionQuality: jpegQuality) else { return }

            lock.lock()
            pending.append((jpeg, nowMs()))
            if pending.count > maxBuffered { pending.removeFirst(pending.count - maxBuffered) }
            let ready = pending.count >= batchSize
            lock.unlock()
            if ready { flush() }
        }
    }

    // ── Privacy masking ──────────────────────────────────────────────
    private static let ciContext = CIContext(options: nil)

    /// Render each sensitive rect per its style (window/point coords):
    ///   • `.blur`     — Gaussian-blur the underlying pixels (configurable
    ///     radius). The rendered source is in pixel coords, so scale the rect
    ///     by screenScale to sample the right region.
    ///   • `.overlay`  — paint a solid box; no source pixel survives. Cleaner
    ///     than the old stripe texture on screens full of fields.
    ///   • `.pixelate` — reduce the region to coarse mosaic blocks via
    ///     `CIPixellate`. Same crop-the-clean-source path as `.blur`.
    private func maskRegions(_ rects: [MaskRect], from rendered: CGImage, in ctx: CGContext) {
        let radius = CGFloat(PrivacyRegistry.shared.blurRadius)
        let overlayColor = UIColor(white: 0.22, alpha: 1.0)
        for item in rects {
            let frame = item.rect
            guard frame.width > 0, frame.height > 0 else { continue }
            switch item.style {
            case .overlay:
                ctx.saveGState()
                overlayColor.setFill()
                ctx.fill(frame)
                ctx.restoreGState()
            case .blur, .pixelate:
                let cropFrame = CGRect(
                    x: frame.origin.x * screenScale,
                    y: frame.origin.y * screenScale,
                    width: frame.size.width * screenScale,
                    height: frame.size.height * screenScale
                )
                guard let region = rendered.cropping(to: cropFrame) else { continue }
                let masked = item.style == .pixelate
                    ? pixelatedRegion(region, blockSize: max(8, radius * 2))
                    : blurredRegion(region, radius: radius)
                guard let masked else { continue }
                masked.draw(in: frame)
            }
        }
    }

    private func blurredRegion(_ cgImage: CGImage, radius: CGFloat) -> UIImage? {
        let ciImage = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage,
              let cg = MobileScreenshots.ciContext.createCGImage(
                output, from: ciImage.extent)
        else { return nil }
        return UIImage(cgImage: cg, scale: screenScale, orientation: .up)
    }

    /// Coarse-mosaic a region via `CIPixellate`. `blockSize` is in source
    /// (pixel) units; clamp the output to the input extent so the filter's
    /// edge bleed doesn't shift the drawn region. Falls back to a solid box
    /// if the filter is unavailable — never leave pixels exposed.
    private func pixelatedRegion(_ cgImage: CGImage, blockSize: CGFloat) -> UIImage? {
        let ciImage = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIPixellate") else {
            return solidRegion(size: ciImage.extent.size)
        }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(blockSize, forKey: kCIInputScaleKey)
        filter.setValue(
            CIVector(x: ciImage.extent.midX, y: ciImage.extent.midY),
            forKey: kCIInputCenterKey)
        guard let output = filter.outputImage,
              let cg = MobileScreenshots.ciContext.createCGImage(
                output, from: ciImage.extent)
        else { return solidRegion(size: ciImage.extent.size) }
        return UIImage(cgImage: cg, scale: screenScale, orientation: .up)
    }

    private func solidRegion(size: CGSize) -> UIImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor(white: 0.22, alpha: 1.0).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    func flush() {
        lock.lock()
        guard !pending.isEmpty else { lock.unlock(); return }
        let frames = pending
        pending.removeAll()
        lock.unlock()

        guard let archive = MobileFrames.archive(frames) else { return }
        transport.sendImages(archive) { [weak self] success in
            if !success {
                self?.lock.lock()
                self?.pending.insert(contentsOf: frames, at: 0)
                self?.lock.unlock()
            }
        }
    }
}
#endif
