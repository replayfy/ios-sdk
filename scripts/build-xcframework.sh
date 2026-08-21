#!/usr/bin/env bash
# Build a distributable Replay.xcframework (iOS device + simulator) for binary
# SPM / CocoaPods distribution. Run on macOS with Xcode.
#
# STARTING POINT — validate on a Mac before the first release. See DISTRIBUTION.md:
#   • a pure SwiftPM package may need a wrapper .xcodeproj or `swift-create-xcframework`
#     to emit a .framework (xcodebuild archive on a raw SPM package won't);
#   • PLCrashReporter must be bundled in (option A) for a self-contained binary.
set -euo pipefail

SCHEME="${1:-Replay}"
BUILD="$(pwd)/.xcframework-build"
OUT="$(pwd)/build"
rm -rf "$BUILD" "$OUT/${SCHEME}.xcframework" "$OUT/${SCHEME}.xcframework.zip"
mkdir -p "$OUT"

archive() { # archive <destination> <archivePath> <sdk>
  xcodebuild archive \
    -scheme "$SCHEME" \
    -destination "$1" \
    -archivePath "$2" \
    -sdk "$3" \
    SKIP_INSTALL=NO \
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES
}

archive "generic/platform=iOS"           "$BUILD/ios.xcarchive" iphoneos
archive "generic/platform=iOS Simulator" "$BUILD/sim.xcarchive" iphonesimulator

FW="Products/Library/Frameworks/${SCHEME}.framework"
xcodebuild -create-xcframework \
  -framework "$BUILD/ios.xcarchive/$FW" \
  -framework "$BUILD/sim.xcarchive/$FW" \
  -output "$OUT/${SCHEME}.xcframework"

( cd "$OUT" && zip -qr "${SCHEME}.xcframework.zip" "${SCHEME}.xcframework" )

echo "built: $OUT/${SCHEME}.xcframework.zip"
echo "checksum (paste into Package.swift .binaryTarget): $(swift package compute-checksum "$OUT/${SCHEME}.xcframework.zip")"
