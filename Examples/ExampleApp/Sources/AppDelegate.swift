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
        // SDK boot. apiHost points at host machine's loopback as seen
        // from the simulator — `127.0.0.1` (or `localhost`) works
        // directly on iOS Simulator (unlike Android emulator's
        // 10.0.2.2 NAT alias) because the simulator shares the host's
        // network namespace. Port 4000 is the local ingest-api.
        Replay.start(
            with: ReplayConfig(
                apiKey: "rpl_pk_ef7e2fc8c7f952bcd0a69466e1a42a0625f9",
                apiHost: "http://127.0.0.1:4000",
                captureSnapshotPixels: true
            )
        )
        NSLog("[ReplayExample] Replay.start dispatched — see ReplaySdk-tagged logs")

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
