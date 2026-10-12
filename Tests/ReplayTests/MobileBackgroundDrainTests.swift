import XCTest
import Compression
#if canImport(UIKit)
import UIKit
@testable import Replay

/// Guards the background/resume upload path of the mobile engine. The bugs
/// these pin down:
///   • backgrounding only fired one flush, with no background task, so frames
///     buffered since the last full batch were lost when the app was
///     suspended or killed;
///   • a failed upload during that window was not resent on return;
///   • the message queue sent one batch per flush, stranding the rest;
///   • resuming restarted native screenshots for host-fed (Flutter) capture.
final class MobileBackgroundDrainTests: XCTestCase {

    // MARK: - Frames

    func testFullBatchFlushLeavesPartialRemainderBuffered() {
        let uploader = StubUploader()
        let shots = MobileScreenshots(transport: uploader, nativeCapture: false, privacyRects: { [] })

        for _ in 0..<45 { shots.submitFrame(Self.png, rects: []) }

        waitUntil { uploader.imageFrameCounts == [20, 20] }
        XCTAssertEqual(uploader.imageFrameCounts, [20, 20], "only full batches go out while recording")
        XCTAssertEqual(shots.pendingCount, 5)
    }

    func testPauseUploadsEverythingBufferedThenCompletes() {
        let uploader = StubUploader()
        let shots = MobileScreenshots(transport: uploader, nativeCapture: false, privacyRects: { [] })
        for _ in 0..<5 { shots.submitFrame(Self.png, rects: []) }
        XCTAssertEqual(uploader.imageFrameCounts, [], "a partial batch is not sent while recording")

        let done = expectation(description: "pause completion")
        shots.pause { done.fulfill() }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(uploader.imageFrameCounts, [5], "completion runs only after the upload settles")
        XCTAssertEqual(shots.pendingCount, 0)
    }

    func testPauseSendsBoundedArchivesInCaptureOrder() {
        let uploader = StubUploader()
        uploader.imageResults = [false] // the first full-batch flush fails while recording
        let shots = MobileScreenshots(transport: uploader, nativeCapture: false, privacyRects: { [] })
        for _ in 0..<47 { shots.submitFrame(Self.png, rects: []) }
        waitUntil { !shots.isDraining }

        let done = expectation(description: "pause completion")
        shots.pause { done.fulfill() }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(uploader.imageFrameCounts.reduce(0, +), 47, "every frame is uploaded exactly once")
        XCTAssertTrue(uploader.imageFrameCounts.allSatisfy { $0 <= 20 }, "archives stay bounded")
        let ts = uploader.imageTimestamps
        XCTAssertEqual(ts, ts.sorted(), "archives reach the server in capture order")
        XCTAssertEqual(shots.pendingCount, 0)
    }

