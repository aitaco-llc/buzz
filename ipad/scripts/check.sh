#!/usr/bin/env bash
set -euo pipefail
IPAD_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$IPAD_ROOT"

swift test --package-path BuzzCore
swift test --package-path ../mobile/ios/BuzzPushKit
xcrun swift-format lint --strict Buzz/*.swift BuzzUITests/*.swift BuzzAppTests/*.swift \
  BuzzCore/Sources/BuzzCore/*.swift BuzzCore/Tests/BuzzCoreTests/*.swift BuzzCore/Package.swift
xcodegen generate

if [[ -z "${BUZZ_IPAD_SIMULATOR_ID:-}" ]]; then
  BUZZ_IPAD_SIMULATOR_ID="$(xcrun simctl list devices available --json | python3 -c '
import json, sys
for devices in json.load(sys.stdin)["devices"].values():
    for device in devices:
        if "iPad" in device["name"]:
            print(device["udid"])
            sys.exit(0)
raise SystemExit("No available iPad simulator; install an iOS runtime in Xcode.")
')"
fi

xcodebuild -project BuzzNative.xcodeproj -scheme Buzz \
  -destination "platform=iOS Simulator,id=$BUZZ_IPAD_SIMULATOR_ID" \
  -derivedDataPath DerivedData -skipPackagePluginValidation \
  -parallel-testing-enabled NO test
xcodebuild -project BuzzNative.xcodeproj -scheme Buzz -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath DerivedData \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build
