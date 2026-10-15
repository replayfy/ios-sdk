import XCTest
#if canImport(UIKit)
import UIKit
import SwiftUI
import WebKit
@testable import Replay
import ReplaySwiftUI

/// What the frames, gestures and input events hide by default, matched to
/// the reference trackers:
///   • secure entry AND the password / new-password / one-time-code /
///     card-number content types, on text fields and text views, masked
///     solid with no flag set;
///   • the reference visibility rule: hidden or transparent views (or
///     ancestors) are not masked, a view still fading out is;
///   • masks follow what is drawn mid-animation (presentation layer);
///   • the whole-screen cover is solid, on host-fed frames too, and hides
///     gestures unless asked not to;
///   • a region the blur can't render is painted solid, blurred regions are
///     drawn back exactly in place, and the blur doesn't let the edge through;
///   • tap labels and observed inputs are blanked wherever the frames are;
///   • `.replayOcclude()` never takes the app's touches;
///   • the dashboard's "always mask input values" adds to the app's flag;
///   • password inputs inside web views (shadow roots and same-origin
///     frames included) are masked where they are drawn, a web view that
///     hasn't answered or can't be placed is masked whole, and only frames
///     of another origin that may take credentials are masked whole.
@MainActor
final class MobilePrivacyReferenceParityTests: XCTestCase {
    private let registry = PrivacyRegistry.shared
    private let core = ReplayCore.shared
    private var windows: [UIWindow] = []

    override func setUp() {
        super.setUp()
        resetPrivacy()
        core.cancelSession()
    }

    override func tearDown() {
        resetPrivacy()
        core.cancelSession()
        for w in windows { w.rootViewController = nil; w.isHidden = true }
        windows.removeAll()
        super.tearDown()
    }

    // MARK: - 1. Secure inputs (secure entry and content types)

    func testASecureFieldIsMaskedWithNoFlagSet() {
        let (window, root) = makeWindow()
        let f = field(in: root, secure: true)
        XCTAssertTrue(isCovered(f, by: registry.bulkBounds(within: window), in: window))
    }

    func testAPasswordContentTypeFieldIsMasked() { assertContentTypeIsMasked(.password) }
    func testANewPasswordContentTypeFieldIsMasked() { assertContentTypeIsMasked(.newPassword) }
    func testAOneTimeCodeContentTypeFieldIsMasked() { assertContentTypeIsMasked(.oneTimeCode) }
    func testACardNumberContentTypeFieldIsMasked() { assertContentTypeIsMasked(.creditCardNumber) }

    func testASecureTextViewIsMasked() {
        let (window, root) = makeWindow()
        let v = UITextView(frame: CGRect(x: 20, y: 40, width: 200, height: 80))
        v.isSecureTextEntry = true
        root.addSubview(v)
        XCTAssertTrue(isCovered(v, by: registry.bulkBounds(within: window), in: window))
    }

    func testAOneTimeCodeTextViewIsMasked() {
        let (window, root) = makeWindow()
        let v = UITextView(frame: CGRect(x: 20, y: 40, width: 200, height: 80))
        v.textContentType = .oneTimeCode
        root.addSubview(v)
        XCTAssertTrue(isCovered(v, by: registry.bulkBounds(within: window), in: window))
    }

    /// No invention: only the four content types the reference ships.
    func testUsernameAndPlainFieldsStayVisible() {
        let (window, root) = makeWindow()
        let user = field(in: root, y: 40)
        user.textContentType = .username
        let plain = field(in: root, y: 120)
        let rects = registry.bulkBounds(within: window)
        XCTAssertFalse(isCovered(user, by: rects, in: window))
        XCTAssertFalse(isCovered(plain, by: rects, in: window))
        XCTAssertTrue(rects.isEmpty, "nothing to mask: \(rects)")
    }

    func testTurningSecureEntryOffShowsTheFieldOnTheNextFrame() {
        let (window, root) = makeWindow()
        let f = field(in: root, secure: true)
        XCTAssertTrue(isCovered(f, by: registry.bulkBounds(within: window), in: window))
        f.isSecureTextEntry = false
        XCTAssertTrue(registry.bulkBounds(within: window).isEmpty)
    }

    func testSecureInputsAreSolidWhateverTheMaskStyle() {
        let (window, root) = makeWindow()
        registry.maskStyle = .blur
        registry.occludeAllTextFields = true
        let secure = field(in: root, y: 40, secure: true)
        let plain = field(in: root, y: 120)
        let rects = registry.bulkMaskRects(within: window)
        XCTAssertEqual(style(of: secure, in: rects, window: window), .overlay)
        XCTAssertEqual(style(of: plain, in: rects, window: window), .blur, "the app's own choice still applies")
    }

    func testAnObservedOneTimeCodeFieldReportsAMaskedValue() {
        let capture = MobileInputCapture()
        var reported: (value: String, masked: Bool, label: String)?
        capture.onInput = { reported = ($0, $1, $2) }
        let f = UITextField()
        f.textContentType = .oneTimeCode
        f.text = "123456"
        f.placeholder = "Code"
        capture.observe(f)
        capture.editingEnded(f)
        XCTAssertEqual(reported?.value, "***")
        XCTAssertEqual(reported?.masked, true)
        XCTAssertEqual(reported?.label, "Code")
    }

    func testAnObservedPlainFieldIsMaskedOnlyWhileAllFieldsAre() {
        let capture = MobileInputCapture()
        var reported: (value: String, masked: Bool)?
        capture.onInput = { value, masked, _ in reported = (value, masked) }
        let f = UITextField()
        f.text = "hello"
        capture.observe(f)

        capture.editingEnded(f)
        XCTAssertEqual(reported?.value, "hello")
        XCTAssertEqual(reported?.masked, false)

        registry.remoteOccludeAllTextFields = true
        capture.editingEnded(f)
        XCTAssertEqual(reported?.value, "***", "the dashboard's switch can't be bypassed through events")
        XCTAssertEqual(reported?.masked, true)
    }

    // MARK: - 2. Visibility (alpha > 0.01 on the view and every ancestor)

    func testASecureChildOfAVisibleContainerIsMasked() {
        let (window, root) = makeWindow()
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        root.addSubview(container)
        let f = field(in: container, secure: true)
        XCTAssertTrue(isCovered(f, by: registry.bulkBounds(within: window), in: window))
    }

    func testASecureChildOfATransparentContainerIsNotMasked() {
        let (window, root) = makeWindow()
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        container.alpha = 0
        root.addSubview(container)
        _ = field(in: container, secure: true)
        CATransaction.flush()
        XCTAssertTrue(registry.bulkBounds(within: window).isEmpty, "nothing is drawn there")
    }

    func testASecureChildOfAFadingContainerIsMasked() {
        let (window, root) = makeWindow()
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        root.addSubview(container)
        let f = field(in: container, secure: true)
        CATransaction.flush()
        UIView.animate(withDuration: 5) { container.alpha = 0 }
        spin(0.05)
        defer { container.layer.removeAllAnimations() }
        XCTAssertEqual(container.alpha, 0, "the model alpha is already 0")
        XCTAssertTrue(isCovered(f, by: registry.bulkBounds(within: window), in: window),
                      "still drawn while it fades out")
    }

    func testASecureChildOfAHiddenAncestorIsNotMasked() {
        let (window, root) = makeWindow()
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        container.isHidden = true
        root.addSubview(container)
        _ = field(in: container, secure: true)
        XCTAssertTrue(registry.bulkBounds(within: window).isEmpty)
    }

    func testASecureChildOfAZeroSizeUnclippedContainerIsMasked() {
        let (window, root) = makeWindow()
        let container = UIView(frame: CGRect(x: 40, y: 40, width: 0, height: 0))
        container.clipsToBounds = false
        root.addSubview(container)
        let f = UITextField(frame: CGRect(x: 10, y: 10, width: 120, height: 40))
        f.isSecureTextEntry = true
        container.addSubview(f)
        let rects = registry.bulkBounds(within: window)
        XCTAssertTrue(rects.contains { $0.contains(CGRect(x: 50, y: 50, width: 120, height: 40)) }, "\(rects)")
    }

