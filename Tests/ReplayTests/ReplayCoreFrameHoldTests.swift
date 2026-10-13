import XCTest
#if canImport(UIKit)
import UIKit
@testable import Replay

/// What keeps the live engine from taking frames: the app being in the
/// background, `pauseRecording` and the schematic opt-out. Driven through the
/// public facade against `ReplayCore.shared`, with a stub upload path in place
/// of the /start round-trip. The bugs these pin down:
///   • host-fed (Flutter) frames shot while the app was in the background were
///     kept and uploaded, recording a screen nobody could see and pushing the
///     session's last upload later; a host resume, an opt-in or leaving an
///     excluded screen in the background restarted native capture there too;
///   • a session that went live in the background (restarted there, or opened
///     by a background launch) took frames and ran native capture there;
///   • such a call from another thread (the React Native bridge's queue) could
///     still restart native capture just after the app left;
///   • opting back into schematic recordings lifted a `pauseRecording` still
///     in effect, and a repeated opt-in flushed a partial archive.
final class ReplayCoreFrameHoldTests: XCTestCase {
    private let core = ReplayCore.shared
    /// What UIKit would report: the runner itself never leaves the
    /// foreground, so the helpers below move this with the notifications.
    private var appState: UIApplication.State = .active
    private var uikitAppState: (() -> UIApplication.State)?

    override func setUp() {
        super.setUp()
        uikitAppState = core.applicationState
        appState = .active
        core.applicationState = { [unowned self] in self.appState }
        resetEngine()
    }

    override func tearDown() {
        resetEngine()
        if let uikitAppState { core.applicationState = uikitAppState }
        super.tearDown()
    }

    // MARK: - Background

    func testHostFedFramesAreRefusedWhileTheAppIsInTheBackground() {
        let (shots, uploader) = goLive(nativeCapture: false)
        Replay.reportFrame(Self.png, rects: [], styles: [])
        goToBackground()
        // Until the drain settles: a resume joining it would also force out a
        // frame stamped in the same millisecond as the resume.
        waitUntil { uploader.imageFrameCounts == [1] && !shots.isDraining }
        XCTAssertEqual(uploader.imageFrameCounts, [1], "the frame shot on screen goes out with the background flush")

        // Flutter's capture timer keeps firing while the background task keeps
        // the app running.
        for _ in 0..<3 { Replay.reportFrame(Self.png, rects: [], styles: []) }
        XCTAssertEqual(shots.pendingCount, 0, "nothing on screen, nothing to record")

        returnToForeground()
        Replay.reportFrame(Self.png, rects: [], styles: [])
        XCTAssertEqual(shots.pendingCount, 1, "frames are taken again once the app is back")
        waitUntil { !shots.isDraining }
        XCTAssertEqual(uploader.imageFrameCounts, [1], "no background frame was uploaded")
    }

    func testAHostResumeInTheBackgroundWaitsForTheForeground() {
        let (shots, _) = goLive(nativeCapture: true)
        Replay.pauseRecording()
        goToBackground()

        Replay.resumeRecording()
        drainMainQueue()
        XCTAssertFalse(shots.isCapturing, "no capture of a window nobody sees")

        returnToForeground()
        XCTAssertTrue(shots.isCapturing)
    }

    func testLeavingAnExcludedScreenInTheBackgroundWaitsForTheForeground() {
        let (shots, _) = goLive(nativeCapture: true)
        Replay.excludeScreen("Secret")
        Replay.tagScreenName("Secret")
        goToBackground()

        Replay.tagScreenName("Home")
        drainMainQueue()
        XCTAssertFalse(shots.isCapturing, "no capture of a window nobody sees")

        returnToForeground()
        XCTAssertTrue(shots.isCapturing)
    }

    func testASessionStoppedInTheBackgroundTakesFramesWhenItStartsAgain() {
        goLive(nativeCapture: false)
        goToBackground()
        Replay.stop() // the lifecycle observers go with the session...
        returnToForeground() // ...so nothing sees this return

        let (shots, _) = goLive(nativeCapture: false)
        Replay.reportFrame(Self.png, rects: [], styles: [])
        XCTAssertEqual(shots.pendingCount, 1)
    }

