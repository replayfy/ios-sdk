# Replayfy for iOS

> Session replay, product analytics & error monitoring for your iOS app.

Replayfy records what really happens in your app — pixel-accurate screen
replays, every tap and gesture, screen navigation, custom events, crashes,
and performance vitals — and streams it to your Replayfy dashboard so you
can see, measure, and debug real user sessions.

## Features

- **Session replay** — pixel-accurate screen recordings of real sessions.
- **Auto-captured interactions** — taps, gestures, and screen navigation
  with no extra code.
- **Product analytics** — identify users and track custom events, funnels,
  and session/user properties.
- **Error monitoring** — automatic crash capture plus reporting for handled
  exceptions.
- **Performance vitals** — cold start, frame drops, hangs, memory, thermal,
  and battery.
- **Network & console capture** — inspect requests and logs alongside the
  replay (network is opt-in).
- **Privacy first** — mask or blur any view, field, label, or region;
  secure text fields are masked automatically.
- **SwiftUI & UIKit** — works with both, with dedicated SwiftUI view
  modifiers.
- **Lightweight** — one call to start; sensible defaults; iOS 15+.

## Install

The module you import is `Replay` regardless of which installer you use:

```swift
import Replay
```

### Swift Package Manager

In Xcode: **File → Add Package Dependencies…** and enter:

```
https://github.com/replayfy/ios-sdk.git
```

Add the **Replayfy** library product to your app target. (Add the optional
**ReplaySwiftUI** product too if you use SwiftUI.)

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/replayfy/ios-sdk.git", from: "0.0.5")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "Replayfy", package: "replay-ios-sdk"),
            // optional SwiftUI modifiers:
            .product(name: "ReplaySwiftUI", package: "replay-ios-sdk"),
        ]
    )
]
```

### CocoaPods

```ruby
pod 'Replayfy', '~> 0.0.5'
```

## Quick start

Start Replayfy as early as possible. From an `AppDelegate`:

```swift
import Replay