    func testARegisteredViewUnderATransparentParentIsNotMasked() {
        let (window, root) = makeWindow()
        let parent = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        parent.alpha = 0
        root.addSubview(parent)
        let label = UILabel(frame: CGRect(x: 20, y: 20, width: 200, height: 40))
        parent.addSubview(label)
        registry.add(label)
        CATransaction.flush()
        XCTAssertTrue(registry.sensitiveBounds(within: window).isEmpty)
    }

    func testARegisteredViewUnderAFadingParentIsMasked() {
        let (window, root) = makeWindow()
        let parent = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        root.addSubview(parent)
        let label = UILabel(frame: CGRect(x: 20, y: 20, width: 200, height: 40))
        parent.addSubview(label)
        registry.add(label)
        CATransaction.flush()
        UIView.animate(withDuration: 5) { parent.alpha = 0 }
        spin(0.05)
        defer { parent.layer.removeAllAnimations() }
        XCTAssertTrue(isCovered(label, by: registry.sensitiveBounds(within: window), in: window))
    }

    // MARK: - 3. Geometry while animating

    func testTheMaskCoversBothWhereAViewIsDrawnAndWhereItIsGoing() throws {
        let (window, root) = makeWindow()
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        root.addSubview(container)
        let f = field(in: container, secure: true)
        CATransaction.flush()
        spin(0.05)
        UIView.animate(withDuration: 5) { container.frame.origin.x += 300 }
        spin(0.2)
        defer { container.layer.removeAllAnimations() }

        let model = f.convert(f.bounds, to: window)
        let pres = try XCTUnwrap(f.layer.presentation(), "no presentation layer to compare with")
            .convert(f.bounds, to: try XCTUnwrap(window.layer.presentation()))
        XCTAssertGreaterThan(abs(model.minX - pres.minX), 1, "mid-slide the model is ahead of the pixels")
        let rects = registry.bulkBounds(within: window)
        XCTAssertTrue(rects.contains { $0.contains(model) && $0.contains(pres) },
                      "model \(model), drawn \(pres), masks \(rects)")
    }

    // MARK: - 4. Whole screen

