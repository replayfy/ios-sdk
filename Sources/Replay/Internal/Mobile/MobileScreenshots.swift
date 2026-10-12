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
    private let transport: MobileUploading
    private let privacy: () -> [MaskRect] // sensitive rects + style, window coords
    /// Whether this engine screenshots the window itself. False for hosts that
    /// push their own frames through `submitFrame` (Flutter's Dart-side
    /// capture): the capture timer must then never run, including on resume.
    private let nativeCapture: Bool

    private var timer: Timer?
    private let lock = NSLock()
    private var pending: [(data: Data, ts: UInt64)] = []
    // Upload drain state, guarded by `lock`. One drain runs at a time so
    // archives reach the server in capture order.
    private var draining = false
    /// Frames captured at or before this time go out even as a partial batch
    /// (a pause, resume or stop asked for everything up to that moment);
    /// later frames wait for a full batch. 0 = full batches only.
    private var flushThroughTs: UInt64 = 0
    private var roundsLeft = 0
    /// A flush arrived while a round was in flight. If that round fails, the
    /// request still gets its own attempt (a resume right after suspension,
    /// whose stale in-flight upload then fails, must not be lost).
    private var requestedDuringRound = false
    private var drainWaiters: [() -> Void] = []
    /// stop() or discard() ran: the capture timer must never start again.
    private var stopped = false
    /// discard() ran: drop everything and send nothing more.
    private var discarded = false

    // Server-tunable via setSettings.
    private var captureInterval: TimeInterval = 1.0 / 3.0 // 3 fps default
    private var jpegQuality: CGFloat = 0.5
    private let screenScale: CGFloat = 1.25
    private let batchSize = 20
    private let maxBuffered = 500
    /// Archives one drain may send. Bounds a drain whose buffer refills as fast
    /// as it uploads, so it (and a background task waiting on it) still ends.
    private let maxDrainRounds = 30

    init(transport: MobileUploading, nativeCapture: Bool, privacyRects: @escaping () -> [MaskRect]) {
        self.transport = transport
        self.nativeCapture = nativeCapture
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
            guard !self.isStopped else { return }
            self.capture()
            self.timer = Timer.scheduledTimer(withTimeInterval: self.captureInterval, repeats: true) { [weak self] _ in
                self?.capture()
            }
        }
    }

    /// Session end: stop capturing and upload everything buffered.
    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        timer?.invalidate(); timer = nil
        flush(all: true)
    }

    /// Drop pending frames WITHOUT uploading — the cancelSession counterpart to
    /// stop() (which flushes). Invalidate synchronously when already on main so
    /// no capture fires between here and teardown.
    /// The buffer is cleared at once, under the lock, so a running drain
    /// stops before its next round even when this is called off the main
    /// thread.
    func discard() {
        lock.lock()
        stopped = true
        discarded = true
        pending.removeAll()
        lock.unlock()
        let clear = { self.timer?.invalidate(); self.timer = nil }
        if Thread.isMainThread { clear() } else { DispatchQueue.main.async(execute: clear) }
    }

    /// Suspend capture (backgrounding, or an excluded screen) and upload
    /// everything buffered — shooting an invisible window just inflates the
    /// archive. Never discards: frames that fail to send (suspension cancels
    /// in-flight requests) stay queued and go out on `resume()`. `completion`
    /// runs once the uploads settle, so the caller can hold a background task
    /// open until then.
    func pause(completion: (() -> Void)? = nil) {
        DispatchQueue.main.async {
            self.timer?.invalidate(); self.timer = nil
            self.flush(all: true, completion: completion)
        }
    }

    /// Resume after `pause()`. First push whatever the pause could not get
    /// out before suspension; then restart the capture timer, but only when
    /// this engine screenshots natively. Host-fed capture (Flutter) never
    /// starts the timer — restarting it here began native screenshots after
    /// the first background, without the host's occlusion rects.
    func resume() {
        flush(all: true)
        guard nativeCapture else { return }
        DispatchQueue.main.async {
            // A stop() between the resume and this block must win.
            guard !self.isStopped, self.timer == nil else { return }
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
                maskRegions(rects, from: rendered, in: ctx, scale: screenScale)
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
    /// `scale` is the pixels-per-point of `rendered` relative to `ctx`'s
    /// coordinate space: `screenScale` for the native drawHierarchy capture,
    /// `1.0` for a Dart-supplied PNG (Flutter), where the rects already arrive
    /// in the PNG's pixel coordinates.
    private func maskRegions(_ rects: [MaskRect], from rendered: CGImage, in ctx: CGContext, scale: CGFloat) {
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
                    x: frame.origin.x * scale,
                    y: frame.origin.y * scale,
                    width: frame.size.width * scale,
                    height: frame.size.height * scale
                )
                guard let region = rendered.cropping(to: cropFrame) else { continue }
                let masked = item.style == .pixelate
                    ? pixelatedRegion(region, blockSize: max(8, radius * 2), scale: scale)
                    : blurredRegion(region, radius: radius, scale: scale)
                guard let masked else { continue }
                masked.draw(in: frame)
            }
        }
    }

    /// Ingest a host-captured frame (Flutter Dart-side `RepaintBoundary.toImage`):
    /// the native PixelCopy/drawHierarchy can't read Flutter's surface, so the
    /// Dart layer ships a PNG + occlusion rects (in PNG-pixel coords) per frame —
    /// the rects arrive *with* the frame, so there's no poll/lag. We mask + JPEG
    /// + enqueue on the same path as `capture()`. Used when native capture is off.
    func submitFrame(_ png: Data, rects: [MaskRect]) {
        autoreleasepool {
            guard let image = UIImage(data: png) else { return }
            let size = image.size // PNG decodes at scale 1.0 → size is in pixels
            guard size.width > 0, size.height > 0 else { return }
            UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
            defer { UIGraphicsEndImageContext() }
            image.draw(in: CGRect(origin: .zero, size: size))
            if !rects.isEmpty,
               let ctx = UIGraphicsGetCurrentContext(),
               let rendered = UIGraphicsGetImageFromCurrentImageContext()?.cgImage {
                maskRegions(rects, from: rendered, in: ctx, scale: 1.0)
            }
            guard let out = UIGraphicsGetImageFromCurrentImageContext(),
                  let jpeg = out.jpegData(compressionQuality: jpegQuality) else { return }
            lock.lock()
            pending.append((jpeg, nowMs()))
            if pending.count > maxBuffered { pending.removeFirst(pending.count - maxBuffered) }
            let ready = pending.count >= batchSize
            lock.unlock()
            if ready { flush() }
        }
    }

    private func blurredRegion(_ cgImage: CGImage, radius: CGFloat, scale: CGFloat) -> UIImage? {
        let ciImage = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage,
              let cg = MobileScreenshots.ciContext.createCGImage(
                output, from: ciImage.extent)
        else { return nil }
        return UIImage(cgImage: cg, scale: scale, orientation: .up)
    }

    /// Coarse-mosaic a region via `CIPixellate`. `blockSize` is in source
    /// (pixel) units; clamp the output to the input extent so the filter's
    /// edge bleed doesn't shift the drawn region. Falls back to a solid box
    /// if the filter is unavailable — never leave pixels exposed.
    private func pixelatedRegion(_ cgImage: CGImage, blockSize: CGFloat, scale: CGFloat) -> UIImage? {
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
        return UIImage(cgImage: cg, scale: scale, orientation: .up)
    }

    private func solidRegion(size: CGSize) -> UIImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor(white: 0.22, alpha: 1.0).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// Upload buffered frames oldest first, one archive of at most `batchSize`
    /// frames per request. `all: false` (a batch just filled) sends full
    /// batches only. `all: true` (pause, resume, stop) also sends a partial
    /// batch of the frames captured up to now; frames captured afterwards
    /// keep filling a batch. A failed upload puts its frames back at the front
    /// and ends the drain, so nothing is dropped and a retry can't spin.
    /// `completion` runs once the drain settles.
    func flush(all: Bool = false, completion: (() -> Void)? = nil) {
        lock.lock()
        if discarded {
            lock.unlock()
            completion?()
            return
        }
        if all {
            flushThroughTs = max(flushThroughTs, nowMs())
            roundsLeft = maxDrainRounds
        }
        if let completion { drainWaiters.append(completion) }
        if draining {
            // The running drain picks up the new frames, the wider scope and
            // the waiter. A pause/resume/stop request also earns its own
            // attempt if the in-flight round fails.
            if all { requestedDuringRound = true }
            lock.unlock()
            return
        }
        draining = true
        if !all { roundsLeft = maxDrainRounds }
        lock.unlock()
        drainNext()
    }

    /// One drain round. The upload callback holds `self` strongly on purpose:
    /// `ReplayCore.stop()` releases this object right after `stop()`, and the
    /// drain must still finish sending the session's last frames.
    private func drainNext() {
        lock.lock()
        let forced = pending.first.map { $0.ts <= flushThroughTs } ?? false
        guard !discarded, roundsLeft > 0, !pending.isEmpty, forced || pending.count >= batchSize else {
            finishDrainLocked()
            return
        }
        roundsLeft -= 1
        requestedDuringRound = false
        let frames = Array(pending.prefix(batchSize))
        pending.removeFirst(frames.count)
        lock.unlock()

        guard let archive = MobileFrames.archive(frames) else {
            // Compression failed: skip this batch rather than retry it forever.
            drainNext()
            return
        }
        transport.sendImages(archive) { success in
            if success {
                self.drainNext()
                return
            }
            self.lock.lock()
            guard !self.discarded else {
                self.finishDrainLocked()
                return
            }
            self.pending.insert(contentsOf: frames, at: 0)
            if self.pending.count > self.maxBuffered {
                self.pending.removeFirst(self.pending.count - self.maxBuffered)
            }
            if self.requestedDuringRound {
                // Someone asked for a flush while this upload was in flight:
                // give that request its own attempt.
                self.lock.unlock()
                self.drainNext()
                return
            }
            self.finishDrainLocked()
        }
    }

    /// Ends the drain and runs its waiters. Call with `lock` held; releases it.
    private func finishDrainLocked() {
        let waiters = drainWaiters
        drainWaiters.removeAll()
        draining = false
        flushThroughTs = 0
        roundsLeft = 0
        requestedDuringRound = false
        lock.unlock()
        waiters.forEach { $0() }
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    /// Frames waiting to upload. For tests.
    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }

    /// Whether the native capture timer is running. For tests.
    var isCapturing: Bool { timer != nil }

    /// Whether an upload drain is running. For tests.
    var isDraining: Bool {
        lock.lock(); defer { lock.unlock() }
        return draining
    }
}
#endif
