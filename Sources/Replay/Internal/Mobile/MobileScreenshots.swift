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
    private let privacy: () -> [CGRect] // sensitive rects in window coords

    private var timer: Timer?
    private let lock = NSLock()
    private var pending: [(data: Data, ts: UInt64)] = []

    // Server-tunable via setSettings.
    private var captureInterval: TimeInterval = 1.0 / 3.0 // 3 fps default
    private var jpegQuality: CGFloat = 0.5
    private let screenScale: CGFloat = 1.25
    private let batchSize = 20
    private let maxBuffered = 500

    init(transport: MobileTransport, privacyRects: @escaping () -> [CGRect]) {
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

            // Mask sensitive regions the reference way: blur the underlying
            // content, then overlay diagonal stripes (Android's capture
            // pipeline paints the matching stripe pattern). Grab the clean
            // render once so every region blurs the real pixels, not a
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

    /// Blur + diagonal-stripe overlay for each sensitive rect (window/point
    /// coords). Mirrors the reference's iOS privacy render. The rendered
    /// source is in pixel coords, so scale the rect by screenScale to sample
    /// the right region.
    private func maskRegions(_ rects: [CGRect], from rendered: CGImage, in ctx: CGContext) {
        let stripeWidth: CGFloat = 5.0
        let stripeSpacing: CGFloat = 15.0
        let stripeColor = UIColor.gray.withAlphaComponent(0.7)
        for frame in rects {
            let cropFrame = CGRect(
                x: frame.origin.x * screenScale,
                y: frame.origin.y * screenScale,
                width: frame.size.width * screenScale,
                height: frame.size.height * screenScale
            )
            guard let region = rendered.cropping(to: cropFrame),
                  let blurred = blurredRegion(region) else { continue }
            blurred.draw(in: frame)

            ctx.saveGState()
            UIRectClip(frame)
            let totalHeight = frame.size.height
            for x in stride(from: -totalHeight, to: frame.size.width,
                            by: stripeSpacing + stripeWidth) {
                ctx.move(to: CGPoint(x: x + frame.minX, y: frame.minY))
                ctx.addLine(to: CGPoint(x: x + totalHeight + frame.minX,
                                        y: totalHeight + frame.minY))
            }
            ctx.setLineWidth(stripeWidth)
            stripeColor.setStroke()
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    private func blurredRegion(_ cgImage: CGImage) -> UIImage? {
        let ciImage = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(2.5, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage,
              let cg = MobileScreenshots.ciContext.createCGImage(
                output, from: ciImage.extent)
        else { return nil }
        return UIImage(cgImage: cg, scale: screenScale, orientation: .up)
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
