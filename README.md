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
- **Privacy first** — mask any view, field, label, or region; secure,
  password, one-time-code and card-number fields, and password inputs in
  web views, are masked automatically.
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
    .package(url: "https://github.com/replayfy/ios-sdk.git", from: "0.0.7")
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
pod 'Replayfy', '~> 0.0.7'
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
| `disableWebViewMasking` | `Bool` | `false` | Stop masking password inputs inside `WKWebView`s (see [Web views](#web-views)). |

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

// Pause / resume screen capture (other events keep flowing). The pause
// holds across background/foreground until resumed.
Replay.pauseRecording()
Replay.resumeRecording()

// Durable opt-out of screen capture, persisted across launches (other
// events keep flowing). A separate hold: opting back in doesn't undo a
// pauseRecording() still in effect.
Replay.optOutOfSchematicRecordings(true)

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

// A `picture` (or `avatar`) trait set to a public https image URL — top-level
// or nested in customProps — becomes the user's avatar in the dashboard.
Replay.identify("user_123", properties: ["picture": "https://cdn.example.com/u/123.png"])

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
// A field the frames mask (secure entry, a password / one-time-code /
// card-number content type, every field while all text fields are masked,
// a registered field) is always recorded as "***".
Replay.addObservedInput(emailField)

// Report a value that isn't backed by a UITextField. masked → "***".
// Also "***" while all text fields are masked or the screen is occluded.
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

Frames reported while the app is in the background, or while capture is
paused, opted out or on an excluded screen, are dropped.

## Privacy & masking

Sensitive content never has to leave the device. Masked automatically, with
no setup:

- text fields and text views with secure entry, or with the content type
  `.password`, `.newPassword`, `.oneTimeCode` or `.creditCardNumber`
  (React Native text inputs included);
- password inputs inside `WKWebView`s (see [Web views](#web-views)).

Everything else is opt-in. Only views drawn on screen are masked: a hidden
or fully transparent view (or one under a hidden or transparent ancestor) is
skipped, and a view still fading out stays masked. Masks follow views while
they animate. Taps on masked views are recorded with the label `"***"`.

The dashboard's "always mask input values" setting masks every text field
and text view from the next session start, on top of the app's own
settings; `occludeAllTextFields(false)` does not lift it. Flutter draws its
own text fields instead of using native ones, so neither this setting nor
`occludeAllTextFields` covers them: wrap them in the Flutter SDK's
`ReplayMask`. React Native text inputs are native fields and are covered.

### Choose a mask style

```swift
Replay.setMaskStyle(.overlay)   // solid box — nothing survives (default)
Replay.setMaskStyle(.blur)      // Gaussian blur
Replay.setMaskStyle(.pixelate)  // coarse mosaic
Replay.setBlurRadius(8)         // blur strength for .blur regions
```

`ReplayMaskStyle` values: `.blur`, `.overlay`, `.pixelate`. The style applies
to the regions the app masks itself. What the SDK masks on its own (secure
and password-type fields, web view password inputs) and the whole-screen
cover are always solid.

### UIKit masking

```swift
// Mask a single view (marks propagate to subviews). Taps on it are kept
// with a blanked label; blockGestures: true leaves gestures that start in
// it out of the recording (the app still receives them).
Replay.addPrivacyView(cardNumberField)
Replay.addPrivacyView(cvcRow, blockGestures: true)
Replay.removePrivacyView(cardNumberField)

// Mask every text field / text view, or every label (button titles and
// other text drawn in a label included; taps then carry no text either).
Replay.occludeAllTextFields(true)
Replay.occludeAllTextView(true)

// Mask every instance of a view class, everywhere it appears, with
// everything inside it.
Replay.applyOcclusion(CreditCardView.self)
Replay.removeOcclusion(CreditCardView.self)

// Mask the entire screen with one solid box (banking PIN pad, health
// records, …). Gestures are not recorded meanwhile; pass
// hideGestures: false to keep them (with blanked labels).
Replay.occludeSensitiveScreen(true)
Replay.occludeSensitiveScreen(true, hideGestures: false)

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

The content under `.replayOcclude()` keeps receiving every touch.
`replayOcclude(blockGestures:)` leaves gestures that start in the masked
region out of the recording when `blockGestures` is `true` (the default).

### Web views

Password inputs inside `WKWebView`s are masked solid: inputs of type
`password`, inputs whose `autocomplete` names a password, one-time code or
card number, and elements with the web SDK's `rr-block` / `rr-mask` classes,
in the page, in its same-origin frames and in open shadow roots (web
components). While every text field is masked, text-like inputs and
textareas are masked too. Before each frame the SDK asks the web views on
screen where these are, with a short read-only script run in an isolated
world (nothing is installed in your pages), and places each mask where the
page is scrolled and zoomed to when the frame is taken.

A web view is masked whole for a frame when it has not answered in time (its
first frame on screen, a slow page, a script error), while it is being
zoomed, when it answered before catching up with a zoom, page zoom or
resize, when one of the page's own scroll areas moved after it answered, or
while a masked input is being moved by an animation (a sliding login
sheet). A frame of another origin can't be looked into: it is masked whole
when its attributes mark it as a payment or sign-in frame (`allow="payment"`,
or a title, name or address naming a card, checkout, login and the like);
other embeds such as videos and maps stay visible. Inputs inside closed
shadow roots can't be found either: put the `rr-mask` class on the
component. Turn this off with `ReplayConfig(..., disableWebViewMasking: true)`.

## Links

- Docs: https://docs.replayfy.app/platforms/ios
- Dashboard: https://app.replayfy.app