    func testTheWholeScreenIsOneSolidBoxWhateverTheMaskStyle() {
        let (window, root) = makeWindow()
        _ = field(in: root, secure: true)
        registry.maskStyle = .blur
        registry.setPendingFrameRects([MaskRect(rect: CGRect(x: 1, y: 1, width: 5, height: 5), style: .blur)])
        Replay.occludeSensitiveScreen(true)
        let rects = registry.windowPrivacyBounds(in: window)
        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects.first?.rect, window.bounds)
        XCTAssertEqual(rects.first?.style, .overlay)
        XCTAssertTrue(registry.consumePendingFrameRects().isEmpty, "the bridge rects were drained")
    }

    func testHostFedFramesAreCoveredWholeWhileTheScreenIsOccluded() throws {
        let uploader = StubUploader()
        let shots = goLiveHostFed(uploader)
        Replay.occludeSensitiveScreen(true)
        Replay.reportFrame(Self.magentaPNG, rects: [], styles: [])
        shots.stop()
        waitUntil { uploader.imageJPEGs.count == 1 }

        let jpeg = try XCTUnwrap(uploader.imageJPEGs.first)
        let image = try XCTUnwrap(UIImage(data: jpeg)?.cgImage)
        let px = try XCTUnwrap(Pixels(image))
        for y in stride(from: 0, to: px.height, by: 7) {
            for x in stride(from: 0, to: px.width, by: 7) {
                XCTAssertTrue(px.isOverlayGray(x, y), "pixel \(x),\(y) = \(px.rgb(x, y))")
            }
        }
    }

    // MARK: - 5. Fail closed, and masked regions stay in place

    func testARegionTheBlurCannotRenderIsPaintedSolid() throws {
        try assertUnrenderableRegionIsSolid(.blur)
    }

    func testARegionThePixelateCannotRenderIsPaintedSolid() throws {
        try assertUnrenderableRegionIsSolid(.pixelate)
    }

    /// A rect half outside the image, at a fractional position: each masked
    /// region is drawn back over exactly the pixels it was cropped from. With
    /// a pass-through renderer the frame must come out unchanged — before,
    /// the clipped crop was stretched into the unclipped rect.
    func testABlurredRegionIsDrawnBackExactlyInPlace() throws {
        let size = CGSize(width: 100, height: 50)
        let scale: CGFloat = 2
        let source = try XCTUnwrap(Self.stripes(size: size, scale: scale))
        let rects = [
            MaskRect(rect: CGRect(x: 60.3, y: 5.7, width: 80, height: 30.2), style: .blur),
            MaskRect(rect: CGRect(x: 10.3, y: 20.1, width: 30.4, height: 20.2), style: .pixelate),
        ]
        let out = try render(source, size: size, scale: scale, rects: rects) { region, _ in
            UIImage(cgImage: region, scale: scale, orientation: .up)
        }
        let a = try XCTUnwrap(Pixels(source)), b = try XCTUnwrap(Pixels(out))
        XCTAssertEqual(a.width, b.width)
        var worst = 0
        for y in 0..<a.height { for x in 0..<a.width { worst = max(worst, a.distance(to: b, x, y)) } }
        XCTAssertLessThanOrEqual(worst, 3, "masked pixels moved")
    }

    /// A solid box covers every pixel it touches. Found in the simulator
    /// end-to-end run: a 390 pt window at the capture scale 1.25 is 487.5 px,
    /// the frame 488 px, and occludeSensitiveScreen left the last column half
    /// covered, showing half of the screen's own pixels there; every mask
    /// that didn't start and end on whole pixels had such a blended edge.
    func testASolidBoxCoversEveryPixelItTouches() throws {
        let size = CGSize(width: 39, height: 21)   // 48.75 x 26.25 px
        let scale: CGFloat = 1.25
        func capture(_ rects: [MaskRect]) throws -> Pixels {
            // As MobileScreenshots.captureNow draws and masks a frame.
            UIGraphicsBeginImageContextWithOptions(size, false, scale)
            defer { UIGraphicsEndImageContext() }
            let ctx = try XCTUnwrap(UIGraphicsGetCurrentContext())
            UIColor.magenta.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let rendered = try XCTUnwrap(UIGraphicsGetImageFromCurrentImageContext()?.cgImage)
            MobileScreenshots(transport: StubUploader(), nativeCapture: false, privacyRects: { [] })
                .maskRegions(rects, from: rendered, in: ctx, scale: scale)
            return try XCTUnwrap(Pixels(try XCTUnwrap(UIGraphicsGetImageFromCurrentImageContext()?.cgImage)))
        }
        func uncovered(_ px: Pixels, _ xs: ClosedRange<Int>, _ ys: ClosedRange<Int>) -> [String] {
            var out: [String] = []
            for y in ys { for x in xs where !px.isOverlayGray(x, y) { out.append("\(x),\(y)=\(px.rgb(x, y))") } }
            return out
        }

        // The whole window, as occludeSensitiveScreen paints it.
        var px = try capture([MaskRect(rect: CGRect(origin: .zero, size: size), style: .overlay)])
        XCTAssertEqual(px.width, 49, "the frame has a part-covered last column")
        var left = uncovered(px, 0...(px.width - 1), 0...(px.height - 1))
        XCTAssertTrue(left.isEmpty, "\(left.count) pixels not solid, e.g. \(left.prefix(4))")

        // A box that starts and ends mid-pixel: 12.875...25.5 px across,
        // 6.625...14.25 px down.
        px = try capture([MaskRect(rect: CGRect(x: 10.3, y: 5.3, width: 10.1, height: 6.1), style: .overlay)])
        left = uncovered(px, 12...25, 6...14)
        XCTAssertTrue(left.isEmpty, "\(left.count) pixels not solid, e.g. \(left.prefix(4))")
        XCTAssertFalse(px.isOverlayGray(11, 10) || px.isOverlayGray(26, 10) || px.isOverlayGray(18, 5)
                       || px.isOverlayGray(18, 15), "only the pixels the box touches")
    }

    // MARK: - 6. Blur edges

    func testTheBlurDoesNotLetTheEdgeShowThrough() throws {
        let size = CGSize(width: 100, height: 60)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let source = try XCTUnwrap(UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 21, y: 10, width: 2, height: 40)) // 1 px inside the left edge
        }.cgImage)
        let rect = CGRect(x: 20, y: 10, width: 60, height: 40)
        let out = try render(source, size: size, scale: 1, rects: [MaskRect(rect: rect, style: .blur)], render: nil)
        let px = try XCTUnwrap(Pixels(out))
        for y in 10..<50 {
            for x in 20..<23 {
                let (r, g, b) = px.rgb(x, y)
                XCTAssertFalse(r > 120 && g < 40 && b < 40, "red shows through at \(x),\(y): \(r),\(g),\(b)")
            }
        }
    }

    // MARK: - 7. Gestures on an occluded screen

    func testGesturesAreHiddenWithTheScreenByDefault() {
        Replay.occludeSensitiveScreen(true)
        Replay.reportInteraction(kind: "tap", label: "Pay", x: 10, y: 10)
        Replay.reportInteraction(kind: "swipe", label: "List", x: 10, y: 10, direction: "up")
        Replay.reportInteraction(kind: "long_press", label: "Card", x: 10, y: 10)
        XCTAssertEqual(core.preStartMessages.count, 0)
    }

    func testGesturesCanBeKeptOnAnOccludedScreenWithTheirLabelsBlanked() {
        Replay.occludeSensitiveScreen(true, hideGestures: false)
        Replay.reportInteraction(kind: "tap", label: "Pay 4111", x: 10, y: 10)
        let messages = core.preStartMessages
        XCTAssertEqual(messages.count, 1)
        XCTAssertNil(messages.first?.range(of: Data("Pay 4111".utf8)), "a host label leaked")
        XCTAssertNotNil(messages.first?.range(of: Data("***".utf8)))
    }

    func testGesturesAreRecordedOnceTheScreenIsShownAgain() {
        Replay.occludeSensitiveScreen(true)
        Replay.occludeSensitiveScreen(false)
        Replay.reportInteraction(kind: "tap", label: "Pay", x: 10, y: 10)
        let messages = core.preStartMessages
        XCTAssertEqual(messages.count, 1)
        XCTAssertNotNil(messages.first?.range(of: Data("Pay".utf8)))
    }

    /// Values a host reports itself (React Native / Flutter) are blanked
    /// wherever the frames are.
    func testTrackedInputsAreBlankedWhileFieldsOrTheScreenAreMasked() {
        Replay.trackInput(label: "Name", value: "Ada", masked: false)
        registry.remoteOccludeAllTextFields = true
        Replay.trackInput(label: "Name", value: "Grace", masked: false)
        registry.remoteOccludeAllTextFields = false
        Replay.occludeSensitiveScreen(true)
        Replay.trackInput(label: "Name", value: "Linus", masked: false)
        let messages = core.preStartMessages
        XCTAssertEqual(messages.count, 3)
        XCTAssertNotNil(messages[0].range(of: Data("Ada".utf8)))
        XCTAssertNil(messages[1].range(of: Data("Grace".utf8)), "the dashboard's switch can't be bypassed")
        XCTAssertNil(messages[2].range(of: Data("Linus".utf8)), "the whole screen is occluded")
    }

    // MARK: - 8. Tap labels

    func testTapLabelsAreBlankedWhereTheFramesAre() {
        let (_, root) = makeWindow()
        let secure = field(in: root, y: 10, secure: true)
        secure.placeholder = "Password"
        let otp = field(in: root, y: 60)
        otp.textContentType = .oneTimeCode
        otp.placeholder = "Code"
        let inner = UIView(frame: CGRect(x: 2, y: 2, width: 10, height: 10))
        secure.addSubview(inner)

        let marked = label(in: root, "SECRET", y: 110)
        registry.add(marked)
        let container = UIView(frame: CGRect(x: 0, y: 160, width: 320, height: 60))
        root.addSubview(container)
        registry.add(container)
        let nested = label(in: container, "NESTED", y: 10)

        let plain = label(in: root, "Hello", y: 230)
        let button = UIButton(frame: CGRect(x: 20, y: 280, width: 100, height: 40))
        button.accessibilityIdentifier = "buy-button"
        root.addSubview(button)
        let email = field(in: root, y: 330)
        email.placeholder = "Email"

        XCTAssertEqual(MobileTouchCapture.describe(secure), "***")
        XCTAssertEqual(MobileTouchCapture.describe(inner), "***", "inside a secure field")
        XCTAssertEqual(MobileTouchCapture.describe(otp), "***")
        XCTAssertEqual(MobileTouchCapture.describe(marked), "***")
        XCTAssertEqual(MobileTouchCapture.describe(nested), "***", "inside a registered container")
        XCTAssertEqual(MobileTouchCapture.describe(plain), "Hello")
        XCTAssertEqual(MobileTouchCapture.describe(button), "buy-button")
        XCTAssertEqual(MobileTouchCapture.describe(email), "Email")

        registry.remoteOccludeAllTextFields = true
        XCTAssertEqual(MobileTouchCapture.describe(email), "***", "every field is masked")
        registry.remoteOccludeAllTextFields = false

        registry.occludeAllScreen = true
        XCTAssertEqual(MobileTouchCapture.describe(plain), "***", "the whole screen is occluded")
    }

    /// iOS 26 ends a touch that a view's own gesture recognizers took over
    /// (text fields, web views) with no view. Found in the simulator
    /// end-to-end run: every tap on a secure, one-time-code or card field was
    /// labelled "view", never "***". The view the touch began in names it,
    /// or the view under where it ended.
    func testATapThatEndsWithNoViewIsNamedByWhereItWas() {
        let (window, root) = makeWindow()
        let secure = field(in: root, y: 10, secure: true)
        secure.placeholder = "Password"
        let email = field(in: root, y: 60)
        email.placeholder = "Email"
        let button = UIButton(frame: CGRect(x: 20, y: 120, width: 100, height: 40))
        button.setTitle("Go", for: .normal)
        root.addSubview(button)
        window.layoutIfNeeded()
        let onSecure = secure.convert(CGPoint(x: secure.bounds.midX, y: secure.bounds.midY), to: window)
        func label(ended: UIView?, began: UIView?, at point: CGPoint) -> String? {
            MobileTouchCapture.gestureLabel(ended: ended, began: began, at: point, in: window)
        }

        XCTAssertEqual(label(ended: nil, began: secure, at: onSecure), "***", "named by where it began")
        XCTAssertEqual(label(ended: nil, began: nil, at: onSecure), "***", "named by where it ended")
        XCTAssertEqual(label(ended: button, began: secure, at: onSecure), "Go", "the touch's own view wins")
        registry.remoteOccludeAllTextFields = true
        XCTAssertEqual(label(ended: nil, began: email, at: onSecure), "***", "every field is masked")
        registry.remoteOccludeAllTextFields = false
        let detached = UITextField()
        XCTAssertEqual(label(ended: nil, began: detached, at: onSecure), "***",
                       "a view that left the window doesn't name it")
        // A framework view names nothing: the generic label, as before.
        let system = UIView(frame: CGRect(x: 0, y: 300, width: 320, height: 100))
        root.addSubview(system)
        XCTAssertEqual(label(ended: nil, began: system, at: CGPoint(x: 10, y: 350)), "view")
        XCTAssertNil(label(ended: system, began: nil, at: CGPoint(x: 10, y: 350)),
                     "a touch that kept its framework view is still dropped")
    }

    /// A marker that sits beside the content (SwiftUI) blanks whatever it
    /// overlaps, as the frames hide it; framework hosts stay dropped.
    func testAViewOverlappingAMarkerIsBlanked() {
        let (_, root) = makeWindow()
        let host = HostLikeView(frame: root.bounds)
        root.addSubview(host)
        let engineHost = FlutterStandInView(frame: root.bounds)
        root.addSubview(engineHost)
        let marker = UIView(frame: CGRect(x: 20, y: 20, width: 100, height: 40))
        root.addSubview(marker)
        let under = label(in: root, "Ada Lovelace", y: 30)  // half under the marker
        let beside = label(in: root, "Hello", y: 300)
        XCTAssertEqual(MobileTouchCapture.describe(under), "Ada Lovelace")
        XCTAssertEqual(MobileTouchCapture.describe(host), "HostLikeView")

        registry.add(marker)
        XCTAssertEqual(MobileTouchCapture.describe(under), "***")
        XCTAssertEqual(MobileTouchCapture.describe(host), "***")
        XCTAssertNil(MobileTouchCapture.describe(engineHost), "an engine host is still dropped, not labelled")
        XCTAssertEqual(MobileTouchCapture.describe(beside), "Hello")
    }

    /// The frames mask an `applyOcclusion` instance whole, so taps on and
    /// inputs in its content carry no content either.
    func testTheContentOfAnOccludedClassIsBlankedInEvents() {
        let (window, root) = makeWindow()
        registry.applyOcclusion(CardStandInView.self)
        defer { registry.removeOcclusion(CardStandInView.self) }
        let card = CardStandInView(frame: CGRect(x: 0, y: 40, width: 320, height: 200))
        root.addSubview(card)
        let number = label(in: card, "4111 1111 1111 1111", y: 10)
        let name = field(in: card, y: 80)
        name.text = "Ada Obi"
        let outside = label(in: root, "Hello", y: 300)
        XCTAssertTrue(isCovered(number, by: registry.bulkBounds(within: window), in: window), "the frames hide it")

        XCTAssertEqual(MobileTouchCapture.describe(number), "***")
        XCTAssertEqual(MobileTouchCapture.describe(card), "***")
        XCTAssertEqual(MobileTouchCapture.describe(outside), "Hello")
        let capture = MobileInputCapture()
        var reported: (value: String, masked: Bool)?
        capture.onInput = { value, masked, _ in reported = (value, masked) }
        capture.observe(name)
        capture.editingEnded(name)
        XCTAssertEqual(reported?.value, "***")
        XCTAssertEqual(reported?.masked, true)
    }

    /// While every label is masked the frames cover the UILabel a button,
    /// segment or placeholder draws its text in, so tap labels taken from
    /// that text (or the accessibility label repeating it) are blanked.
    func testWhileEveryLabelIsMaskedTextOnButtonsAndAccessibilityLabelsIsBlanked() throws {
        let (window, root) = makeWindow()
        let button = UIButton(type: .system)
        button.frame = CGRect(x: 20, y: 40, width: 280, height: 44)
        button.setTitle("Send $250 to Ada Obi", for: .normal)
        root.addSubview(button)
        let icon = UIView(frame: CGRect(x: 20, y: 100, width: 44, height: 44))
        icon.accessibilityLabel = "Ada Obi"
        root.addSubview(icon)
        let email = field(in: root, y: 160)
        email.placeholder = "ada@example.com"
        let custom = HostLikeView(frame: CGRect(x: 20, y: 220, width: 44, height: 44))
        root.addSubview(custom)
        let tagged = UIButton(frame: CGRect(x: 20, y: 280, width: 100, height: 44))
        tagged.setTitle("Pay Ada", for: .normal)
        tagged.accessibilityIdentifier = "pay-button"
        root.addSubview(tagged)
        root.layoutIfNeeded()
        button.layoutIfNeeded()

        XCTAssertEqual(MobileTouchCapture.describe(button), "Send $250 to Ada Obi")
        XCTAssertEqual(MobileTouchCapture.describe(icon), "Ada Obi")
        XCTAssertEqual(MobileTouchCapture.describe(email), "ada@example.com")

        Replay.occludeAllTextView(true)
        let title = try XCTUnwrap(button.titleLabel)
        XCTAssertTrue(isCovered(title, by: registry.windowPrivacyBounds(in: window).map { $0.rect }, in: window),
                      "the frames hide the title")
        XCTAssertEqual(MobileTouchCapture.describe(button), "***")
        XCTAssertEqual(MobileTouchCapture.describe(icon), "***")
        XCTAssertEqual(MobileTouchCapture.describe(email), "***")
        XCTAssertEqual(MobileTouchCapture.describe(custom), "HostLikeView", "a class name is not text on screen")
        XCTAssertEqual(MobileTouchCapture.describe(tagged), "pay-button", "a developer id is not text on screen")
    }

    // MARK: - 9. SwiftUI .replayOcclude

    func testReplayOccludeLeavesTouchesToTheContentAndBlocksTheirRecording() throws {
        let (window, marker) = try hostOccludedButton(blockGestures: true)
        let center = marker.convert(CGPoint(x: marker.bounds.midX, y: marker.bounds.midY), to: window)
        let hit = window.hitTest(center, with: nil)
        XCTAssertNotNil(hit)
        XCTAssertFalse(hit.map { Self.isMarker($0) } ?? false, "the marker took the touch")
        XCTAssertTrue(registry.isGestureBlocked(at: center, in: window))
        XCTAssertFalse(registry.isGestureBlocked(at: CGPoint(x: 5, y: window.bounds.maxY - 5), in: window))
        XCTAssertTrue(registry.windowPrivacyBounds(in: window).contains { $0.rect.contains(center) })
    }

    func testReplayOccludeWithoutBlockingStillMasksButRecordsGestures() throws {
        let (window, marker) = try hostOccludedButton(blockGestures: false)
        let center = marker.convert(CGPoint(x: marker.bounds.midX, y: marker.bounds.midY), to: window)
        XCTAssertFalse(registry.isGestureBlocked(at: center, in: window))
        XCTAssertTrue(registry.windowPrivacyBounds(in: window).contains { $0.rect.contains(center) })
    }

    func testAddPrivacyViewDoesNotBlockGesturesByDefault() {
        let (window, root) = makeWindow()
        let v = label(in: root, "x", y: 20)
        Replay.addPrivacyView(v)
        let center = CGPoint(x: v.frame.midX, y: v.frame.midY)
        XCTAssertFalse(registry.isGestureBlocked(at: center, in: window))
        Replay.addPrivacyView(v, blockGestures: true)
        XCTAssertTrue(registry.isGestureBlocked(at: center, in: window))
        Replay.removePrivacyView(v)
        XCTAssertFalse(registry.isGestureBlocked(at: center, in: window))
    }

    // MARK: - Dashboard enforcement (privacy.occludeAllTextFields)

    func testTheDashboardFlagMasksPlainFieldsAndTextViews() {
        let (window, root) = makeWindow()
        let plain = field(in: root, y: 20)
        let textView = UITextView(frame: CGRect(x: 20, y: 100, width: 200, height: 80))
        root.addSubview(textView)
        let secure = field(in: root, y: 200, secure: true)
        XCTAssertEqual(registry.windowPrivacyBounds(in: window).count, 1, "only the secure field by default")

        registry.remoteOccludeAllTextFields = true
        let rects = registry.windowPrivacyBounds(in: window).map { $0.rect }
        XCTAssertTrue(isCovered(plain, by: rects, in: window))
        XCTAssertTrue(isCovered(textView, by: rects, in: window))
        XCTAssertTrue(isCovered(secure, by: rects, in: window))
    }

    func testTheAppCannotLiftTheDashboardFlag() {
        let (window, root) = makeWindow()
        let plain = field(in: root, y: 20)
        registry.remoteOccludeAllTextFields = true
        Replay.occludeAllTextFields(false)
        XCTAssertTrue(isCovered(plain, by: registry.windowPrivacyBounds(in: window).map { $0.rect }, in: window))
    }

    func testTheStartResponseCarriesTheDashboardFlag() throws {
        func decode(_ privacy: String) throws -> MobileStartResponse {
            let json = """
            {"token":"t","sessionID":"s","fps":3,"quality":"low","framesSupport":true,
             "projectID":"p","userUUID":"u"\(privacy)}
            """
            return try JSONDecoder().decode(MobileStartResponse.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode(#","privacy":{"occludeAllTextFields":true}"#).privacy?.occludeAllTextFields, true)
        XCTAssertEqual(try decode(#","privacy":{"occludeAllTextFields":false}"#).privacy?.occludeAllTextFields, false)
        XCTAssertNil(try decode("").privacy, "older servers send no privacy block")
        XCTAssertNil(try decode(#","privacy":{}"#).privacy?.occludeAllTextFields)
    }

    // MARK: - WKWebView

    func testAWebViewThatHasNotAnsweredIsMaskedWhole() {
        let (window, root) = makeWindow()
        let web = WKWebView(frame: CGRect(x: 10, y: 20, width: 300, height: 400))
        root.addSubview(web)
        let rects = registry.windowPrivacyBounds(in: window)
        XCTAssertTrue(rects.contains { $0.rect == web.frame && $0.style == .overlay }, "\(rects.map { $0.rect })")
    }

    func testWebViewMaskingCanBeTurnedOff() {
        let (window, root) = makeWindow()
        root.addSubview(WKWebView(frame: CGRect(x: 10, y: 20, width: 300, height: 400)))
        registry.webViewMaskingEnabled = false
        XCTAssertTrue(registry.windowPrivacyBounds(in: window).isEmpty)
    }

    func testPasswordInputsInsideAWebViewAreMasked() throws {
        let (window, root) = makeWindow()
        let web = WKWebView(frame: CGRect(x: 0, y: 40, width: 320, height: 400))
        web.scrollView.contentInsetAdjustmentBehavior = .never
        root.addSubview(web)
        try load(web, """
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
        <body style="margin:0">
        <input type="password" value="SECRET" style="position:absolute;left:20px;top:30px;width:100px;height:20px;border:0">
        <input type="text" value="public" style="position:absolute;left:20px;top:100px;width:100px;height:20px;border:0">
        <input autocomplete="one-time-code" value="123456" style="position:absolute;left:20px;top:170px;width:100px;height:20px;border:0">
        </body></html>
        """)
        let password = CGRect(x: 20, y: 70, width: 100, height: 20)   // window coordinates
        let text = CGRect(x: 20, y: 140, width: 100, height: 20)
        let code = CGRect(x: 20, y: 210, width: 100, height: 20)

        // First sight: no answer yet, masked whole.
        XCTAssertTrue(registry.windowPrivacyBounds(in: window).contains { $0.rect == web.frame })

        var rects = try nextFrame(in: window)
        XCTAssertFalse(rects.contains { $0.rect == web.frame }, "answered in time: \(rects.map { $0.rect })")
        XCTAssertTrue(rects.contains { $0.rect.contains(password) && $0.style == .overlay }, "\(rects.map { $0.rect })")
        XCTAssertTrue(rects.contains { $0.rect.contains(code) }, "\(rects.map { $0.rect })")
        XCTAssertFalse(rects.contains { $0.rect.intersects(text) }, "\(rects.map { $0.rect })")

        registry.remoteOccludeAllTextFields = true
        rects = try nextFrame(in: window)
        XCTAssertTrue(rects.contains { $0.rect.contains(text) }, "every field is masked: \(rects.map { $0.rect })")
    }

    /// The page measures a few milliseconds before the capture: an input in
    /// the page's flow is placed where the content is scrolled to when the
    /// frame is taken (the keyboard scrolling a field into view), and one
    /// pinned to the viewport stays where it is.
    func testWebViewMasksFollowAScrollAfterThePageMeasured() throws {
        let (_, root) = makeWindow()
        let web = WKWebView(frame: CGRect(x: 0, y: 40, width: 320, height: 400))
        web.scrollView.contentInsetAdjustmentBehavior = .never
        root.addSubview(web)
        try load(web, """
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
        <body style="margin:0;height:3000px">
        <input type="password" value="SECRET" style="position:absolute;left:20px;top:600px;width:100px;height:20px;border:0">
        <input type="password" value="PINNED" style="position:fixed;left:20px;top:10px;width:100px;height:20px;border:0">
        </body></html>
        """)
        let (answer, asked) = try ask(web)
        XCTAssertEqual(answer.rects.count, 2)
        XCTAssertFalse(answer.moving)

        web.scrollView.contentOffset = CGPoint(x: 0, y: 300)
        let rects = try XCTUnwrap(WebViewMasking.place(answer, in: web, asked: asked))
        XCTAssertTrue(rects.contains { $0.contains(CGRect(x: 20, y: 300, width: 100, height: 20)) },
                      "in the page's flow: \(rects)")
        XCTAssertTrue(rects.contains { $0.contains(CGRect(x: 20, y: 10, width: 100, height: 20)) },
                      "pinned to the viewport: \(rects)")
    }

    /// Once the page has caught up with the scroll view, the masks sit
    /// exactly where the content is drawn, scrolled, under an inset the app
    /// set itself (which doesn't move the page's viewport) and under a safe
    /// area (which does). Before that, an input pinned to the viewport is
    /// covered at every inset it could be drawn below. (Web views don't paint
    /// in the test host; the drawn pixels are checked in the simulator
    /// end-to-end run.)
    func testWebViewMasksAreTightOnceThePageHasCaughtUp() throws {
        for safeArea in [false, true] {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
            let vc = UIViewController()
            window.rootViewController = vc
            window.makeKeyAndVisible()
            windows.append(window)
            let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
            vc.view.addSubview(web)
            if safeArea {
                vc.additionalSafeAreaInsets = UIEdgeInsets(top: 50, left: 0, bottom: 0, right: 0)
            } else {
                web.scrollView.contentInsetAdjustmentBehavior = .never
                web.scrollView.contentInset = UIEdgeInsets(top: 50, left: 0, bottom: 0, right: 0)
            }
            vc.view.layoutIfNeeded()
            try load(web, """
            <html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
            <body style="margin:0;height:3000px">
            <input type="password" value="SECRET" style="position:absolute;left:20px;top:600px;width:100px;height:20px;border:0">
            <input type="password" value="PINNED" style="position:fixed;left:180px;top:10px;width:100px;height:20px;border:0">
            </body></html>
            """)
            // The page's viewport starts below the safe area (the test
            // window's status bar plus the 50 added here), not below an inset
            // the app set itself.
            let obscured: CGFloat = safeArea ? web.safeAreaInsets.top : 0
            XCTAssertEqual(web.scrollView.adjustedContentInset.top, safeArea ? obscured : 50)
            XCTAssertGreaterThanOrEqual(obscured, safeArea ? 50 : 0)
            web.scrollView.contentOffset = CGPoint(x: 0, y: 250)
            waitForPage(web, top: 250 + obscured)

            let (answer, asked) = try ask(web, previousOffset: web.scrollView.contentOffset)
            XCTAssertTrue(asked.settled)
            let rects = try XCTUnwrap(WebViewMasking.place(answer, in: web, asked: asked))
            let flow = CGRect(x: 20, y: 600 - 250, width: 100, height: 20)        // content y - offset
            let pinned = CGRect(x: 180, y: obscured + 10, width: 100, height: 20)  // below the safe area
            for input in [flow, pinned] {
                let mask = rects.first { $0.contains(input) }
                XCTAssertNotNil(mask, "safe area \(safeArea): \(input) uncovered by \(rects)")
                XCTAssertLessThan(mask?.height ?? .infinity, input.height + 4, "no smear once caught up: \(rects)")
            }

            // Not caught up yet (no earlier lookup): the pinned input is
            // covered below no inset through the largest one.
            let (early, earlyAsked) = try ask(web)
            XCTAssertFalse(earlyAsked.settled)
            let wide = try XCTUnwrap(WebViewMasking.place(early, in: web, asked: earlyAsked))
            for y: CGFloat in [10, obscured + 10, 60] {
                XCTAssertTrue(wide.contains { $0.contains(CGRect(x: 180, y: y, width: 100, height: 20)) },
                              "safe area \(safeArea): pinned at \(y) uncovered by \(wide)")
            }
            XCTAssertTrue(wide.contains { $0.contains(flow) })
        }
    }

    /// The page's scale (a page with no viewport tag, laid out wide and
    /// zoomed out) and the web view's page zoom are both applied.
    func testWebViewMasksScaleWithThePageAndThePageZoom() throws {
        for (head, pageZoom) in [
            ("", CGFloat(1)),
            ("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">", CGFloat(1.5)),
        ] {
            let (_, root) = makeWindow()
            let web = WKWebView(frame: CGRect(x: 0, y: 40, width: 320, height: 400))
            web.scrollView.contentInsetAdjustmentBehavior = .never
            root.addSubview(web)
            try load(web, """
            <html><head>\(head)</head><body style="margin:0;width:980px;height:2000px">
            <div class="rr-mask" style="position:absolute;left:40px;top:60px;width:100px;height:30px"></div>
            </body></html>
            """)
            if pageZoom != 1 {
                web.pageZoom = pageZoom
                waitUntil {
                    (self.evaluate(web, "document.documentElement.clientWidth") as? NSNumber)?.intValue == Int(320 / pageZoom)
                }
            } else {
                XCTAssertLessThan(web.scrollView.zoomScale, 0.5, "a wide page is shown zoomed out")
            }
            let (answer, asked) = try ask(web, previousOffset: web.scrollView.contentOffset)
            let rects = try XCTUnwrap(WebViewMasking.place(answer, in: web, asked: asked))
            let k = web.scrollView.zoomScale * pageZoom
            let input = CGRect(x: 40 * k, y: 60 * k, width: 100 * k, height: 30 * k)
            XCTAssertTrue(rects.contains { $0.contains(input) && $0.height < input.height + 4 },
                          "page zoom \(pageZoom), scale \(web.scrollView.zoomScale): \(input) not covered by \(rects)")
            // The page reports the scale and width it was laid out for.
            XCTAssertEqual(answer.scale ?? 0, web.scrollView.zoomScale, accuracy: 0.01)
            XCTAssertEqual(answer.viewportWidth ?? 0, 320, accuracy: 2)
        }
    }

    /// A web view zoomed in (a pinch, or setZoomScale) and scrolled: each
    /// input is placed at its place in the page times the zoom, minus the
    /// scroll offset. WebKit gives a zoomed page's client rects from the
    /// zoomed viewport while its visualViewport.offsetTop repeats pageTop, so
    /// the zoom offset must not be taken off twice. Found in the simulator
    /// end-to-end run: zoomed in, the mask sat over another part of the page
    /// and the password showed in every frame.
    func testWebViewMasksFollowAZoomedInPage() throws {
        let (_, root) = makeWindow()
        let web = WKWebView(frame: CGRect(x: 0, y: 40, width: 320, height: 400))
        web.scrollView.contentInsetAdjustmentBehavior = .never
        root.addSubview(web)
        try load(web, """
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=4"></head>
        <body style="margin:0;height:3000px">
        <input type="password" value="SECRET" style="position:absolute;left:60px;top:300px;width:100px;height:20px;border:0">
        </body></html>
        """)
        web.scrollView.setZoomScale(2, animated: false)
        XCTAssertEqual(web.scrollView.zoomScale, 2, accuracy: 0.001, "the page didn't zoom")
        web.scrollView.contentOffset = CGPoint(x: 80, y: 500)
        waitForPage(web, top: 250)   // 500 pt at zoom 2
        var scale: Double?
        waitUntil {
            scale = (self.evaluate(web, "window.visualViewport.scale") as? NSNumber)?.doubleValue
            return scale == 2
        }
        XCTAssertEqual(scale, 2, "the page never caught up with the zoom")

        let (answer, asked) = try ask(web, previousOffset: web.scrollView.contentOffset)
        XCTAssertTrue(asked.settled)
        let rects = try XCTUnwrap(WebViewMasking.place(answer, in: web, asked: asked))
        let input = CGRect(x: 60 * 2 - 80, y: 300 * 2 - 500, width: 100 * 2, height: 20 * 2)
        XCTAssertTrue(rects.contains { $0.contains(input) && $0.height < input.height + 4 },
                      "zoomed in: \(input) not covered by \(rects)")
    }

    /// An answer the page gave before it caught up with the web view's zoom
    /// or page zoom (just after setZoomScale, a pageZoom change, a resize)
    /// describes a drawing that isn't on screen: the web view is masked whole
    /// for that frame. Found in the simulator end-to-end run: the frame right
    /// after a pageZoom change showed the password, its mask placed for the
    /// new page zoom over the old layout.
    func testAnAnswerForAnotherZoomOrLayoutIsMaskedWhole() throws {
        let (_, root) = makeWindow()
        let web = WKWebView(frame: CGRect(x: 0, y: 40, width: 320, height: 400))
        web.scrollView.contentInsetAdjustmentBehavior = .never
        root.addSubview(web)
        try load(web, """
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=4"></head>
        <body style="margin:0;height:2000px">
        <input type="password" value="SECRET" style="position:absolute;left:20px;top:30px;width:100px;height:20px;border:0">
        </body></html>
        """)
        let (answer, asked) = try ask(web, previousOffset: web.scrollView.contentOffset)
        XCTAssertEqual(answer.scale, 1)
        XCTAssertEqual(answer.viewportWidth ?? 0, 320, accuracy: 1)
        XCTAssertNotNil(WebViewMasking.place(answer, in: web, asked: asked), "an up-to-date answer is placed")

        func page(scale: Double, width: Double, pageZoom: CGFloat) throws -> WebViewMasking.Answer {
            let value: [String: Any] = ["r": [[20.0, 30.0, 100.0, 20.0]], "o": [0.0, 0.0], "m": false,
                                        "s": scale, "w": width]
            return try XCTUnwrap(WebViewMasking.answer(from: value, pageZoom: pageZoom))
        }
        // Page zoom 1.5 set, the page still laid out for 1 (320 CSS px wide).
        web.pageZoom = 1.5
        let zoomedPage = WebViewMasking.Geometry(of: web, previousOffset: web.scrollView.contentOffset)
        XCTAssertNil(WebViewMasking.place(try page(scale: 1, width: 320, pageZoom: 1.5), in: web, asked: zoomedPage),
                     "laid out for another page zoom")
        XCTAssertNotNil(WebViewMasking.place(try page(scale: 1, width: 320 / 1.5, pageZoom: 1.5), in: web,
                                             asked: zoomedPage), "laid out for this page zoom")
        web.pageZoom = 1

        // Zoomed to 2, the page still at scale 1.
        web.scrollView.setZoomScale(2, animated: false)
        let zoomed = WebViewMasking.Geometry(of: web, previousOffset: web.scrollView.contentOffset)
        XCTAssertNil(WebViewMasking.place(try page(scale: 1, width: 320, pageZoom: 1), in: web, asked: zoomed),
                     "measured at another zoom")
        XCTAssertNotNil(WebViewMasking.place(try page(scale: 2, width: 320, pageZoom: 1), in: web, asked: zoomed),
                        "measured at this zoom")
    }

    /// Measurements taken before a zoom, or before one of the page's own
    /// scrollers moved, can't be placed: the web view is masked whole.
    func testAWebViewZoomedOrInnerScrolledSinceItWasAskedIsMaskedWhole() throws {
        let (_, root) = makeWindow()
        let web = WKWebView(frame: CGRect(x: 0, y: 40, width: 320, height: 400))
        web.scrollView.contentInsetAdjustmentBehavior = .never
        root.addSubview(web)
        try load(web, """
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
        <body style="margin:0">
        <div style="position:absolute;left:0;top:0;width:300px;height:120px;overflow:auto">
          <div style="height:1000px;position:relative">
            <input type="password" value="SECRET" style="position:absolute;left:20px;top:30px;width:100px;height:20px;border:0">
          </div>
        </div>
        </body></html>
        """)
        var (answer, asked) = try ask(web)
        XCTAssertNotNil(WebViewMasking.place(answer, in: web, asked: asked))
        let inner = try XCTUnwrap(Self.find(in: web.scrollView) { $0 !== web.scrollView && $0 is UIScrollView } as? UIScrollView,
                                  "the overflow area has no scroller of its own")
        inner.contentOffset.y += 50
        XCTAssertNil(WebViewMasking.place(answer, in: web, asked: asked), "an inner scroller moved")

        (answer, asked) = try ask(web)
        XCTAssertNotNil(WebViewMasking.place(answer, in: web, asked: asked))
        web.scrollView.setZoomScale(2, animated: false)
        XCTAssertNotEqual(web.scrollView.zoomScale, asked.zoomScale, "the page didn't zoom")
        XCTAssertNil(WebViewMasking.place(answer, in: web, asked: asked), "zoomed since")

        // A page with nothing to mask has nothing to misplace.
        let empty = WebViewMasking.Answer(rects: [], origin: .zero, moving: true)
        XCTAssertEqual(WebViewMasking.place(empty, in: web, asked: asked), [])
    }

    /// An input inside an element whose position is being animated (a login
    /// sheet sliding in) moves while the frame is taken: masked whole. An
    /// animation that doesn't move anything (a fade) doesn't count.
    func testAWebViewWithAMovingMaskedInputIsMaskedWhole() throws {
        let (_, root) = makeWindow()
        let web = WKWebView(frame: CGRect(x: 0, y: 40, width: 320, height: 400))
        root.addSubview(web)
        try load(web, """
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        @keyframes slide { from { transform: translateY(400px) } to { transform: translateY(0) } }
        @keyframes pulse { from { opacity: 1 } to { opacity: 0.6 } }
        </style></head>
        <body style="margin:0;animation:pulse 2s infinite alternate">
        <div id="sheet" style="position:absolute;left:0;top:0;width:300px;height:100px">
          <input type="password" value="SECRET" style="width:100px;height:20px;border:0">
        </div>
        </body></html>
        """)
        var (answer, asked) = try ask(web)
        XCTAssertFalse(answer.moving, "a fade doesn't move the input")
        XCTAssertNotNil(WebViewMasking.place(answer, in: web, asked: asked))

        _ = evaluate(web, "document.getElementById('sheet').style.animation = 'slide 5s infinite'; 1")
        (answer, asked) = try ask(web)
        XCTAssertTrue(answer.moving)
        XCTAssertNil(WebViewMasking.place(answer, in: web, asked: asked))
    }

    /// Password inputs rendered inside web components' open shadow roots,
    /// nested ones included, are found.
    func testPasswordInputsInsideShadowRootsAreMasked() throws {
        let (_, root) = makeWindow()
        let web = WKWebView(frame: CGRect(x: 0, y: 40, width: 320, height: 400))
        web.scrollView.contentInsetAdjustmentBehavior = .never
        root.addSubview(web)
        try load(web, """
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
        <body style="margin:0">
        <x-field id="outer"></x-field>
        <script>
        var input = '<input type="password" value="SECRET" style="position:absolute;left:20px;width:100px;height:20px;border:0;top:';
        var outer = document.getElementById('outer').attachShadow({ mode: 'open' });
        outer.innerHTML = input + '30px"><x-inner id="inner"></x-inner>';
        outer.getElementById('inner').attachShadow({ mode: 'open' }).innerHTML = input + '80px">';
        </script>
        </body></html>
        """)
        let (answer, _) = try ask(web)
        for top in [30, 80] {
            let input = CGRect(x: 20, y: top, width: 100, height: 20)
            XCTAssertTrue(answer.rects.contains { $0.insetBy(dx: -0.5, dy: -0.5).contains(input) },
                          "shadow input at \(top): \(answer.rects)")
        }
    }

    /// A frame of another origin can't be read into. It is masked whole when
    /// its attributes say it may take a card, a code or a password; other
    /// embeds stay visible. Same-origin frames are looked into.
    func testOnlyCredentialFramesOfAnotherOriginAreMaskedWhole() throws {
        let (_, root) = makeWindow()
        let web = WKWebView(frame: CGRect(x: 0, y: 40, width: 320, height: 400))
        web.scrollView.contentInsetAdjustmentBehavior = .never
        root.addSubview(web)
        let frame = "position:absolute;left:0;width:300px;border:0;"
        try load(web, """
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
        <body style="margin:0">
        <iframe sandbox title="Secure card payment input frame" srcdoc="<input>" style="\(frame)top:0;height:60px"></iframe>
        <iframe sandbox title="Video player" srcdoc="<p>video</p>" style="\(frame)top:80px;height:150px"></iframe>
        <iframe sandbox allow="payment" srcdoc="<p>pay</p>" style="\(frame)top:250px;height:40px"></iframe>
        <iframe srcdoc="<body style='margin:0'><input type=password style='position:absolute;left:10px;top:5px;width:50px;height:20px;border:0'></body>"
                style="\(frame)top:310px;height:40px"></iframe>
        </body></html>
        """)
        let (answer, _) = try ask(web)
        func covered(_ r: CGRect) -> Bool { answer.rects.contains { $0.insetBy(dx: -0.5, dy: -0.5).contains(r) } }
        XCTAssertTrue(covered(CGRect(x: 0, y: 0, width: 300, height: 60)), "card frame: \(answer.rects)")
        XCTAssertTrue(covered(CGRect(x: 0, y: 250, width: 300, height: 40)), "payment frame: \(answer.rects)")
        XCTAssertFalse(answer.rects.contains { $0.intersects(CGRect(x: 0, y: 81, width: 300, height: 148)) },
                       "the video embed stays visible: \(answer.rects)")
        XCTAssertTrue(covered(CGRect(x: 10, y: 315, width: 50, height: 20)), "same-origin frame input: \(answer.rects)")
        XCTAssertEqual(answer.rects.count, 3, "\(answer.rects)")
    }

    // MARK: - Helpers

    private func resetPrivacy() {
        registry.clear()
        registry.occludeAllScreen = false
        registry.hideScreenGestures = false
        registry.occludeAllTextFields = false
        registry.remoteOccludeAllTextFields = false
        registry.occludeAllTextViews = false
        registry.maskStyle = .overlay
        registry.blurRadius = 8
        registry.webViewMaskingEnabled = true
        registry.webViews.endFrame()
        registry.webViews.endFrame()
        _ = registry.consumePendingFrameRects()
    }

    private func makeWindow() -> (UIWindow, UIView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.backgroundColor = .white
        let root = UIView(frame: window.bounds)
        window.addSubview(root)
        window.makeKeyAndVisible()
        windows.append(window)
        return (window, root)
    }

    @discardableResult
    private func field(in parent: UIView, y: CGFloat = 40, secure: Bool = false) -> UITextField {
        let f = UITextField(frame: CGRect(x: 20, y: y, width: 200, height: 40))
        f.isSecureTextEntry = secure
        parent.addSubview(f)
        return f
    }

    private func label(in parent: UIView, _ text: String, y: CGFloat) -> UILabel {
        let l = UILabel(frame: CGRect(x: 20, y: y, width: 200, height: 40))
        l.text = text
        parent.addSubview(l)
        return l
    }

    private func assertContentTypeIsMasked(_ type: UITextContentType, line: UInt = #line) {
        let (window, root) = makeWindow()
        let f = field(in: root)
        f.textContentType = type
        XCTAssertTrue(isCovered(f, by: registry.bulkBounds(within: window), in: window),
                      "\(type.rawValue) not masked", line: line)
    }

    private func isCovered(_ view: UIView, by rects: [CGRect], in window: UIWindow) -> Bool {
        let frame = view.convert(view.bounds, to: window)
        return rects.contains { $0.contains(frame) }
    }

    private func style(of view: UIView, in rects: [MaskRect], window: UIWindow) -> ReplayMaskStyle? {
        let frame = view.convert(view.bounds, to: window)
        return rects.first { $0.rect.contains(frame) }?.style
    }

    private func assertUnrenderableRegionIsSolid(_ style: ReplayMaskStyle) throws {
        let size = CGSize(width: 100, height: 100)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let source = try XCTUnwrap(UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.magenta.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }.cgImage)
        let rect = CGRect(x: 20, y: 20, width: 40, height: 40)
        let out = try render(source, size: size, scale: 1, rects: [MaskRect(rect: rect, style: style)]) { _, _ in nil }
        let px = try XCTUnwrap(Pixels(out))
        XCTAssertTrue(px.isOverlayGray(40, 40), "centre = \(px.rgb(40, 40))")
        XCTAssertTrue(px.isOverlayGray(21, 21) && px.isOverlayGray(58, 58), "edges")
        XCTAssertFalse(px.isOverlayGray(10, 10), "outside the rect is untouched")
    }

    /// Draw `source` and mask it exactly as the screenshotter does.
    private func render(_ source: CGImage, size: CGSize, scale: CGFloat, rects: [MaskRect],
                        render: ((CGImage, ReplayMaskStyle) -> UIImage?)?) throws -> CGImage {
        let shots = MobileScreenshots(transport: StubUploader(), nativeCapture: false, privacyRects: { [] })
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIImage(cgImage: source, scale: scale, orientation: .up).draw(in: CGRect(origin: .zero, size: size))
            shots.maskRegions(rects, from: source, in: ctx.cgContext, scale: scale, render: render)
        }
        return try XCTUnwrap(image.cgImage)
    }

    /// Vertical stripes 3 px wide in four colours, so any shift shows.
    private static func stripes(size: CGSize, scale: CGFloat) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.preferredRange = .standard
        let colors: [UIColor] = [.red, .green, .blue, .yellow]
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let w = 3 / scale
            var x: CGFloat = 0, i = 0
            while x < size.width {
                colors[i % colors.count].setFill()
                ctx.fill(CGRect(x: x, y: 0, width: w, height: size.height))
                x += w; i += 1
            }
        }.cgImage
    }

    private static let magentaPNG: Data = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 60, height: 90), format: format).pngData { ctx in
            UIColor.magenta.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 90))
        }
    }()

    /// The shared engine, live with host-fed frames over a stub upload path.
    private func goLiveHostFed(_ uploader: StubUploader) -> MobileScreenshots {
        let previous = core.applicationState
        core.applicationState = { .active }
        addTeardownBlock { [core] in core.applicationState = previous }
        OptOutStore.shared.schematicOptOut = false
        core.resumeCapture()
        let shots = MobileScreenshots(transport: uploader, nativeCapture: false, privacyRects: { [] })
        core.attachFrames(shots, nativeCapture: false)
        return shots
    }

    private func hostOccludedButton(blockGestures: Bool) throws -> (UIWindow, UIView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        windows.append(window)
        let content = Button("Go") {}
            .frame(width: 200, height: 60)
            .replayOcclude(blockGestures: blockGestures)
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
        var marker: UIView?
        waitUntil {
            window.rootViewController?.view.layoutIfNeeded()
            marker = Self.find(in: window, Self.isMarker)
            return marker != nil && marker!.bounds.width > 0
        }
        return (window, try XCTUnwrap(marker, "the marker never appeared"))
    }

    private static func isMarker(_ v: UIView) -> Bool {
        String(describing: type(of: v)).contains("PrivacyMarkerView")
    }

    private static func find(in view: UIView, _ match: (UIView) -> Bool) -> UIView? {
        if match(view) { return view }
        for sub in view.subviews { if let hit = find(in: sub, match) { return hit } }
        return nil
    }

    private func load(_ web: WKWebView, _ html: String) throws {
        let loaded = WebLoad()
        web.navigationDelegate = loaded
        web.loadHTMLString(html, baseURL: nil)
        waitUntil(timeout: 20) { loaded.done }
        XCTAssertTrue(loaded.done, "the page never loaded")
        _ = loaded
        // Let the first layer commits land (initial zoom, the page's own
        // scrollers) before the test measures anything.
        spin(0.5)
    }

    /// One native capture cycle: look the web views up, then walk the frame.
    private func nextFrame(in window: UIWindow) throws -> [MaskRect] {
        var ready = false
        registry.prepareFrame { ready = true }
        waitUntil(timeout: 2) { ready }
        XCTAssertTrue(ready, "prepareFrame never called back")
        return registry.windowPrivacyBounds(in: window)
    }

    /// Ask `web` for its masked inputs as a capture does, with no deadline.
    /// `previousOffset`: the scroll view's offset at the previous lookup.
    private func ask(_ web: WKWebView, previousOffset: CGPoint? = nil,
                     allFields: Bool = false) throws -> (WebViewMasking.Answer, WebViewMasking.Geometry) {
        let asked = WebViewMasking.Geometry(of: web, previousOffset: previousOffset)
        var value: Any?
        var done = false
        let script = allFields ? WebViewMasking.allFieldsScript : WebViewMasking.passwordScript
        web.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
            if case .success(let v) = result { value = v }
            if case .failure(let e) = result { XCTFail("the lookup failed: \(e)") }
            done = true
        }
        waitUntil(timeout: 5) { done }
        let answer = try XCTUnwrap(value.flatMap { WebViewMasking.answer(from: $0, pageZoom: asked.pageZoom) },
                                   "malformed answer: \(String(describing: value))")
        return (answer, asked)
    }

    private func evaluate(_ web: WKWebView, _ js: String) -> Any? {
        var value: Any?
        var done = false
        web.evaluateJavaScript(js) { v, _ in value = v; done = true }
        waitUntil(timeout: 5) { done }
        return value
    }

    /// Wait until the page itself has scrolled to `top` (CSS px).
    private func waitForPage(_ web: WKWebView, top: Double, line: UInt = #line) {
        var seen: Double?
        waitUntil {
            seen = (self.evaluate(web, "window.visualViewport.pageTop") as? NSNumber)?.doubleValue
            return seen == top
        }
        XCTAssertEqual(seen, top, "the page never caught up with the scroll view", line: line)
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}

