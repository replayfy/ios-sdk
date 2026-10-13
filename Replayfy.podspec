#
# CocoaPods spec for the Replayfy iOS SDK.
#
# Customers using CocoaPods add to their Podfile:
#   pod 'Replayfy', '~> 0.0.1'
#
# Customers using SwiftPM add the package in Xcode — see README.
#
# In both cases the module customers import is `Replay`:
#   import Replay
#
# To publish a new version:
#   1. Bump `spec.version` here AND the Package.swift `// version:`
#      comment (informational).
#   2. Tag the commit:  git tag 0.0.2 && git push origin 0.0.2
#   3. Validate:        pod spec lint Replayfy.podspec
#   4. Push to trunk:   pod trunk push Replayfy.podspec
#      (requires `pod trunk register` session — done once per
#      maintainer machine.)
#
Pod::Spec.new do |spec|
  spec.name         = "Replayfy"
  spec.module_name  = "Replay"
  spec.version      = "0.0.5"
  spec.summary      = "Session replay, product analytics & error monitoring for iOS."
  spec.description  = <<-DESC
    Replayfy is the iOS SDK for session replay, product analytics, and
    error monitoring. Drop it in with one call and get pixel-accurate
    screen replays, tap & gesture tracking, screen navigation, custom
    events, network and console capture, crash & exception reporting,
    and performance vitals (cold start, frame drops, hangs, memory,
    thermal) — all streamed to your Replayfy dashboard.

    Built-in privacy controls let you mask or blur any view, text field,
    label, or region so sensitive data never leaves the device. An
    optional SwiftUI integration adds `.replayOcclude()` and
    `.replayTagScreenName(_:)` view modifiers.
  DESC

  spec.homepage     = "https://replayfy.app"
  spec.license      = { :type => "MIT", :file => "LICENSE" }
  spec.author       = { "Replayfy" => "hello@replayfy.app" }
  spec.source       = {
    :git => "https://github.com/replayfy/ios-sdk.git",
    :tag => spec.version.to_s
  }

  # iOS 15.0 floor matches Package.swift.
  spec.ios.deployment_target = "15.0"
  spec.swift_versions = ["5.9"]

  # The crash-capture dependency (PLCrashReporter, below) ships a static
  # .xcframework. A pod that transitively links a static binary must itself be
  # built as a static framework — otherwise `pod lib lint` / `pod trunk push`
  # fails with "transitive dependencies that include statically linked
  # binaries". This is the standard requirement for PLCrashReporter-based pods.
  spec.static_framework = true

  spec.default_subspec = "Core"

  spec.subspec "Core" do |core|
    core.source_files = "Sources/Replay/**/*.swift"
    core.frameworks   = ["UIKit", "Foundation"]
    # Crash capture is powered by PLCrashReporter (matches the SwiftPM
    # dependency declared in Package.swift).
    core.dependency "PLCrashReporter", "~> 1.12"
  end

  # Opt-in SwiftUI integration — .replayOcclude / .replayTagScreenName
  # view modifiers. UIKit-only apps don't need this subspec.
  spec.subspec "SwiftUI" do |swiftui|
    swiftui.source_files = "Sources/ReplaySwiftUI/**/*.swift"
    swiftui.dependency "Replayfy/Core"
    swiftui.frameworks = ["SwiftUI"]
  end
end
