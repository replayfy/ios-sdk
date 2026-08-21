# iOS SDK distribution — moving to a binary xcframework

## Why

Today the SDK ships as **SwiftPM source** (`.target`s that clone the repo and
resolve from git tags) plus a **CocoaPods** podspec. The source-SPM path is the
one customers hit `Couldn't get the list of tags` on: Xcode's SwiftPM runs a
live `git ls-remote --tags` with its own git/cache/credentials, which fails
(rate limits, cache corruption, Xcode ≠ shell git) even when the repo is
reachable from a terminal.

A **binary `.xcframework` distributed via SPM `.binaryTarget(url:checksum:)`**
fixes this: SPM downloads a versioned zip attached to a GitHub Release instead
of cloning source and listing tags — faster, and immune to the tag-list failure.
This is how Sentry, Firebase, and Amplitude ship their iOS SDKs.

## The one real complication: PLCrashReporter

`Package.swift` depends on `plcrashreporter` (an SPM package). **A
`.binaryTarget` cannot declare package dependencies.** Two ways to resolve it:

- **(A) Self-contained xcframework (recommended).** Statically link
  PLCrashReporter *into* `Replay.xcframework` at build time, so the shipped
  binary has no external SPM dep and `Package.swift` becomes a single
  `.binaryTarget`. Matches how Sentry ships (their xcframework embeds its crash
  reporter). Requires merging the static archives during the build.
- **(B) Keep PLCrashReporter as a sibling dep.** Ship `Replay.xcframework`
  (built against, but not embedding, PLCrashReporter) and keep the
  `plcrashreporter` package dependency; a thin wrapper links them. Simpler build,
  but reintroduces a source/tag dependency (PLCrashReporter's) into resolution —
  it partially defeats the point. Prefer (A).

## Validated findings (Xcode 26.6 / Swift 6.3, 2026)

Tried on the Mac, so this is grounded, not guessed:

- ✅ `xcodebuild build -scheme Replayfy -destination 'generic/platform=iOS'` →
  **BUILD SUCCEEDED**, and with `BUILD_LIBRARY_FOR_DISTRIBUTION=YES` it emits a
  `Replay.swiftinterface` — the SDK is module-stable and *ready* to ship as a
  binary. The blocker below is purely packaging.
- ❌ **A pure SwiftPM package does not archive into a `.framework`.**
  `xcodebuild archive … SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES` on
  the `Replayfy` scheme produced **no `.framework`** (SPM builds static
  libraries/modules, not frameworks), so `-create-xcframework -framework …` has
  nothing to consume.
- ❌ **`swift-create-xcframework` won't build on Swift 6.3** (fails compiling for
  `arm64-apple-macosx26.5`) — the tool lags the toolchain.

## What a binary xcframework actually requires here

Not a script — a small **wrapper framework project**:

1. A `.xcodeproj` (hand-authored, or generated with **XcodeGen**) with dynamic
   **framework** targets `Replay` + `ReplaySwiftUI` that compile the same
   `Sources/…` and set `BUILD_LIBRARY_FOR_DISTRIBUTION=YES`.
2. **PLCrashReporter bundled in** (option A) — link its static lib into
   `Replay.framework` so the shipped binary has no external SPM dep.
3. `xcodebuild archive` for `iphoneos` + `iphonesimulator`, then
   `xcodebuild -create-xcframework` over the two `.framework`s.

`scripts/build-xcframework.sh` + `release-xcframework.yml` encode the archive →
zip → checksum → release steps and are correct **once a framework-producing
scheme exists** (step 1). They will NOT work against the raw SPM scheme.

## Recommendation

The customer's iOS failure (`Couldn't get the list of tags`) is **already fixed
by using CocoaPods** — Flutter's default, made explicit in `replayfy_flutter`'s
README. That needs no xcframework. Treat the binary xcframework as a **separate,
deliberate task** (the wrapper project above) when there's appetite for faster
SPM resolution — it's ready on the SDK side, just gated on packaging tooling.

## How to flip `Package.swift` once a binary release exists

Keep the current source manifest until the first `Replay.xcframework.zip` is
attached to a release. Then the products stay the same and the target becomes:

```swift
// products unchanged: .library(name: "Replayfy", targets: ["Replay"]) …
targets: [
    .binaryTarget(
        name: "Replay",
        url: "https://github.com/replayfy/ios-sdk/releases/download/0.1.0/Replay.xcframework.zip",
        checksum: "<swift package compute-checksum output>"
    ),
    // ReplaySwiftUI stays a source target that depends on the binary "Replay",
    // or ships as its own binaryTarget too.
]
```

The **CocoaPods** podspec can likewise switch to `vendored_frameworks` pointing
at the same `Replay.xcframework.zip`, so both channels serve one binary.

## Sequence

1. Decide (A) vs (B) — recommend (A).
2. Validate `scripts/build-xcframework.sh` on a Mac; wire the PLCrashReporter
   bundling for (A).
3. Tag a release → `release-xcframework.yml` builds, checksums, and attaches
   `Replay.xcframework.zip`.
4. Flip `Package.swift` to `.binaryTarget` (and the podspec to
   `vendored_frameworks`), tag the next version.

Until then, the **immediate customer fix is CocoaPods** (Flutter's default) —
see `replayfy_flutter`'s README; the source-SPM path should be avoided.