/// Stands in for a hosting view that spans the screen under a marker.
private final class HostLikeView: UIView {}

/// Stands in for an engine host view (named like one), whose taps are
/// dropped.
private final class FlutterStandInView: UIView {}

/// Stands in for a view class an app masks everywhere with applyOcclusion.
private final class CardStandInView: UIView {}

private final class WebLoad: NSObject, WKNavigationDelegate {
    var done = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
}

/// 8-bit RGBA copy of an image, top-left origin.
private struct Pixels {
    let data: [UInt8]
    let width: Int
    let height: Int

    init?(_ cg: CGImage) {
        width = cg.width
        height = cg.height
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &buf, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        data = buf
    }

    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let o = (y * width + x) * 4
        return (Int(data[o]), Int(data[o + 1]), Int(data[o + 2]))
    }

    /// The overlay fill, white 0.22 ≈ rgb(56, 56, 56), within JPEG noise.
    func isOverlayGray(_ x: Int, _ y: Int) -> Bool {
        let (r, g, b) = rgb(x, y)
        return abs(r - 56) <= 10 && abs(g - 56) <= 10 && abs(b - 56) <= 10
    }

    func distance(to other: Pixels, _ x: Int, _ y: Int) -> Int {
        let (r1, g1, b1) = rgb(x, y), (r2, g2, b2) = other.rgb(x, y)
        return max(abs(r1 - r2), abs(g1 - g2), abs(b1 - b2))
    }
}
#endif
