# Changelog

All notable changes to the Replayfy iOS SDK are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.0.6] - 2026-10-14

### Fixed
- Frames a hybrid host captures itself (Flutter) are no longer taken while
  the app is in the background. The host's capture timer keeps firing while
  the background task keeps the app running, so those frames recorded a
  screen nobody could see and pushed the session's last upload, and its end,
  later. They are accepted again when the app returns to the foreground.
- `resumeRecording`, opting back into schematic recordings or leaving an
  excluded screen while the app is in the background no longer restarts
  native capture there; it restarts when the app returns. This also holds
  for a call from another thread (the React Native bridge) made as the app
  leaves: these changes now take effect on the main thread.
- A session that goes live while the app is in the background (restarted
  there, or opened by a background launch such as a silent push or
  background fetch) no longer takes frames or runs native capture until the
  app is opened.
- Opting back into schematic recordings
  (`optOutOfSchematicRecordings(false)`) no longer lifts a `pauseRecording`
  still in effect. The opt-out is now a hold of its own, and a call that
  changes nothing (a consent sync on every launch) no longer sends a partial
  frames archive.
- The podspec declares MIT, matching LICENSE (it declared BSD-3-Clause).

## [0.0.5] - 2026-10-13

### Fixed
- Frames and messages are no longer lost when the app goes to the
  background. The engine flushed once with no background task, so iOS could
  suspend or kill the app before the upload finished; everything captured
  since the last full batch was lost, and frames captured after a return to
  the app were often lost the same way. A background task is now held for
  each background cycle until its frame and message uploads settle.
- Frames upload one archive (at most 20) at a time, oldest first. A failed
  upload goes back to the front of the buffer instead of being discarded,
  and leftovers are sent as soon as the app returns to the foreground.
- The message collector sends one batch at a time, drains its whole queue on
  backgrounding, and on session end drains it and finishes with the late
  upload.
- Hybrid hosts that capture frames themselves (Flutter) no longer get native,
  unmasked screenshots after their first background: the native capture
  timer is only restarted on foreground when native capture is on.
- `pauseRecording`, the opt-out and excluded screens now hold across
  foregrounding and also stop host-fed (Flutter) frames.
- An excluded screen stays unrecorded when the session rotates while it is
  in front (a return after the short-break window, `startNewSession`), and
  exclusions set at runtime (`excludeScreen`, `setExcludedScreens`) survive
  the rotation; both used to be reset.
- A message larger than the batch cap is sent alone instead of blocking the
  queue.
- The SDK reports its real version (it reported 0.0.1 since the first
  release).

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

[0.0.6]: https://github.com/replayfy/ios-sdk/releases/tag/0.0.6
[0.0.5]: https://github.com/replayfy/ios-sdk/releases/tag/0.0.5
[0.0.1]: https://github.com/replayfy/ios-sdk/releases/tag/0.0.1
