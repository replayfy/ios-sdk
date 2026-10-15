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
    /// Runs before each native capture and calls back on the main thread
    /// once the frame's masks can be resolved (the password inputs inside
    /// web views are looked up asynchronously). Immediate by default.
    private let prepareFrame: (@escaping () -> Void) -> Void
    /// Whether this engine screenshots the window itself. False for hosts that
    /// push their own frames through `submitFrame` (Flutter's Dart-side
    /// capture): the capture timer must then never run, including on resume.
    private let nativeCapture: Bool

    private var timer: Timer?
    /// A native capture is waiting for its masks (main thread only). The
    /// next timer tick is skipped rather than queued behind it.
    private var preparing = false
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

    init(transport: MobileUploading, nativeCapture: Bool,
         privacyRects: @escaping () -> [MaskRect],
         prepareFrame: @escaping (@escaping () -> Void) -> Void = { $0() }) {
        self.transport = transport
        self.nativeCapture = nativeCapture
        self.privacy = privacyRects
        self.prepareFrame = prepareFrame
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
            // The timer first: a capture waiting for its masks checks it is
            // still running before it shoots.
            self.timer = Timer.scheduledTimer(withTimeInterval: self.captureInterval, repeats: true) { [weak self] _ in
                self?.capture()
            }
            self.capture()
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
            self.timer = Timer.scheduledTimer(withTimeInterval: self.captureInterval, repeats: true) { [weak self] _ in
                self?.capture()
            }
            self.capture()
        }
    }

    /// One timer tick: resolve what the frame must mask, then shoot it —
    /// unless pause(), stop() or discard() ran in the meantime.
    private func capture() {
        guard !preparing else { return }
        preparing = true
        prepareFrame { [weak self] in
            guard let self else { return }
            self.preparing = false
            guard !self.isStopped, self.timer != nil else { return }
            self.captureNow()
        }
    }

    private func captureNow() {
        autoreleasepool {
            guard let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) else { return }
            let size = window.bounds.size
            guard size.width > 0, size.height > 0 else { return }

            UIGraphicsBeginImageContextWithOptions(size, false, screenScale)
            defer { UIGraphicsEndImageContext() }
            guard let ctx = UIGraphicsGetCurrentContext() else { return }
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)

            // Mask sensitive regions per their style — `.overlay` paints a
            // solid box, `.blur` Gaussian-blurs the underlying pixels. Grab
            // the clean render once so every blur samples the real pixels,
            // not a region we already masked this pass. A frame that can't be
            // masked is not kept.
            let rects = privacy()
            if !rects.isEmpty {
                guard let rendered = UIGraphicsGetImageFromCurrentImageContext()?.cgImage else { return }
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
    /// The solid fill of `.overlay` regions, and of any region that could
    /// not be blurred or pixelated.
    static let overlayColor = UIColor(white: 0.22, alpha: 1.0)

    /// Render each sensitive rect per its style (window/point coords):
    ///   • `.overlay`  — paint a solid box; no source pixel survives. The
    ///     default, as in both reference trackers.
    ///   • `.blur`     — Gaussian-blur the underlying pixels (configurable
    ///     radius). The rendered source is in pixel coords, so scale the rect
    ///     by screenScale to sample the right region.
    ///   • `.pixelate` — reduce the region to coarse mosaic blocks via
    ///     `CIPixellate`. Same crop-the-clean-source path as `.blur`.
    /// `scale` is the pixels-per-point of `rendered` relative to `ctx`'s
    /// coordinate space: `screenScale` for the native drawHierarchy capture,
    /// `1.0` for a Dart-supplied PNG (Flutter), where the rects already arrive
    /// in the PNG's pixel coordinates.
    ///
    /// Each rect is first clipped to the image, and a blurred or pixelated
    /// region is drawn back exactly where its pixels were cropped from. When
    /// the filter fails the region is painted solid instead.
    /// `render` stands in for the blur/pixelate filters in tests.
    func maskRegions(_ rects: [MaskRect], from rendered: CGImage, in ctx: CGContext, scale: CGFloat,
                     render: ((CGImage, ReplayMaskStyle) -> UIImage?)? = nil) {
        let radius = CGFloat(PrivacyRegistry.shared.blurRadius)
        let imageRect = CGRect(x: 0, y: 0,
                               width: CGFloat(rendered.width) / scale,
                               height: CGFloat(rendered.height) / scale)
        let filter = render ?? { region, style in
            style == .pixelate
                ? self.pixelatedRegion(region, blockSize: max(8, radius * 2), scale: scale)
                : self.blurredRegion(region, radius: radius, scale: scale)
        }
        for item in rects {
            let frame = item.rect.intersection(imageRect)
            // Entirely outside the image: there are no pixels to cover.
            guard !frame.isNull, frame.width > 0, frame.height > 0 else { continue }
            switch item.style {
            case .overlay:
                // Every pixel the box touches: one it only partly covered
                // would show a blend of what it hides (a 390 pt window at
                // 1.25 is 487.5 px).
                fill(Self.outwardToPixels(frame, scale: scale), in: ctx)
            case .blur, .pixelate:
                // Crop whole pixels, and draw the result back over exactly
                // those pixels, so nothing is stretched or shifted.
                let crop = CGRect(x: frame.minX * scale, y: frame.minY * scale,
                                  width: frame.width * scale, height: frame.height * scale).integral
                let drawFrame = CGRect(x: crop.minX / scale, y: crop.minY / scale,
                                       width: crop.width / scale, height: crop.height / scale)
                let masked = rendered.cropping(to: crop).flatMap { filter($0, item.style) }
                guard let masked else {
                    // Fail closed, like the reference tracker: never leave a
                    // sensitive region uncovered.
                    fill(drawFrame, in: ctx)
                    continue
                }
                masked.draw(in: drawFrame)
            }
        }
    }

    /// `rect` (points) grown to whole pixels of an image `scale` pixels per
    /// point.
    static func outwardToPixels(_ rect: CGRect, scale: CGFloat) -> CGRect {
        let px = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                        width: rect.width * scale, height: rect.height * scale).integral
        return CGRect(x: px.minX / scale, y: px.minY / scale,
                      width: px.width / scale, height: px.height / scale)
    }

    private func fill(_ rect: CGRect, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setFillColor(Self.overlayColor.cgColor)
        ctx.fill(rect)
        ctx.restoreGState()
    }

    /// Ingest a host-captured frame (Flutter Dart-side `RepaintBoundary.toImage`):
    /// the native PixelCopy/drawHierarchy can't read Flutter's surface, so the
    /// Dart layer ships a PNG + occlusion rects (in PNG-pixel coords) per frame —
    /// the rects arrive *with* the frame, so there's no poll/lag. We mask + JPEG
    /// + enqueue on the same path as `capture()`. Used when native capture is off.
    /// `occludeAll` (the app's `occludeSensitiveScreen`) replaces the host's
    /// rects with one solid box over the whole frame.
    func submitFrame(_ png: Data, rects: [MaskRect], occludeAll: Bool = false) {
        autoreleasepool {
            guard let image = UIImage(data: png) else { return }
            let size = image.size // PNG decodes at scale 1.0 → size is in pixels
            guard size.width > 0, size.height > 0 else { return }
            let rects = occludeAll ? [MaskRect(rect: CGRect(origin: .zero, size: size), style: .overlay)] : rects
            UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
            defer { UIGraphicsEndImageContext() }
            image.draw(in: CGRect(origin: .zero, size: size))
            if !rects.isEmpty {
                // A frame that can't be masked is not kept.
                guard let ctx = UIGraphicsGetCurrentContext(),
                      let rendered = UIGraphicsGetImageFromCurrentImageContext()?.cgImage else { return }
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

    /// Gaussian-blur a region. The input is clamped to its extent (edge
    /// pixels repeat outwards), so the blur never averages in transparent
    /// pixels from outside the crop: the result is opaque to the edge, and no
    /// original pixel shows through when it is drawn over the source. Nil
    /// when the filter fails (the caller then paints the region solid).
    private func blurredRegion(_ cgImage: CGImage, radius: CGFloat, scale: CGFloat) -> UIImage? {
        let source = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(source.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage,
              let cg = MobileScreenshots.ciContext.createCGImage(
                output, from: source.extent)
        else { return nil }
        return UIImage(cgImage: cg, scale: scale, orientation: .up)
    }

    /// Coarse-mosaic a region via `CIPixellate`. `blockSize` is in source
    /// (pixel) units; clamp the output to the input extent so the filter's
    /// edge bleed doesn't shift the drawn region. Nil when the filter fails
    /// (the caller then paints the region solid).
    private func pixelatedRegion(_ cgImage: CGImage, blockSize: CGFloat, scale: CGFloat) -> UIImage? {
        let ciImage = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(blockSize, forKey: kCIInputScaleKey)
        filter.setValue(
            CIVector(x: ciImage.extent.midX, y: ciImage.extent.midY),
            forKey: kCIInputCenterKey)
        guard let output = filter.outputImage,
              let cg = MobileScreenshots.ciContext.createCGImage(
                output, from: ciImage.extent)
        else { return nil }
        return UIImage(cgImage: cg, scale: scale, orientation: .up)
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