    /// startNewSession (or stop + start) while the app is still in the
    /// background: stop() takes the observers that saw it leave.
    func testASessionRestartedInTheBackgroundTakesNoHostFedFramesUntilTheAppReturns() {
        goLive(nativeCapture: false)
        goToBackground()
        Replay.stop()
        let (shots, _) = goLive(nativeCapture: false) // still in the background

        Replay.reportFrame(Self.png, rects: [], styles: [])
        XCTAssertEqual(shots.pendingCount, 0, "nothing on screen, nothing to record")

        returnToForeground()
        Replay.reportFrame(Self.png, rects: [], styles: [])
        XCTAssertEqual(shots.pendingCount, 1)
    }

    func testASessionRestartedInTheBackgroundStartsNativeCaptureWhenTheAppReturns() {
        goLive(nativeCapture: true)
        goToBackground()
        Replay.stop()
        let (shots, _) = goLive(nativeCapture: true) // still in the background
        XCTAssertFalse(shots.isCapturing, "no capture of a window nobody sees")

        returnToForeground()
        XCTAssertTrue(shots.isCapturing)
    }

    /// A silent push, background fetch or location update launches the app in
    /// the background, and Replay.start in didFinishLaunching opens a session
    /// there: no didEnterBackground is ever posted.
    func testASessionThatGoesLiveInABackgroundLaunchWaitsForTheAppToOpen() {
        appState = .background
        let (shots, _) = goLive(nativeCapture: true)
        XCTAssertFalse(shots.isCapturing, "no capture of a window nobody sees")
        Replay.reportFrame(Self.png, rects: [], styles: [])
        XCTAssertEqual(shots.pendingCount, 0, "nor of frames the host reports")

        returnToForeground()
        XCTAssertTrue(shots.isCapturing)
    }

    // MARK: - Schematic opt-out

    func testOptingBackIntoSchematicRecordingDoesNotLiftAHostPause() {
        let (shots, _) = goLive(nativeCapture: true)
        Replay.pauseRecording() // pauseRecording on a PIN screen

        Replay.optOutOfSchematicRecordings(true)
        Replay.optOutOfSchematicRecordings(false) // e.g. a consent sync on every launch
        drainMainQueue()
        XCTAssertFalse(shots.isCapturing, "pauseRecording still holds")

        Replay.resumeRecording()
        drainMainQueue()
        XCTAssertTrue(shots.isCapturing)
    }

    func testOptingBackInDoesNotLiftAHostPauseOnHostFedFrames() {
        let (shots, _) = goLive(nativeCapture: false)
        Replay.pauseRecording()
        Replay.optOutOfSchematicRecordings(true)
        Replay.optOutOfSchematicRecordings(false)

        Replay.reportFrame(Self.png, rects: [], styles: [])
        XCTAssertEqual(shots.pendingCount, 0, "pauseRecording still holds")

        Replay.resumeRecording()
        Replay.reportFrame(Self.png, rects: [], styles: [])
        XCTAssertEqual(shots.pendingCount, 1)
    }

    func testARepeatedOptInSendsNoPartialArchive() {
        let (shots, uploader) = goLive(nativeCapture: false)
        for _ in 0..<3 { Replay.reportFrame(Self.png, rects: [], styles: []) }

        Replay.optOutOfSchematicRecordings(false) // already opted in: nothing changes
        waitUntil(timeout: 0.3) { !uploader.imageFrameCounts.isEmpty }

        XCTAssertEqual(uploader.imageFrameCounts, [], "only a full batch goes out while recording")
        XCTAssertEqual(shots.pendingCount, 3)
    }

    func testOptingInWhileInTheBackgroundWaitsForTheForeground() {
        let (shots, _) = goLive(nativeCapture: true)
        Replay.optOutOfSchematicRecordings(true)
        goToBackground()

        Replay.optOutOfSchematicRecordings(false)
        drainMainQueue()
        XCTAssertFalse(shots.isCapturing, "no capture of a window nobody sees")

        returnToForeground()
        XCTAssertTrue(shots.isCapturing)
    }

