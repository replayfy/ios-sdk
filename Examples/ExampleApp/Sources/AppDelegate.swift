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
                apiKey: "rpl_pk_97f6b1ce7235126b0cc017716e81fe12849e",
                apiHost: "http://127.0.0.1:4000",
                captureSnapshotPixels: true
            )
        )
        NSLog("[ReplayExample] Replay.start dispatched — see ReplaySdk-tagged logs")

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = MainViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
