# Changelog

All notable changes to the Replayfy iOS SDK are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.0.1] - 2026-08-03

Initial public release.

### Added
- Session replay with pixel-accurate screen capture and automatic tap,
  gesture, and screen-navigation tracking.
- Product analytics: `identify`, `track`, session/user properties, and
  custom event timelines.
- Error monitoring: automatic crash capture plus `captureException` for
  handled errors.
- Performance vitals: cold start, frame drops, hangs, memory, thermal,
  and battery.
- Network and console capture (opt-in for network).
- Privacy & masking: per-view, per-class, whole-screen, and region
  masking with blur / overlay / pixelate styles; automatic masking of
  secure text fields.
- Optional SwiftUI integration (`ReplaySwiftUI`) with `.replayOcclude()`
  and `.replayTagScreenName(_:)` view modifiers.
- Distribution via Swift Package Manager and CocoaPods.

[0.0.1]: https://github.com/replayfy/ios-sdk/releases/tag/0.0.1
