import UIKit
import WebKit
import Replay

/// End-to-end fixture for the default masking rules. Launch with
/// `-replayPrivacyDemo 1` (see AppDelegate) to make it the root screen.
///
/// Every view the SDK must mask has a MAGENTA background, so a single magenta
/// pixel in a captured frame is a leak. What must stay visible is CYAN (the
/// plain text field) or YELLOW (the plain text view). In the web page each
/// input sits in a GREEN ring a few px wide: a mask that drifts off its input
/// shows magenta on one side, and one that is far too big hides the ring.
///
/// The screen is driven from the host, not by timers, so a test can hold each
/// state for as many frames as it needs: append lines `<seq> <command> [arg]`
/// to `Documents/e2e-cmd.txt` in the app's data container. After each command
/// the screen appends one JSON line to `Documents/e2e-log.jsonl` with the time
/// (epoch ms, the clock the frames carry) and every element's window rect, so
/// the frames can be checked against where things actually are.
///
/// Commands:
///   occlude 1|0       Replay.occludeSensitiveScreen
///   allfields 1|0     Replay.occludeAllTextFields (the app's own flag)
///   webscroll <y>     scroll the web view to y (points)
///   webzoom <scale>   zoom the web view's scroll view
///   pagezoom <z>      WKWebView.pageZoom
///   inputs            end editing on every observed field, then trackInput
///   mark <name>       custom event, to find a phase in the message stream
///   stop              Replay.stop() (uploads everything buffered)
final class PrivacyDemoViewController: UIViewController {

    static let magenta = UIColor(red: 1, green: 0, blue: 1, alpha: 1)
    static let cyan = UIColor(red: 0, green: 1, blue: 1, alpha: 1)
    static let yellow = UIColor(red: 1, green: 1, blue: 0, alpha: 1)