    // MARK: - Calls from another thread

    // The React Native bridge calls from its own module queue. A call there
    // that lifted a hold, having checked that the app was in front, could
    // restart native capture just after onBackground (on main) stopped it, so
    // the capture timer ran on in the background.

    func testAResumeFromAnotherThreadAsTheAppLeavesDoesNotRestartCapture() {
        let (shots, uploader) = goLiveGated()
        holdWithAFrameUnsent(shots, uploader) { Replay.pauseRecording() }

        callOffMainAsTheAppLeaves(uploader) { Replay.resumeRecording() }
        XCTAssertFalse(shots.isCapturing, "no capture of a window nobody sees")

        returnToForeground()
        XCTAssertTrue(shots.isCapturing)
    }

    func testAnOptInFromAnotherThreadAsTheAppLeavesDoesNotRestartCapture() {
        let (shots, uploader) = goLiveGated()
        holdWithAFrameUnsent(shots, uploader) { Replay.optOutOfSchematicRecordings(true) }

        callOffMainAsTheAppLeaves(uploader) { Replay.optOutOfSchematicRecordings(false) }
        XCTAssertFalse(shots.isCapturing, "no capture of a window nobody sees")
        XCTAssertFalse(Replay.isOptedOutOfSchematicRecordings, "persisted by the time the call returns")

        returnToForeground()
        XCTAssertTrue(shots.isCapturing)
    }

    func testLeavingAnExcludedScreenFromAnotherThreadAsTheAppLeavesDoesNotRestartCapture() {
        let (shots, uploader) = goLiveGated()
        Replay.excludeScreen("Secret")
        holdWithAFrameUnsent(shots, uploader) { Replay.tagScreenName("Secret") }

        callOffMainAsTheAppLeaves(uploader) { Replay.tagScreenName("Home") }
        XCTAssertFalse(shots.isCapturing, "no capture of a window nobody sees")

        returnToForeground()
        XCTAssertTrue(shots.isCapturing)
    }

    /// Not a regression on the old code: guards the opt-out's own check that
    /// no other hold keeps frames paused.
    func testOptingInOnAnExcludedScreenKeepsItsFramesPaused() {
        let (shots, _) = goLive(nativeCapture: true)
        Replay.excludeScreen("Secret")
        Replay.tagScreenName("Secret")

        Replay.optOutOfSchematicRecordings(true)
        Replay.optOutOfSchematicRecordings(false)
        drainMainQueue()
        XCTAssertFalse(shots.isCapturing, "the excluded screen still holds")

        Replay.tagScreenName("Home")
        drainMainQueue()
        XCTAssertTrue(shots.isCapturing)
    }

    /// Not a regression on the old code: guards the order in the facade. The
    /// engine acts only when the opt-out changes, which it can only see
    /// before the opt-out is persisted.
    func testTheSchematicOptOutHoldsFramesUntilItIsLifted() {
        let (shots, _) = goLive(nativeCapture: true)

        Replay.optOutOfSchematicRecordings(true)
        drainMainQueue()
        XCTAssertFalse(shots.isCapturing)
        XCTAssertTrue(Replay.isOptedOutOfSchematicRecordings, "persisted")

        Replay.optOutOfSchematicRecordings(false)
        drainMainQueue()
        XCTAssertTrue(shots.isCapturing)
        XCTAssertFalse(Replay.isOptedOutOfSchematicRecordings)
    }

    // MARK: - Helpers

    /// Hand the shared engine a stub-backed frame buffer and its lifecycle
    /// observers, as a live session would have.
    @discardableResult
    private func goLive(nativeCapture: Bool) -> (MobileScreenshots, StubUploader) {
        let uploader = StubUploader()
        return (goLive(nativeCapture: nativeCapture, transport: uploader), uploader)
    }