    func testFramesFailingDuringPauseAreKeptAndSentOnResume() {
        let uploader = StubUploader()
        uploader.imageResults = [false] // suspension cancels the in-flight upload
        let shots = MobileScreenshots(transport: uploader, nativeCapture: false, privacyRects: { [] })
        for _ in 0..<5 { shots.submitFrame(Self.png, rects: []) }

        let done = expectation(description: "pause completion")
        shots.pause { done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(uploader.imageFrameCounts, [], "the cancelled upload delivered nothing")
        XCTAssertEqual(shots.pendingCount, 5, "pause never discards frames")

        shots.resume()
        waitUntil { uploader.imageFrameCounts == [5] }
        XCTAssertEqual(uploader.imageFrameCounts, [5], "resume resends the leftovers immediately")
        XCTAssertEqual(shots.pendingCount, 0)
    }

    func testStopFinishesUploadingAfterTheEngineReleasesIt() {
        let uploader = StubUploader()
        var shots: MobileScreenshots? = MobileScreenshots(transport: uploader, nativeCapture: false, privacyRects: { [] })
        // Offline while 45 frames buffer up, so stop() has three archives to send.
        uploader.failImages = true
        for _ in 0..<45 { shots?.submitFrame(Self.png, rects: []) }
        waitUntil { shots?.isDraining == false && shots?.pendingCount == 45 }
        XCTAssertEqual(shots?.pendingCount, 45)
        uploader.failImages = false

        shots?.stop()
        shots = nil // ReplayCore.stop() drops its reference straight away

        waitUntil { uploader.imageFrameCounts.reduce(0, +) == 45 }
        XCTAssertEqual(uploader.imageFrameCounts, [20, 20, 5], "the session's last frames all go out")
    }

    func testResumeJoiningAFailingUploadStillGetsItsAttempt() {
        let uploader = StubUploader()
        uploader.imageDelay = 0.3
        uploader.imageResults = [false] // the pre-suspension upload dies...
        let shots = MobileScreenshots(transport: uploader, nativeCapture: false, privacyRects: { [] })
        for _ in 0..<5 { shots.submitFrame(Self.png, rects: []) }

        shots.pause()
        waitUntil { shots.isDraining }
        shots.resume() // ...while the app returns and asks for the leftovers

        waitUntil { uploader.imageFrameCounts == [5] }
        XCTAssertEqual(uploader.imageFrameCounts, [5], "the resume request is retried, not lost with the failed round")
        XCTAssertEqual(shots.pendingCount, 0)
    }

    func testResumeOnlyForcesOutFramesCapturedBeforeIt() {
        let uploader = StubUploader()
        uploader.imageDelay = 0.3
        let shots = MobileScreenshots(transport: uploader, nativeCapture: false, privacyRects: { [] })
        for _ in 0..<3 { shots.submitFrame(Self.png, rects: []) }
        shots.resume()
        waitUntil { shots.isDraining }

        // Live capture keeps going while the resume's upload is in flight.
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        for _ in 0..<5 { shots.submitFrame(Self.png, rects: []) }
        waitUntil { !shots.isDraining }

        XCTAssertEqual(uploader.imageFrameCounts, [3], "frames after the resume wait for a full batch")
        XCTAssertEqual(shots.pendingCount, 5)
    }

    func testStopRacingAResumeNeverRestartsCapture() {
        let shots = MobileScreenshots(transport: StubUploader(), nativeCapture: true, privacyRects: { [] })
        shots.resume() // queues the timer restart on main...
        shots.stop()   // ...and the session ends before it runs
        drainMainQueue()
        XCTAssertFalse(shots.isCapturing)
    }

    func testDiscardHaltsARunningDrain() {
        let uploader = StubUploader()
        let shots = MobileScreenshots(transport: uploader, nativeCapture: false, privacyRects: { [] })
        uploader.failImages = true
        for _ in 0..<60 { shots.submitFrame(Self.png, rects: []) }
        waitUntil { !shots.isDraining && shots.pendingCount == 60 }
        uploader.failImages = false
        uploader.imageDelay = 0.2

        shots.pause()
        waitUntil { shots.isDraining }
        shots.discard() // cancelSession: nothing more may leave the device

        waitUntil { !shots.isDraining }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertLessThanOrEqual(uploader.imageFrameCounts.count, 1, "only the archive already in flight goes out")
        XCTAssertEqual(shots.pendingCount, 0)
    }

    func testResumeDoesNotStartNativeCaptureForHostFedFrames() {
        let shots = MobileScreenshots(transport: StubUploader(), nativeCapture: false, privacyRects: { [] })
        shots.pause()
        shots.resume()
        drainMainQueue()
        XCTAssertFalse(shots.isCapturing, "host-fed capture must never start the native timer")
    }

    func testResumeRestartsNativeCapture() {
        let shots = MobileScreenshots(transport: StubUploader(), nativeCapture: true, privacyRects: { [] })
        shots.pause()
        shots.resume()
        drainMainQueue()
        XCTAssertTrue(shots.isCapturing)
        shots.discard()
        drainMainQueue()
    }

    // MARK: - Messages

    func testCollectorDrainSendsEveryQueuedBatch() {
        let uploader = StubUploader()
        let collector = MobileCollector(transport: uploader)
        // Offline while 12 × 60 KB queue up (720 KB, more than one 500 KB
        // batch): the size-triggered flushes fail and re-queue.
        uploader.failMessages = true
        for _ in 0..<12 { collector.add(Data(repeating: 7, count: 60_000)) }
        waitUntil { collector.waitingCount == 12 }
        XCTAssertEqual(collector.waitingCount, 12)
        uploader.failMessages = false

        let done = expectation(description: "drain completion")
        collector.drain { done.fulfill() }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(collector.waitingCount, 0, "drain empties the queue, not just one batch")
        XCTAssertEqual(uploader.messageBatchCount, 2)
    }

    func testCollectorStopDrainsEverythingAndEndsWithLate() {
        let uploader = StubUploader()
        var collector: MobileCollector? = MobileCollector(transport: uploader)
        uploader.failMessages = true
        for _ in 0..<12 { collector?.add(Data(repeating: 7, count: 60_000)) }
        waitUntil { collector?.waitingCount == 12 }
        uploader.failMessages = false

        collector?.stop()
        collector = nil // ReplayCore.stop() drops its reference straight away

        waitUntil { uploader.lateBatchCount == 1 }
        XCTAssertEqual(uploader.messageBatchCount, 1, "every batch but the last goes to /i")
        XCTAssertEqual(uploader.lateBatchCount, 1, "the batch that empties the queue goes to /late")
    }

    func testCollectorDrainStopsOnFailureAndKeepsTheBatch() {
        let uploader = StubUploader()
        uploader.messageResults = [false]
        let collector = MobileCollector(transport: uploader)
        for i in 0..<3 { collector.add(Data([UInt8(i)])) }

        let done = expectation(description: "drain completion")
        collector.drain { done.fulfill() }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(uploader.messageBatchCount, 0)
        XCTAssertEqual(collector.waitingCount, 3, "a failed batch goes back on the queue")
    }

    // MARK: - Helpers

    private static let png: Data = {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }()

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func drainMainQueue() {
        let flushed = expectation(description: "main queue")
        DispatchQueue.main.async { flushed.fulfill() }
        wait(for: [flushed], timeout: 2)
    }
}

/// Records uploads and answers them asynchronously, like URLSession does.
private final class StubUploader: MobileUploading {
    private let lock = NSLock()
    private var archives: [Data] = []
    private var batches = 0
    /// Outcomes for the next sends, in order; once empty every send succeeds.
    var imageResults: [Bool] = []
    var messageResults: [Bool] = []
    /// Fail every send of that kind while set (the device is offline).
    var failMessages = false
    var failImages = false
    /// How long an image upload takes before its outcome is reported.
    var imageDelay: TimeInterval = 0.01
    private var lates = 0