    // Masked by default (secure entry and the four secure content types).
    private let secureField = PrivacyDemoViewController.field("Secure", "SECRET123", magenta)
    private let otpField = PrivacyDemoViewController.field("OTP", "123456", magenta)
    private let cardField = PrivacyDemoViewController.field("Card", "4111111111111111", magenta)
    private let passwordTypeField = PrivacyDemoViewController.field("PwType", "hunter2", magenta)
    // Visible by default; masked only when every text field is.
    private let plainField = PrivacyDemoViewController.field("Plain", "PLAINTEXT", cyan)
    private let textView = UITextView()
    // Registered with Replay.addPrivacyView.
    private let privacyContainer = UIView()
    private let privacyLabel = UILabel()
    private let plainButton = UIButton(type: .system)
    private let occludeButton = UIButton(type: .system)
    private let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())

    private var occluded = false
    private var lastSeq = 0
    private var poll: Timer?
    private var plainTaps = 0

    private static func field(_ placeholder: String, _ text: String, _ bg: UIColor) -> UITextField {
        let f = UITextField()
        f.placeholder = placeholder
        f.text = text
        f.backgroundColor = bg
        f.textColor = .black
        f.font = .systemFont(ofSize: 18, weight: .semibold)
        f.borderStyle = .none
        f.autocorrectionType = .no
        f.autocapitalizationType = .none
        return f
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Privacy Demo"
        view.backgroundColor = .white

        secureField.isSecureTextEntry = true
        otpField.textContentType = .oneTimeCode
        cardField.textContentType = .creditCardNumber
        passwordTypeField.textContentType = .password

        textView.text = "NOTES"
        textView.backgroundColor = Self.yellow
        textView.textColor = .black
        textView.font = .systemFont(ofSize: 18, weight: .semibold)
        textView.isScrollEnabled = false

        privacyContainer.backgroundColor = Self.magenta
        privacyLabel.text = "PRIVATE-LABEL"
        privacyLabel.textColor = .white
        privacyLabel.font = .systemFont(ofSize: 18, weight: .bold)
        privacyLabel.isUserInteractionEnabled = true
        privacyContainer.addSubview(privacyLabel)
        Replay.addPrivacyView(privacyContainer)

        plainButton.setTitle("PLAIN-BUTTON", for: .normal)
        plainButton.backgroundColor = UIColor(white: 0.9, alpha: 1)
        plainButton.addTarget(self, action: #selector(plainTapped), for: .touchUpInside)
        occludeButton.setTitle("OCCLUDE-TOGGLE", for: .normal)
        occludeButton.backgroundColor = UIColor(white: 0.9, alpha: 1)
        occludeButton.addTarget(self, action: #selector(toggleOcclusion), for: .touchUpInside)

        for v: UIView in [secureField, otpField, cardField, passwordTypeField, plainField, textView,
                          privacyContainer, plainButton, occludeButton, webView] {
            view.addSubview(v)
        }
        for f in [secureField, otpField, cardField, plainField] {
            Replay.addObservedInput(f)
        }

        webView.scrollView.backgroundColor = .white
        webView.loadHTMLString(Self.loginPage, baseURL: URL(string: "https://privacy-demo.test/"))
        Replay.tagScreenName("PrivacyDemo")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Whole points, so the masks start on whole pixels too.
        let top = view.safeAreaInsets.top.rounded(.up) + 8
        let w = view.bounds.width - 32
        var y = top
        func place(_ v: UIView, _ h: CGFloat) {
            v.frame = CGRect(x: 16, y: y, width: w, height: h)
            y += h + 6
        }
        for f in [secureField, otpField, cardField, passwordTypeField, plainField] { place(f, 36) }
        place(textView, 40)
        place(privacyContainer, 36)
        privacyLabel.frame = privacyContainer.bounds.insetBy(dx: 8, dy: 0)
        place(plainButton, 36)
        place(occludeButton, 36)
        let bottom = view.bounds.height - view.safeAreaInsets.bottom.rounded(.up) - 8
        webView.frame = CGRect(x: 16, y: y, width: w, height: max(120, bottom - y))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The app's own flag off: the dashboard's force must still apply.
        Replay.occludeAllTextFields(false)
        if poll == nil {
            let p = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.readCommands() }
            RunLoop.main.add(p, forMode: .common)
            poll = p
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.logState(cmd: "ready", seq: 0) }
    }

    @objc private func plainTapped() {
        plainTaps += 1
        plainButton.setTitle("PLAIN-BUTTON", for: .normal)
        NSLog("[ReplayExample] plain button tapped (\(plainTaps))")
    }

    @objc private func toggleOcclusion() {
        occluded.toggle()
        Replay.occludeSensitiveScreen(occluded)
        NSLog("[ReplayExample] whole-screen occlusion \(occluded ? "ON" : "OFF") (button)")
        logState(cmd: "toggle \(occluded ? 1 : 0)", seq: -1)
    }

    // MARK: - Host commands

    private var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func readCommands() {
        guard let text = try? String(contentsOf: documents.appendingPathComponent("e2e-cmd.txt"), encoding: .utf8)
        else { return }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count >= 2, let seq = Int(parts[0]), seq > lastSeq else { continue }
            lastSeq = seq
            run(parts[1], parts.count > 2 ? parts[2] : "", seq: seq)
        }
    }

    private func run(_ cmd: String, _ arg: String, seq: Int) {
        NSLog("[ReplayExample] e2e command \(seq): \(cmd) \(arg)")
        switch cmd {
        case "occlude":
            occluded = arg == "1"
            Replay.occludeSensitiveScreen(occluded)
        case "allfields":
            Replay.occludeAllTextFields(arg == "1")
        case "webscroll":
            webView.scrollView.setContentOffset(CGPoint(x: 0, y: CGFloat(Double(arg) ?? 0)), animated: false)
        case "webzoom":
            webView.scrollView.setZoomScale(CGFloat(Double(arg) ?? 1), animated: false)
        case "pagezoom":
            webView.pageZoom = CGFloat(Double(arg) ?? 1)
        case "inputs":
            for f in [secureField, otpField, cardField, plainField] {
                f.becomeFirstResponder()
                f.resignFirstResponder()
            }
            Replay.trackInput(label: "track-plain", value: "TRACKVALUE", masked: false)
            Replay.trackInput(label: "track-secure", value: "TRACKSECRET", masked: true)
        case "mark":
            Replay.track("e2e_mark", properties: ["name": arg])
        case "stop":
            Replay.stop()
        default:
            break
        }
        // Log once the change has been laid out and drawn.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.logState(cmd: "\(cmd) \(arg)", seq: seq)
        }
    }

    private func logState(cmd: String, seq: Int) {
        func r(_ v: UIView) -> [Double] {
            let f = v.convert(v.bounds, to: nil)
            return [f.minX, f.minY, f.width, f.height].map { Double($0) }
        }
        let sv = webView.scrollView
        var state: [String: Any] = [
            "t": Int64(Date().timeIntervalSince1970 * 1000),
            "seq": seq,
            "cmd": cmd,
            "occluded": occluded,
            "window": r(view.window ?? view),
            "rects": [
                "secure": r(secureField), "otp": r(otpField), "card": r(cardField),
                "pwType": r(passwordTypeField), "plain": r(plainField), "textView": r(textView),
                "privacy": r(privacyContainer), "privacyLabel": r(privacyLabel),
                "plainButton": r(plainButton), "occludeButton": r(occludeButton), "web": r(webView),
            ],
            "webScroll": [
                "offset": [Double(sv.contentOffset.x), Double(sv.contentOffset.y)],
                "zoomScale": Double(sv.zoomScale), "pageZoom": Double(webView.pageZoom),
                "adjustedInsetTop": Double(sv.adjustedContentInset.top),
            ],
        ]
        let js = """
        (function(){function r(id){var b=document.getElementById(id).getBoundingClientRect();\
        return [b.left,b.top,b.width,b.height];}var v=window.visualViewport;\
        return JSON.stringify({pw:r('pw'),pwwrap:r('pwwrap'),user:r('user'),\
        vv:v?[v.offsetLeft,v.offsetTop,v.pageLeft,v.pageTop,v.scale,v.width,v.height]:null});})()
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            if let s = result as? String { state["page"] = s }
            self?.append(state)
        }
    }

    private func append(_ state: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: state) else { return }
        let url = documents.appendingPathComponent("e2e-log.jsonl")
        var line = data
        line.append(0x0A)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line)
            try? h.close()
        } else {
            try? line.write(to: url)
        }
    }

    /// A sign-in page: a text input and a password input, each in a green
    /// ring, and a long tail so the page can scroll.
    private static let loginPage = """
    <!doctype html><html><head>
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=4, user-scalable=yes">
    <style>
      body { margin: 0; background: #DDEEFF; font: 16px -apple-system, sans-serif; }
      .ring { padding: 6px; margin: 10px 16px; background: #00FF00; }
      input { display: block; width: 100%; box-sizing: border-box; height: 36px; border: 0;
              font: 18px -apple-system, sans-serif; color: #000; }
      #user { background: #00FFFF; }
      #pw { background: #FF00FF; }
      .tail { height: 1600px; background: linear-gradient(#DDEEFF, #FFE8CC); }
    </style></head><body>
    <div style="height:40px;padding:8px 16px">Sign in</div>
    <div class="ring" id="userwrap"><input id="user" type="text" value="webuser"></div>
    <div class="ring" id="pwwrap"><input id="pw" type="password" value="websecret"></div>
    <div class="tail"></div>
    </body></html>
    """
}
