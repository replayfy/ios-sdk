#if canImport(UIKit)
import UIKit

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

    private func capture() {
        autoreleasepool {
            guard let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) else { return }
            let size = window.bounds.size
            guard size.width > 0, size.height > 0 else { return }

            UIGraphicsBeginImageContextWithOptions(size, false, screenScale)
            defer { UIGraphicsEndImageContext() }
            guard let ctx = UIGraphicsGetCurrentContext() else { return }
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)

            // Mask sensitive regions with a solid box.
            ctx.setFillColor(UIColor.darkGray.cgColor)
            for rect in privacy() { ctx.fill(rect) }

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
