import UIKit
import Replay

/// Bootstraps the SDK + mounts MainViewController as the root.
///
/// Why a plain AppDelegate (no SceneDelegate): smoke tests want the
/// shortest possible launch path. SceneDelegate adds 100+ ms of
/// scene-session bookkeeping that doesn't earn its keep here.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Multi-session gate must be set BEFORE start() to record exactly one
        // session (setting it after start leaves the current session + one more
        // allowed, per the reference's "current/next still allowed" semantics).
        if ProcessInfo.processInfo.environment["REPLAY_MULTISESSION"] == "0" {
            Replay.setMultiSessionRecord(false)
            NSLog("[ReplayExample] multi-session DISABLED before start (one session this process)")
        }

        // SDK boot. apiHost points at host machine's loopback as seen
        // from the simulator — `127.0.0.1` (or `localhost`) works
        // directly on iOS Simulator (unlike Android emulator's
        // 10.0.2.2 NAT alias) because the simulator shares the host's
        // network namespace. Port 4000 is the local ingest-api.
        Replay.start(
            with: ReplayConfig(
                apiKey: "rpl_pk_ef7e2fc8c7f952bcd0a69466e1a42a0625f9",
                apiHost: "http://127.0.0.1:4000",
                captureSnapshotPixels: true,
                // Demo: exclude the Menu screen from replay — frames pause while
                // it's foreground and resume on "Game". (Screen-exclusion feature.)
                excludedScreens: ["Menu"]
            )
        )
        NSLog("[ReplayExample] Replay.start dispatched — see ReplaySdk-tagged logs")

        // Test scaffolding — drive the new engine features from launch env vars
        // so scenarios can be exercised without a rebuild:
        //   REPLAY_ADV_GESTURES=1        → enable pinch/rotate capture
        //   REPLAY_SHORTBREAK_SECS=5     → short-break window (rotate after N s bg)
        //   REPLAY_MULTISESSION=0        → record exactly one session this process
        let env = ProcessInfo.processInfo.environment
        if env["REPLAY_ADV_GESTURES"] == "1" {
            Replay.enableAdvancedGestureRecognizer(true)
            NSLog("[ReplayExample] advanced gestures ENABLED")
        }
        if let s = env["REPLAY_SHORTBREAK_SECS"], let secs = TimeInterval(s) {
            Replay.allowShortBreakForAnotherApp(true, windowSeconds: secs)
            NSLog("[ReplayExample] short-break window = \(secs)s")
        }
        if let s = env["REPLAY_CANCEL_AFTER_SECS"], let secs = TimeInterval(s) {
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
                NSLog("[ReplayExample] >>> calling cancelSession() — batches should STOP after this")
                Replay.cancelSession()
                // Prove a fresh session can still start after a cancel.
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    NSLog("[ReplayExample] >>> calling startNewSession() after cancel")
                    Replay.startNewSession()
                }
            }
        }

        // Headless crash-test hook. Launch with
        //   SIMCTL_CHILD_REPLAY_AUTOCRASH=nsexception (or =signal)
        //   xcrun simctl launch <udid> <bundle-id>
        // to fire a crash ~6s after start (enough for the session to
        // register + the first frames/events to flow) without a UI tap.
        //   nsexception → caught in-process by MobileCrashHandler →
        //                 MobileWire.crash + flushBlocking (same session).
        //   signal      → SIGSEGV; PLCrashReporter records it, recovered +
        //                 emitted on the NEXT launch.
        if let mode = ProcessInfo.processInfo.environment["REPLAY_AUTOCRASH"],
           !mode.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                NSLog("[ReplayExample] auto-crash: \(mode)")
                switch mode {
                case "signal":
                    // Null-pointer write → SIGSEGV / EXC_BAD_ACCESS.
                    UnsafeMutablePointer<Int>(bitPattern: 0x1)!.pointee = 42
                case "nsexception":
                    fallthrough
                default:
                    NSException(
                        name: NSExceptionName("ReplayAutoCrash"),
                        reason: "Headless auto-crash: \(mode)",
                        userInfo: nil
                    ).raise()
                }
            }
        }

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: MainViewController())
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