    var lateBatchCount: Int {
        lock.lock(); defer { lock.unlock() }
        return lates
    }

    var imageFrameCounts: [Int] {
        lock.lock(); defer { lock.unlock() }
        return archives.map { Self.frameTimestamps($0).count }
    }

    var imageTimestamps: [UInt64] {
        lock.lock(); defer { lock.unlock() }
        return archives.flatMap { Self.frameTimestamps($0) }
    }

    var messageBatchCount: Int {
        lock.lock(); defer { lock.unlock() }
        return batches
    }

    func sendImages(_ gzippedArchive: Data, completion: @escaping (Bool) -> Void) {
        lock.lock()
        let ok = !failImages && (imageResults.isEmpty ? true : imageResults.removeFirst())
        if ok { archives.append(gzippedArchive) }
        let delay = imageDelay
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { completion(ok) }
    }

    func sendMessages(_ gzippedBatch: Data, completion: @escaping (Bool) -> Void) {
        lock.lock()
        let ok = !failMessages && (messageResults.isEmpty ? true : messageResults.removeFirst())
        if ok { batches += 1 }
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) { completion(ok) }
    }

    func sendLateMessages(_ batch: Data, completion: @escaping (Bool) -> Void) {
        lock.lock(); lates += 1; lock.unlock()
        DispatchQueue.global().async { completion(true) }
    }

    /// Timestamps of the frames in one gzipped `[u64 ts][u32 size][jpeg]` archive.
    private static func frameTimestamps(_ gz: Data) -> [UInt64] {
        // MobileGzip wraps raw DEFLATE in a 10-byte header + 8-byte trailer;
        // the last 4 bytes hold the uncompressed size.
        guard gz.count > 18 else { return [] }
        let size = gz.suffix(4).withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).littleEndian) }
        let deflate = gz.subdata(in: 10..<(gz.count - 8))
        var raw = [UInt8](repeating: 0, count: size)
        let written = deflate.withUnsafeBytes { src in
            compression_decode_buffer(&raw, size, src.bindMemory(to: UInt8.self).baseAddress!, deflate.count, nil, COMPRESSION_ZLIB)
        }
        guard written == size else { return [] }
        var out: [UInt64] = []
        var off = 0
        while off + 12 <= raw.count {
            let ts = raw[off..<off + 8].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
            let len = raw[off + 8..<off + 12].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
            out.append(ts)
            off += 12 + len
        }
        return out
    }
}
#endif
