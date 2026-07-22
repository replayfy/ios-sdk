// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Replay",
    // iOS 15 min covers ~95% of in-use devices in 2026 and lets us
    // use async/await throughout. Customers still on iOS 13/14 can
    // pin an older SDK version.
    platforms: [
        .iOS(.v15),
        // macOS target only exists so `swift build` can validate
        // (Apple's CLI defaults to macOS). The SDK isn't intended
        // for shipping macOS apps; UIKit-dependent code is wrapped
        // in `#if canImport(UIKit)` guards.
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "Replay",
            targets: ["Replay"]
        ),
        // Optional SwiftUI integration — gives customers
        // `.replayOcclude()` and `.replayTagScreenName(_:)` view
        // modifiers. Customers building UIKit-only apps don't need
        // to import this; it adds nothing at runtime when unused.
        .library(
            name: "ReplaySwiftUI",
            targets: ["ReplaySwiftUI"]
        ),
    ],
    dependencies: [
        // PLCrashReporter — the canonical iOS crash-capture library
        // (originally Plausible Labs, now maintained by Microsoft).
        // Catches Mach exceptions (EXC_BAD_ACCESS, EXC_BAD_INSTRUCTION,
        // EXC_CRASH) on top of POSIX signals (SIGSEGV/SIGBUS/SIGABRT/
        // SIGFPE), writes async-signal-safe crash dumps, and
        // symbolicates frames. Our previous hand-rolled NSException +
        // sigaction handler covered ~70% of crash modes; PLCrashReporter
        // covers ~99%. Brought in as SwiftPM transitive dep — adds
        // ~150 KB to the binary, no other runtime deps.
        //
        // the reference mobile SDK ships PLCrashReporter symbols inside their iOS binary
        // (verified via `nm`), so this puts us at parity on iOS
        // crash reliability.
        .package(
            url: "https://github.com/microsoft/plcrashreporter.git",
            from: "1.12.0"
        ),
    ],
    targets: [
        .target(
            name: "Replay",
            dependencies: [
                .product(name: "CrashReporter", package: "plcrashreporter"),
            ],
            path: "Sources/Replay"
        ),
        .target(
            // SwiftUI integration. Depends on the core Replay target
            // so the modifiers can call into PrivacyRegistry +
            // Replay.tagScreenName directly. Single-file target —
            // ~80% View modifiers + ~20% UIViewRepresentable plumbing.
            name: "ReplaySwiftUI",
            dependencies: ["Replay"],
            path: "Sources/ReplaySwiftUI"
        ),
        // XCTest target. `swift test` still fails under the CLT-only
        // toolchain (no XCTest), so these run via
        // `xcodebuild test -scheme Replay -destination 'platform=iOS Simulator,…'`
        // where the full Xcode toolchain provides XCTest + a UIKit
        // simulator host.
        .testTarget(
            name: "ReplayTests",
            dependencies: ["Replay"],
            path: "Tests/ReplayTests"
        ),
    ]
)