func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions:
                 [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    Replay.start(with: ReplayConfig(
        apiKey: "YOUR_API_KEY",
        apiHost: "https://us.replayfy.app"  // or your self-hosted API URL
    ))
    return true
}
```

SwiftUI-only apps (no `AppDelegate`) start it from `App.init`:

```swift
@main
struct MyApp: App {
    init() {
        Replay.start(with: ReplayConfig(
            apiKey: "YOUR_API_KEY",
            apiHost: "https://us.replayfy.app"  // or your self-hosted API URL
        ))
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

Attach a known user and record custom events:

```swift
Replay.identify("user_123", properties: ["email": "a@b.com", "plan": "pro"])
Replay.track("purchase", properties: ["amount": 4200, "currency": "USD"])
```

## Configuration

Only `apiKey` and `apiHost` are required — everything else has a sensible
default. Pass any subset to `ReplayConfig(...)`.

| Option | Type | Default | Description |
|---|---|---|---|
| `apiKey` | `String` | **required** | Your project API key from the dashboard. |
| `apiHost` | `String` | **required** | Ingest base URL, e.g. `https://us.replayfy.app` (or your self-hosted API URL). |
| `projectId` | `String?` | `nil` | Only when one key covers multiple projects. |
| `distinctId` | `String?` | `nil` | Known user id at start; otherwise an install-stable anonymous id is used. |
| `flushInterval` | `TimeInterval` | `5` | Seconds between automatic uploads of the in-memory batch. |
| `maxBufferSize` | `Int` | `500` | Events buffered before an upload is forced. |
| `captureConsole` | `Bool` | `true` | Capture `print` / `NSLog` / `os_log` output. |
| `captureNetwork` | `Bool` | `false` | Capture HTTP requests (off by default to avoid PII). |
| `captureErrors` | `Bool` | `true` | Capture uncaught exceptions and crashes. |
| `captureHeaders` | `Bool` | `false` | Include request/response headers in network capture. |
| `captureBodies` | `Bool` | `true` | Include request/response bodies (capped by `maxBodyBytes`). |
| `maxBodyBytes` | `Int` | `4096` | Max captured body bytes per network event; larger bodies are truncated. |
| `captureSnapshotPixels` | `Bool` | `true` | Pixel-accurate replay when `true`; lighter wireframe replay when `false`. |
| `snapshotInterval` | `TimeInterval` | `0.5` | Screen-capture cadence in seconds (floored at 0.2s). |
| `autoScreenName` | `Bool` | `true` | Auto-detect the current screen from the foreground view controller. |
| `useRemoteConfig` | `Bool` | `true` | Let dashboard settings override these values at runtime. |
| `captureTouch` | `Bool` | `true` | Capture taps natively (disable only for host-driven capture such as Flutter). |
| `excludedScreens` | `[String]` | `[]` | Screen names whose frame capture pauses while they're foreground (case-insensitive); mutable at runtime via `Replay.excludeScreen`. |

## API

All methods are static on the `Replay` type.

### Lifecycle

```swift
// Boot the SDK and start recording. Call once at launch.
Replay.start(with: ReplayConfig(apiKey: "YOUR_API_KEY",
                                apiHost: "https://us.replayfy.app"))  // or your self-hosted API URL

// End the current session and upload immediately. A new session starts
// on the next foreground.
Replay.stop()

// Discard the current session WITHOUT uploading — the buffered events
// are dropped and the server drops whatever already streamed. A fresh
// session can start afterward. Unlike stop() (graceful end + upload).
Replay.cancelSession()

// Whether a session is currently recording.
if Replay.isRecording { /* … */ }

// Pause / resume screen capture (other events keep flowing).
Replay.pauseRecording()
Replay.resumeRecording()

// Force a new logical session (e.g. after logout → login).
Replay.startNewSession()

// Keep the SAME session across a brief switch to another app (a gap up
// to windowSeconds); a longer gap starts a fresh session on return.
Replay.allowShortBreakForAnotherApp(true, windowSeconds: 30)

// Record only one session per app launch instead of the default many.
// The current/next session records, then no further sessions open in
// this process.
Replay.setMultiSessionRecord(false)

// Stop recording and block up to `timeoutSeconds` until the buffer is
// flushed — use from applicationWillTerminate or a sign-out flow.
Replay.stopApplicationAndUploadData(timeoutSeconds: 5)
```

### Identify & analytics

```swift
// Attach a known user to the session; anonymous history links back to them.
Replay.identify("user_123", properties: ["email": "a@b.com", "plan": "pro"])

// Fire a custom event onto the timeline (drives funnels and filters).
Replay.track("checkout_started", properties: ["cart_value": 4200])

// Sticky property on the end user (persists across sessions).
Replay.setUserProperty("plan", value: "pro")

// Sticky property on the current session only.
Replay.setSessionProperty("ab_variant", value: "B")

// Session-level tag (with optional properties) for filtering sessions.
Replay.addTagWithProperties("holiday_flow", properties: ["campaign": "xmas"])

// Star the current session so it surfaces in the dashboard's saved filter.
Replay.markSessionAsFavorite()

// Send a manual bug report (wire to a "Report issue" button).
Replay.reportBugEvent("checkout_bug", description: "Pay button did nothing")
```

### Error monitoring

```swift
// Report a caught error onto the timeline (handled = true by default).
do {
    try riskyWork()
} catch {
    Replay.captureException(error, properties: ["where": "sync"])
}

// Mark a caught error as fatal:
Replay.captureException(error, handled: false)
```

Uncaught exceptions and crashes are captured automatically when
`captureErrors` is `true`.

### Screens

```swift
// Manually set the current screen name (overrides the auto-tagger).
Replay.tagScreenName("Checkout")

// Toggle the automatic screen-name tagger at runtime.
Replay.setAutomaticScreenNameTagging(false)

// Exclude a screen from replay by name (case-insensitive; matched
// against the auto-tagged / tagScreenName name). While it's foreground
// the frame capture pauses — taps, network, console, and performance
// events keep flowing — and resumes on the next non-excluded screen.
Replay.excludeScreen("PinPad")

// Stop excluding a screen — frame capture resumes next time it's shown.
Replay.unexcludeScreen("PinPad")

// Replace the entire excluded-screens list in one call.
Replay.setExcludedScreens(["PinPad", "AccountRecovery"])
```

Screen exclusion is distinct from `occludeSensitiveScreen(_:)`: occlusion
keeps recording but blanks the frame, whereas an excluded screen captures
no frames at all. Seed the initial list at start via
`ReplayConfig(excludedScreens:)`:

```swift
Replay.start(with: ReplayConfig(
    apiKey: "YOUR_API_KEY",
    apiHost: "https://us.replayfy.app",  // or your self-hosted API URL
    excludedScreens: ["PinPad", "AccountRecovery"]
))
```

### Gestures

```swift
// Additionally capture pinch and rotate gestures, on top of the
// always-on tap / swipe / long-press. Default off.
Replay.enableAdvancedGestureRecognizer(true)
```

### Logging

```swift
// Bridge a custom logger (os_log, Logger, CocoaLumberjack, …) into the
// console tab. level ∈ "log" | "info" | "warn" | "error" | "debug".
Replay.log(level: "error", message: "Payment failed", stack: nil)
```

### Metadata

```swift
// Override the auto-detected app version/build (useful for RN/Flutter shells).
Replay.setAppVersion("4.2.0", build: "1201")

// Attach the device push token to the session.
Replay.setPushNotificationToken(deviceToken, platform: "apns")
```

### Text input

```swift
// Record a text field's value when editing ends (opt-in per field).
// Secure fields (isSecureTextEntry) are always recorded as "***".
Replay.addObservedInput(emailField)

// Report a value that isn't backed by a UITextField. masked → "***".
Replay.trackInput(label: "Coupon", value: code, masked: false)
```

### Network capture

Set `captureNetwork: true`. `URLSession.shared` is captured automatically.
For a custom `URLSessionConfiguration`, register it before creating the
session:

```swift
let cfg = URLSessionConfiguration.default
Replay.captureURLSessionConfiguration(cfg)
let session = URLSession(configuration: cfg)
```

### Consent / opt-out

```swift
// Overall opt-out — drops all events and recording. Persists across launches.
Replay.optOutOverall(true)
if Replay.isOptedOutOverall { /* … */ }
```

### Integration verification

```swift
// Fires once after the first successful upload — light up your
// "Verify integration" onboarding UI. Returns a token to remove it later.
let token = Replay.addVerificationListener {
    print("Replayfy is connected 🎉")
}
Replay.removeVerificationListener(token)
```

### Cross-platform bridges

These entry points let host frameworks (React Native, Flutter) feed
interactions, inputs, and frames they capture themselves. Native iOS apps
don't need them:

```swift
Replay.reportInteraction(kind: "tap", label: "Buy", x: 120, y: 340)
Replay.trackInput(label: "Email", value: text, masked: false)
Replay.reportFrame(pngData, rects: rects, styles: styles)
```

> **Not yet active.** A few methods are on the public surface but are
> no-ops in this release, pending an engine follow-up:
> `optOutOfSchematicRecordings(_:)` / `isOptedOutOfSchematicRecordings`
> and `urlForCurrentSession()` / `urlForCurrentUser()`. Calling them is
> safe but has no effect.

## Privacy & masking

Sensitive content never has to leave the device. Secure/password fields
are masked automatically; everything else is opt-in.

### Choose a mask style

```swift
Replay.setMaskStyle(.blur)      // Gaussian blur (default)
Replay.setMaskStyle(.overlay)   // solid box — nothing survives
Replay.setMaskStyle(.pixelate)  // coarse mosaic
Replay.setBlurRadius(8)         // blur strength for .blur regions
```

`ReplayMaskStyle` values: `.blur`, `.overlay`, `.pixelate`.

### UIKit masking

```swift
// Mask a single view (marks propagate to subviews).
Replay.addPrivacyView(cardNumberField)
Replay.removePrivacyView(cardNumberField)

// Mask every text field / text view, or every label.
Replay.occludeAllTextFields(true)
Replay.occludeAllTextView(true)

// Mask every instance of a view class, everywhere it appears.
Replay.applyOcclusion(CreditCardView.self)
Replay.removeOcclusion(CreditCardView.self)

// Mask the entire screen (banking PIN pad, health records, …).
Replay.occludeSensitiveScreen(true)

// Mask specific regions on the next frame only (root-relative points).
Replay.occludeRectsOnNextFrame(rects)
Replay.occludeRectsOnNextFrame(rects, style: .overlay)
```

### SwiftUI masking

Import the optional `ReplaySwiftUI` module:

```swift
import ReplaySwiftUI

var body: some View {
    VStack {
        CreditCardForm()
            .replayOcclude()                 // mask this view's region
    }
    .replayTagScreenName("Checkout")         // tag the screen on appear
}
```

`replayOcclude(blockGestures:)` also suppresses taps on the masked region
when `blockGestures` is `true` (the default).

## Links

- Docs: https://docs.replayfy.app/platforms/ios
- Dashboard: https://app.replayfy.app