    /// Native capture, over an upload path that can hold a send.
    private func goLiveGated() -> (MobileScreenshots, GatedUploader) {
        let uploader = GatedUploader()
        return (goLive(nativeCapture: true, transport: uploader), uploader)
    }

    private func goLive(nativeCapture: Bool, transport: MobileUploading) -> MobileScreenshots {
        let shots = MobileScreenshots(transport: transport, nativeCapture: nativeCapture, privacyRects: { [] })
        core.attachFrames(shots, nativeCapture: nativeCapture)
        core.registerLifecycle()
        drainMainQueue()
        return shots
    }

    /// Apply `hold` with a frame left unsent (its upload fails, as offline),
    /// so the call that lifts the hold has an upload to make: its flush sends
    /// the first archive on the caller's own thread.
    private func holdWithAFrameUnsent(_ shots: MobileScreenshots, _ uploader: GatedUploader, hold: () -> Void) {
        Replay.reportFrame(Self.png, rects: [], styles: [])
        uploader.stub.imageResults = [false]
        hold()
        waitUntil { uploader.imageSends == 1 && !shots.isDraining }
        XCTAssertFalse(shots.isCapturing)
        XCTAssertGreaterThan(shots.pendingCount, 0, "the failed upload keeps its frames")
    }

    /// Run `call` on another thread and send the app to the background while
    /// the call is part-way: held in that upload, after it looked at whether
    /// the app was in front. Then let it finish and run what both queued on
    /// the main thread. A call that only hands its work to the main thread
    /// returns at once instead, and that work runs after the background.
    private func callOffMainAsTheAppLeaves(_ uploader: GatedUploader, _ call: @escaping () -> Void) {
        uploader.close()
        let returned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { call(); returned.signal() }
        // Block main (no run-loop turn) so nothing it was handed runs yet.
        var done = false
        let deadline = Date().addingTimeInterval(2)
        while !done && !uploader.isHolding && Date() < deadline {
            done = returned.wait(timeout: .now() + 0.005) == .success
        }
        appState = .background
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        uploader.open()
        if !done { XCTAssertEqual(returned.wait(timeout: .now() + 2), .success, "the call finished") }
        drainMainQueue()
    }

    /// The engine is a process-wide singleton: clear everything a test can
    /// leave on it, and the persisted opt-out.
    private func resetEngine() {
        core.cancelSession()
        core.resumeCapture()
        core.setExcludedScreens([])
        OptOutStore.shared.schematicOptOut = false
        drainMainQueue()
    }

    private func goToBackground() {
        appState = .background
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        drainMainQueue()
    }

    private func returnToForeground() {
        appState = .active
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        drainMainQueue()
    }

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

/// Holds image uploads on the caller's thread while closed, to stop a host
/// call part-way through the flush it makes. Otherwise a StubUploader.
private final class GatedUploader: MobileUploading {
    let stub = StubUploader()
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var closed = false
    private var held = 0
    private var sends = 0

    /// Image uploads attempted, held or not, failed or not.
    var imageSends: Int {
        lock.lock(); defer { lock.unlock() }
        return sends
    }

    var isHolding: Bool {
        lock.lock(); defer { lock.unlock() }
        return held > 0
    }

    func close() {
        lock.lock(); closed = true; lock.unlock()
    }

    func open() {
        lock.lock()
        closed = false
        let waiting = held
        held = 0
        lock.unlock()
        for _ in 0..<waiting { gate.signal() }
    }

    func sendImages(_ gzippedArchive: Data, completion: @escaping (Bool) -> Void) {
        lock.lock()
        sends += 1
        let hold = closed
        if hold { held += 1 }
        lock.unlock()
        if hold { gate.wait() }
        stub.sendImages(gzippedArchive, completion: completion)
    }

    func sendMessages(_ gzippedBatch: Data, completion: @escaping (Bool) -> Void) {
        stub.sendMessages(gzippedBatch, completion: completion)
    }

    func sendLateMessages(_ batch: Data, completion: @escaping (Bool) -> Void) {
        stub.sendLateMessages(batch, completion: completion)
    }
}
#endif
