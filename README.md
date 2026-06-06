# Replay iOS SDK

Session replay + analytics for iOS. Captures screen recordings, taps &
gestures, screen navigation, network, console logs, crashes, and
performance vitals, and streams them to your Replayfy dashboard.

- **Platforms:** iOS 15+
- **Distribution:** Swift Package Manager · CocoaPods (`pod 'Replay'`)

## Install

Swift Package Manager — Xcode → File → Add Package Dependencies:

```
https://github.com/replayfy/ios-sdk.git
```

## Quick start

Call `start(with:)` as early as possible. From an `AppDelegate`:

```swift
import Replay

func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: …) -> Bool {
    Replay.start(with: ReplayConfig(
        apiKey: "rpl_pk_xxxxxxxx",
        apiHost: "https://ingest.replayfy.io"
    ))
    return true
}
```

SwiftUI-only apps (no `AppDelegate`) call it from `@main App.init`:

```swift
@main
struct MyApp: App {
    init() {
        Replay.start(with: ReplayConfig(
            apiKey: "rpl_pk_xxxxxxxx",
            apiHost: "https://ingest.replayfy.io"
        ))
    }
    var body: some Scene { … }
}
```

Attach a known user and fire custom events:

```swift
Replay.identify("user_123", properties: ["email": "a@b.com", "plan": "pro"])
Replay.track("purchase", properties: ["amount": 4200, "currency": "USD"])
```

## Configuration — `ReplayConfig`

Only `apiKey` and `apiHost` are required; everything else has a sensible
default. With `useRemoteConfig = true` (default), your values act as
cold-start fallbacks — after the first fetch, dashboard settings win
(15-minute refresh), so flags can change without an app update.

| Property | Type | Default | Description |
|---|---|---|---|
| `apiKey` | `String` | **required** | Project API key from the dashboard |
| `apiHost` | `String` | **required** | Ingest base URL, e.g. `https://ingest.replayfy.io` |
| `projectId` | `String?` | `nil` | Only when one key spans multiple projects |
| `distinctId` | `String?` | `nil` | Known user id at start; else an install-stable anonymous id |
| `flushInterval` | `TimeInterval` | `5` | Auto-flush cadence (seconds) for the in-memory batch |
| `maxBufferSize` | `Int` | `500` | Events buffered before a flush is forced |
| `liveMode` | `Bool` | `true` | Live-presence socket (shows the session "online" on the dashboard) |
| `captureConsole` | `Bool` | `true` | Capture `print` / `NSLog` / `os_log` |
| `captureNetwork` | `Bool` | `false` | Capture HTTP requests (off by default — PII risk) |
| `captureErrors` | `Bool` | `true` | Capture uncaught exceptions / crashes |
| `captureHeaders` | `Bool` | `false` | Include request/response headers in network capture (PII risk) |
| `maxBodyBytes` | `Int` | `4096` | Max captured body bytes per network event (truncated above) |
| `captureSnapshotPixels` | `Bool` | `true` | Pixel-accurate playback vs tree-only "wireframe" |
| `snapshotInterval` | `TimeInterval` | `0.5` | Snapshot cadence (~2 FPS); floored at 0.2 s |
| `autoScreenName` | `Bool` | `true` | Auto-detect screen from the foremost `UIViewController` class name |
| `useRemoteConfig` | `Bool` | `true` | Let dashboard config override these at runtime |

## Privacy & masking

UIKit:

```swift
Replay.addPrivacyView(cardNumberField)        // mask one view
Replay.removePrivacyView(cardNumberField)

Replay.occludeAllTextFields(true)             // mask every UITextField/UITextView
Replay.occludeAllTextView(true)               // mask every UILabel
Replay.applyOcclusion(CreditCardView.self)    // mask a view class everywhere
Replay.occludeSensitiveScreen(true)           // mask the whole screen
Replay.occludeRectsOnNextFrame(rects)         // one-shot rect mask (RN/Flutter)
```

SwiftUI (via the `ReplaySwiftUI` module):

```swift
import ReplaySwiftUI

SecretView().replayOcclude()                  // mask this view (blockGestures: Bool = true)
ProfileScreen().replayTagScreenName("Profile")// tag the screen on first appear
```

Secure / password fields are masked automatically.

## Network capture

Set `captureNetwork: true`. A `URLProtocol` is auto-installed on
`URLSession.shared`. For custom `URLSessionConfiguration`s, register
before constructing the session:

```swift
let cfg = URLSessionConfiguration.default
Replay.captureURLSessionConfiguration(cfg)
let session = URLSession(configuration: cfg)
```

## API reference

### Active

| Method | Purpose |
|---|---|
| `start(with: config)` | Boot + start recording |
| `identify(_:properties:)` | Attach a known user (`email` / `name` / `plan` are promoted) |
| `track(_:properties:)` | Custom timeline / funnel event |
| `tagScreenName(_:)` | Manually set the current screen name |
| `log(level:message:stack:)` | Bridge a custom logger into the console tab |
| `addPrivacyView` / `removePrivacyView` | Per-view masking |
| `occludeAllTextFields` / `occludeAllTextView` | Bulk input / label masking |
| `applyOcclusion(_:)` / `removeOcclusion(_:)` | Mask all instances of a view class |
| `occludeSensitiveScreen(_:)` | Full-screen mask |
| `occludeRectsOnNextFrame(_:)` | One-shot rect masking |
| `captureURLSessionConfiguration(_:)` | Network capture for a custom session config |
| `.replayOcclude()` / `.replayTagScreenName(_:)` | SwiftUI view modifiers |

The engine additionally captures automatically: periodic screenshots,
taps & gestures, screen navigation, performance vitals (cold start,
frame drops, hangs, memory, thermal, battery), and crashes.

### Coming soon — currently no-ops

These methods exist on the public surface but are **not yet active** —
they are pending the engine consolidation (see `TODO.md`). Calling them
today is safe but has no effect:

`stop()` · `isRecording` · `pauseRecording()` / `resumeRecording()` ·
`cancelSession()` · `optOutOverall(_:)` / `isOptedOutOverall` ·
`optOutOfSchematicRecordings(_:)` / `isOptedOutOfSchematicRecordings` ·
`setUserProperty` · `setSessionProperty` · `markSessionAsFavorite()` ·
`addTagWithProperties` · `reportBugEvent` · `urlForCurrentSession()` /
`urlForCurrentUser()` · `setAutomaticScreenNameTagging` ·
`setPushNotificationToken` · `startNewSession()` · `setAppVersion` ·
`allowShortBreakForAnotherApp` · `setMultiSessionRecord` ·
`enableAdvancedGestureRecognizer` · `addVerificationListener` /
`removeVerificationListener` · `stopApplicationAndUploadData`.

> Until these land, do not rely on `optOutOverall` for GDPR compliance.

## Building locally

```bash
xcodebuild -scheme Replay -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' build
xcodebuild -scheme Replay-Package -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 15' test
```

## License

Commercial. Contact help@replayfy.io for terms.
