#
# CocoaPods spec for the Replay iOS SDK.
#
# Customers using CocoaPods add to their Podfile:
#   pod 'Replay', '~> 0.0.1'
#
# Customers using SwiftPM should use Package.swift directly — see README.
#
# To publish a new version:
#   1. Bump `spec.version` here AND the Package.swift `// version:`
#      comment (informational).
#   2. Tag the commit:  git tag 0.0.2 && git push origin 0.0.2
#   3. Validate:        pod spec lint Replay.podspec
#   4. Push to trunk:   pod trunk push Replay.podspec
#      (requires `pod trunk register` session — done once per
#      maintainer machine.)
#
Pod::Spec.new do |spec|
  spec.name         = "Replay"
  spec.version      = "0.0.1"
  spec.summary      = "Replayfy session replay + analytics for iOS."
  spec.description  = <<-DESC
    iOS SDK for Replayfy — captures session replays (view-tree snapshots
    + bitmap pixels via UIView.drawHierarchy + hardware-layer composite),
    taps, network requests, crashes, performance metrics (cold start,
    frame drops, ANR/hang, memory, thermal), and console output. Mirrors
    the wire format of the Android + web SDKs so a single dashboard
    timeline covers cross-platform sessions.

    Zero external runtime dependencies — Foundation + UIKit + URLSession
    + CryptoKit cover everything. Optional ReplaySwiftUI subspec adds
    Modifier wrappers (.replayOcclude, .replayTagScreenName).
  DESC

  spec.homepage     = "https://replayfy.io"
  spec.license      = { :type => "MIT", :file => "LICENSE" }
  spec.author       = { "Nasirudeen Olohundare" => "iamnasirudeen@gmail.com" }
  spec.source       = {
    :git => "https://github.com/replayfy/ios-sdk.git",
    :tag => spec.version.to_s
  }

  # iOS 15.0 floor matches Package.swift — covers ~95% of active devices
  # in 2026 and lets us use async/await throughout. Pre-15 customers can
  # pin the last 0.0.x or wait for the 0.1.x line if we decide to back-port.
  spec.ios.deployment_target = "15.0"
  spec.swift_versions = ["5.9"]

  # Core target: Foundation + UIKit + URLSession + CryptoKit. No vendor
  # frameworks. Mirrors what Package.swift declares as `.target(name: "Replay")`.
  spec.default_subspec = "Core"

  spec.subspec "Core" do |core|
    core.source_files = "Sources/Replay/**/*.swift"
    core.frameworks   = ["UIKit", "Foundation"]
    # CryptoKit is system on iOS 13+ — no explicit framework entry needed
    # for the SHA-256 helper.
  end

  # Opt-in SwiftUI integration — .replayOcclude / .replayTagScreenName
  # modifiers. Customers building UIKit-only apps don't need to add
  # this subspec; pulling it costs nothing at runtime when unused but
  # keeps the binary slightly smaller when omitted.
  spec.subspec "SwiftUI" do |swiftui|
    swiftui.source_files = "Sources/ReplaySwiftUI/**/*.swift"
    swiftui.dependency "Replay/Core"
    swiftui.frameworks = ["SwiftUI"]
  end
end
