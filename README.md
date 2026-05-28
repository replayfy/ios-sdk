# Replay iOS SDK

Session replay + analytics for iOS apps. Swift Package Manager.

## Status

**Foundation only — not production-ready.** Public API is in place
but the recording engine ships in follow-up commits, mirroring the
Android SDK's incremental rollout:

- ✅ Public API surface (`Replay.start` / `identify` / `track` / `stop` / `isRecording`)
- ✅ URLSession-based BatchSender (POST `/v1/replay/batch`)
- ✅ UIApplication notification observer (fore/background session boundaries)
- ✅ SessionRuntime with serial-queue thread safety
- ✅ Device context (model identifier, viewport, locale, timezone)
- ✅ Tap tracker — `UIGestureRecognizer` injected per window, walks
  hit-test result up to the most-specific meaningful ancestor,
  classifies + extracts value, emits `tap` events
- ✅ Manual screen tagging (`Replay.tagScreenName`)
- ✅ Snapshot pipeline (tree-only) — `ViewTreeSerializer` walks the
  UIView hierarchy and emits `native_snapshot` events. Triggered on
  500ms idle after every tap + immediate on `tagScreenName`. Player
  renders a wireframe today; full bitmap follows in the next commit.
- ⏳ Snapshot pipeline (bitmap) — `UIView.drawHierarchy` + asset upload
- ⏳ Persistent upload queue — background URLSession + on-disk persistence
- ⏳ Network capture — `URLProtocol` swizzle
- ⏳ Crash handler — `NSSetUncaughtExceptionHandler` + signal handlers
- ⏳ Occlusion / privacy views
- ⏳ Native performance metrics (cold_start_ms, frame drops, memory, etc.)
- ⏳ SwiftUI view modifiers (`.replayOcclude()` / `.replayTagScreenName()`)

Each ⏳ corresponds to a follow-up commit; see the design docs in
the `replay-web-sdk` repo (`mobile-vitals-matrix.md`,
`native-snapshot-format.md`).

## Quick start

Add to your app's `Package.swift` or via Xcode → File → Add Package
Dependencies:

```
https://github.com/replayfy/ios-sdk.git
```

Then in your `AppDelegate.application(_:didFinishLaunchingWithOptions:)`:

```swift
import Replay

class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: …) -> Bool {
        Replay.start(with: ReplayConfig(
            apiKey: "rpl_pk_…",
            apiHost: "https://ingest.replayfy.io"
        ))
        return true
    }
}
```

For SwiftUI-only apps (no AppDelegate), the same call goes in your
`@main App`'s `init`:

```swift
@main
struct MyApp: App {
    init() {
        Replay.start(with: ReplayConfig(apiKey: "…", apiHost: "…"))
    }
    var body: some Scene { … }
}
```

## API surface

```swift
Replay.start(with: config)                       // initialize
Replay.identify("user-123", properties: ["plan": "pro"])
Replay.track("checkout_started", properties: ["amount": 99])
Replay.stop()                                     // manual session end
Replay.isRecording                                // status

Replay.tagScreenName("Login")                    // (stub)
Replay.addPrivacyView(myTextField)               // (stub) UIKit
Replay.pauseRecording()                          // (stub)
Replay.resumeRecording()                         // (stub)
Replay.cancelSession()                           // (stub)
```

## Building locally

Requires Xcode 15+ or the Swift toolchain that ships with macOS
Command Line Tools.

```bash
# Run unit tests
swift test

# Build for iOS Simulator (requires xcodebuild + Xcode)
xcodebuild -scheme Replay -destination 'generic/platform=iOS Simulator'
```

## Architecture

Same shape as the Android SDK so cross-platform debugging stays
symmetric:

| Layer | iOS | Android equivalent |
|---|---|---|
| Public API | `Replay.swift` (`enum`) | `Replay.kt` (`object`) |
| Config | `ReplayConfig.swift` (`struct`) | `ReplayConfig.kt` (data class) |
| Orchestrator | `Internal/ReplayCore.swift` | `internal/ReplayCore.kt` |
| Session state | `Internal/SessionRuntime.swift` | `internal/SessionRuntime.kt` |
| Lifecycle | `Internal/LifecycleObserver.swift` (UIApplication notifications) | `internal/SessionLifecycleObserver.kt` (ProcessLifecycleOwner) |
| Transport | `Internal/BatchSender.swift` (URLSession) | `internal/BatchSender.kt` (OkHttp) |
| Schema | `Internal/EventSchema.swift` (Codable) | `internal/EventSchema.kt` |

iOS has **no zero-config bootstrap** like Android's ContentProvider
— the customer's one-line `start(with:)` call is what brings the
SDK to life. Matches the UXCam pattern.

## License

Commercial. Contact help@replayfy.io for terms.
