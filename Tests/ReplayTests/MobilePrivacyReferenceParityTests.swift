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
///   • password inputs inside web views are masked, and a web view that
///     hasn't answered is masked whole.
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
    }

    /// One native capture cycle: look the web views up, then walk the frame.
    private func nextFrame(in window: UIWindow) throws -> [MaskRect] {
        var ready = false
        registry.prepareFrame { ready = true }
        waitUntil(timeout: 2) { ready }
        XCTAssertTrue(ready, "prepareFrame never called back")
        return registry.windowPrivacyBounds(in: window)
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
