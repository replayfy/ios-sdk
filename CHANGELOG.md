# Changelog

All notable changes to the Replayfy iOS SDK are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.0.7] - 2026-10-14

### Changed
- Masked regions are painted solid by default (`setMaskStyle` defaults to
  `.overlay`; it was `.blur`), as the reference tracker does. Blur and
  pixelate are still available for the regions the app masks itself. What
  the SDK masks on its own (secure and password-type fields, password
  inputs inside web views) and `occludeSensitiveScreen` are always solid,
  whatever the style.
- `occludeSensitiveScreen(true)` also stops recording gestures while it is
  on, as the reference tracker does. Use
  `occludeSensitiveScreen(true, hideGestures: false)` to keep them; their
  labels are then blanked (`"***"`).
- Taps on masked views are recorded with the label `"***"` instead of the
  view's text: secure and password-type fields, every text field while all
  text fields are masked, registered views and their content, views of an
  `applyOcclusion` class, views under a `.replayOcclude()` region, and
  anything while the whole screen is occluded. Taps on secure fields, which
  used to be dropped, are now kept with the blanked label.
- Observed inputs (`addObservedInput`) report `"***"` whenever the frames
  mask the field, not only for secure entry. Values a host reports with
  `trackInput` are blanked while every text field is masked or the screen
  is occluded.
- `.replayOcclude()` no longer takes the touches of the content it covers:
  buttons and fields under it work again. `blockGestures` now only keeps
  gestures that start in the region out of the recording.

### Added
- Text inputs whose content type is `.password`, `.newPassword`,
  `.oneTimeCode` or `.creditCardNumber` are masked automatically, like
  secure entry, on `UITextField` and `UITextView` (secure `UITextView`s
  included). React Native text inputs with these content types are covered
  too.
- Password inputs inside `WKWebView`s are masked automatically (inputs of
  type password, and inputs marked as a password, one-time code or card
  number). The SDK looks them up with a short read-only script before each
  frame; a web view that has not answered in time, or a frame of another
  origin inside it, is masked whole. Turn this off with
  `ReplayConfig(disableWebViewMasking: true)`.
- The dashboard's "always mask input values" setting masks every text field
  and text view from the next session start. It adds to the app's
  `occludeAllTextFields`; `occludeAllTextFields(false)` does not lift it.
- `addPrivacyView(_:blockGestures:)`, and
  `occludeSensitiveScreen(_:hideGestures:)`, also from Objective-C.

### Fixed
- A view that is hidden or fully transparent, or sits under such a view, is
  no longer masked over the content drawn in its place; a view still fading
  out stays masked until it is gone.
- Masks follow views while they animate (push, pop, sheets, slides): they
  cover both where a view is drawn and where it is going, instead of
  trailing the pixels.
- A zero-size container that does not clip its children no longer hides a
  secure field inside it from masking.
- A region that cannot be blurred or pixelated is painted solid instead of
  being left uncovered, and a frame whose masks cannot be applied is
  dropped.
- A blurred or pixelated region that runs off the edge of the frame is drawn
  back in place instead of being stretched over neighbouring pixels.
- The blur no longer lets the original pixels show at the edges of a
  region.
- `occludeSensitiveScreen` now covers frames a hybrid host captures itself
  (Flutter), which it did not mask at all.

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

[0.0.7]: https://github.com/replayfy/ios-sdk/releases/tag/0.0.7
[0.0.6]: https://github.com/replayfy/ios-sdk/releases/tag/0.0.6
[0.0.5]: https://github.com/replayfy/ios-sdk/releases/tag/0.0.5
[0.0.1]: https://github.com/replayfy/ios-sdk/releases/tag/0.0.1
