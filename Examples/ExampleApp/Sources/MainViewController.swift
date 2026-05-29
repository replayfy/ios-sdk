import UIKit
import Replay

/// End-to-end smoke-test screen for the Replay iOS SDK.
///
/// Mirrors the Android example app's validation surfaces so we get
/// parity coverage across both platforms:
///
///   1. UIButton tap probes — fires TapEvents the SDK records.
///   2. CALayer-painted gradient view — software-painted by UIKit,
///      should be captured by the snapshot pipeline as a regular
///      view-hierarchy render.
///   3. Hardware-surface view via `CAEAGLLayer` / `CAMetalLayer`
///      analog: a CALayer gradient that lives on a background-
///      composited layer, useful to validate the snapshot path
///      sees content drawn by the GPU (the iOS analog of Android's
///      SurfaceView hole-punch issue).
///   4. Sensitive UITextField — marked via `Replay.addPrivacyView(_:)`,
///      should appear occluded in snapshots and taps inside ship
///      with `isSensitive: true`.
///   5. "Trigger Hang" button — blocks main with `Thread.sleep(7)`.
///      The `HangWatchdog` should detect within ~5s and emit
///      `anr_ms` perf event same shape as Android.
///
/// Watch via `xcrun simctl spawn booted log stream --predicate
/// 'subsystem == "io.replayfy.example"'` or just `os_log` in the
/// Xcode console.
final class MainViewController: UIViewController {

    private var tapCount = 0
    private let tapLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // Tag this screen so the SDK timeline shows it on session
        // events. Equivalent of Android's tagScreenName(name).
        Replay.tagScreenName("MainViewController")

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 24, left: 20, bottom: 24, right: 20)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])

        // --- 1. tap probes -------------------------------------------
        tapLabel.text = "Taps recorded: 0"
        tapLabel.font = .systemFont(ofSize: 18, weight: .medium)
        stack.addArrangedSubview(tapLabel)

        let tapButton = UIButton(type: .system)
        tapButton.setTitle("Tap me (normal button)", for: .normal)
        tapButton.titleLabel?.font = .systemFont(ofSize: 16)
        tapButton.contentEdgeInsets = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        tapButton.backgroundColor = .systemBlue
        tapButton.setTitleColor(.white, for: .normal)
        tapButton.layer.cornerRadius = 8
        tapButton.addTarget(self, action: #selector(handleTap(_:)), for: .touchUpInside)
        stack.addArrangedSubview(tapButton)

        // --- 2. gradient view (CALayer / Core Animation) -------------
        stack.addArrangedSubview(label("Gradient #1 (MAGENTA→CYAN→YELLOW) — UIKit-painted, should appear in snapshot"))
        let grad1 = GradientLayerView(
            colors: [UIColor.magenta.cgColor, UIColor.cyan.cgColor, UIColor.yellow.cgColor]
        )
        grad1.translatesAutoresizingMaskIntoConstraints = false
        grad1.heightAnchor.constraint(equalToConstant: 140).isActive = true
        stack.addArrangedSubview(grad1)

        // --- 3. occluded gradient — privacy overlay test -------------
        stack.addArrangedSubview(label("Gradient #2 (RED→GREEN→BLUE) — marked sensitive, should show occlusion overlay"))
        let grad2 = GradientLayerView(
            colors: [UIColor.red.cgColor, UIColor.green.cgColor, UIColor.blue.cgColor]
        )
        grad2.translatesAutoresizingMaskIntoConstraints = false
        grad2.heightAnchor.constraint(equalToConstant: 140).isActive = true
        stack.addArrangedSubview(grad2)
        Replay.addPrivacyView(grad2)

        // --- 4. Hang trigger -----------------------------------------
        let hangButton = UIButton(type: .system)
        hangButton.setTitle("Trigger Hang (blocks main 7s — watchdog should flag at ~5s)", for: .normal)
        hangButton.titleLabel?.font = .systemFont(ofSize: 14)
        hangButton.titleLabel?.numberOfLines = 0
        hangButton.titleLabel?.textAlignment = .center
        hangButton.contentEdgeInsets = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        hangButton.backgroundColor = .systemOrange
        hangButton.setTitleColor(.white, for: .normal)
        hangButton.layer.cornerRadius = 8
        hangButton.addTarget(self, action: #selector(handleHang), for: .touchUpInside)
        stack.addArrangedSubview(hangButton)

        // --- 5. Privacy text field -----------------------------------
        stack.addArrangedSubview(label("Sensitive text field — taps + snapshots should occlude it:"))
        let field = UITextField()
        field.placeholder = "Pretend this is a credit card #"
        field.borderStyle = .roundedRect
        field.font = .systemFont(ofSize: 16)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.heightAnchor.constraint(equalToConstant: 44).isActive = true
        stack.addArrangedSubview(field)
        Replay.addPrivacyView(field)
    }

    @objc private func handleTap(_ sender: UIButton) {
        tapCount += 1
        tapLabel.text = "Taps recorded: \(tapCount)"
    }

    @objc private func handleHang() {
        NSLog("[ReplayExample] Blocking main for 7s — expect anr_ms event from watchdog")
        Thread.sleep(forTimeInterval: 7.0)
        NSLog("[ReplayExample] Main unblocked")
    }

    private func label(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 13)
        l.textColor = .secondaryLabel
        l.numberOfLines = 0
        return l
    }
}

/// A UIView backed by a CAGradientLayer. CAGradientLayer is a
/// Core Animation layer — its content is painted by the system
/// compositor, not by `drawRect:`. This validates that the
/// snapshot pipeline picks up Core-Animation-rendered content
/// (the closest iOS analog of Android's SurfaceView question).
final class GradientLayerView: UIView {

    override class var layerClass: AnyClass { CAGradientLayer.self }

    init(colors: [CGColor]) {
        super.init(frame: .zero)
        let g = layer as! CAGradientLayer
        g.colors = colors
        g.startPoint = CGPoint(x: 0, y: 0)
        g.endPoint = CGPoint(x: 1, y: 1)
        layer.cornerRadius = 8
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }
}
