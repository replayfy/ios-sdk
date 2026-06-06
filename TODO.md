# TODO

## #119 — Consolidate `LegacyCore` into `ReplayCore` (remove the duplicate engine)

**Status:** pending · **Priority:** high (includes a correctness gap)

### Problem
The SDK currently has two engines:

- **`Internal/Mobile/ReplayCore.swift`** — the LIVE engine (periodic frames +
  binary `/v1/mobile` protocol). Started by `Replay.start` →
  `ReplayCore.shared.start(...)`. Owns its own touch / screenshot / perf /
  crash capture.
- **`Internal/LegacyCore.swift`** — the legacy engine. `LegacyCore.shared`
  is only ever touched lazily by facade methods; `LegacyCore.shared.start(config:)`
  is never called, so it never starts a session and records nothing.

Unlike Android there is no `ContentProvider`, so `LegacyCore` does not
auto-bootstrap a duplicate collector stack — the main issue here is:

- **No-op public API.** ~25 public `Replay.*` methods still delegate to
  `LegacyCore` and are therefore inert today (see README "Coming soon").
  Notably **`optOutOverall` / opt-out is not enforced** on the live engine
  — a GDPR-compliance gap.

(Keep this in lock-step with the Android `#119` so the two SDKs stay
symmetric — Android additionally has the duplicate-handler problem from its
ContentProvider auto-bootstrap.)

### Fix
- Re-home the ~25 facade methods onto `ReplayCore` (or drop / keep a thin
  `LegacyCore` piece per method — e.g. opt-out `UserDefaults` persistence).
  Then delete the dead recording machinery in `LegacyCore`.

### Constraint (project standing rule #3)
Follow the reference open-source mobile SDK approach EXACTLY — do **not**
invent the re-homing. Ask the owner for the reference iOS SDK source before
implementing.

### Verify
```bash
xcodebuild -scheme Replay -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' build
xcodebuild -scheme Replay-Package -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 15' build-for-testing
```
