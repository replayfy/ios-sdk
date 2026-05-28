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
- ✅ Snapshot pipeline (tree + bitmap) — `ViewTreeSerializer` walks
  the UIView hierarchy and emits `native_snapshot` events on screen
  change + 500ms after each tap. Full-screen PNG captured via
  `UIView.drawHierarchy`, SHA-256 hashed, uploaded to
  `/v1/replay/assets/:hash`, embedded as `root.imageRef`. Player
  renders pixel-accurate playback.
- ✅ Persistent upload queue — failed live batches persist to
  `Application Support/replay-queue/`. Drains on every foreground
  via the lifecycle observer. Capped at 500 queued files / ~25 MB.
  iOS has no WorkManager equivalent so v1 is foreground-only;
  BGTaskScheduler integration is a follow-up.
- ✅ Network capture — `URLProtocol` subclass auto-installed on
  `URLSession.shared` + deprecated NSURLConnection traffic. Captures
  method, URL, status, timing; headers + bodies behind
  `captureHeaders` / `maxBodyBytes` config flags. Tag-recursion
  guard prevents the forwarded request from infinitely re-entering
  the interceptor. Off by default — set `ReplayConfig(captureNetwork:
  true)` to enable. Limitation: customer URLSessions with custom
  `protocolClasses` bypass us without an explicit install.
- ✅ Crash handler — `NSSetUncaughtExceptionHandler` catches Obj-C
  exceptions; `sigaction` handlers catch SIGSEGV/SIGABRT/SIGBUS/
  SIGFPE/SIGILL/SIGTRAP. Signal handler writes a tiny ASCII record
  via async-signal-safe `open()` + `write()` (no allocations, no
  Swift runtime). Next launch reads the record + emits as an
  `error` event with `kind:"crash"`. Previous handlers chained
  (Crashlytics/Sentry still fire); default re-raised so the OS
  still produces its normal crash report. No PLCrashReporter
  integration in v1 — symbolicated stack traces are a follow-up.
- ✅ Occlusion / privacy views — `Replay.addPrivacyView(_:)` marks a
  UIView (and all descendants) sensitive. Tap events get `isSensitive`
  with metadata blanked, view-tree nodes get `occluded`, BitmapCapture
  paints a diagonal-stripe overlay over the region inside the captured
  PNG. Triple-layer defense.
- ✅ Native performance metrics — `cold_start_ms` (one-shot first
  foreground), `frame_drop_pct` + `frozen_frame_count` (CADisplayLink
  10s rolling window), `memory_rss_mb` (mach_task_basic_info every
  30s), `thermal_state` (ProcessInfo notification on change). Ships
  as `performance` events with the same `kind:"perf"` shape the web
  SDK uses — backend's existing classifier handles them. Deferred:
  `tap_response_ms`, `first_network_ttfb_ms`, `battery_drain_pct_per_min`,
  `time_to_first_meaningful_render_ms` (need other hooks first).
- ✅ SwiftUI view modifiers (separate `ReplaySwiftUI` SPM target) —
  `.replayOcclude(blockGestures:)` overlays a transparent
  PrivacyMarker UIView and registers it via `Replay.addPrivacyView`;
  the SDK's PrivacyRegistry bounds-intersection check picks up
  SwiftUI content rendered at the same screen rect.
  `.replayTagScreenName("Login")` fires `Replay.tagScreenName` on
  first `.onAppear` — fixes the auto-tag gap for SwiftUI-first apps
  where every screen lives under one root UIViewController.

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
