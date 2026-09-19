// swift-tools-version: 6.0
import PackageDescription

// The native iPad UI as a library, so the universal Runner app can run it on
// iPad (mobile/ios/Runner/main.swift). BuzzNative.xcodeproj still builds the
// same sources as a standalone app for development and tests.
let package = Package(
  name: "BuzzPad",
  platforms: [.iOS(.v17)],
  products: [.library(name: "BuzzPadApp", targets: ["BuzzPadApp"])],
  dependencies: [
    .package(path: "BuzzCore"),
    .package(path: "../mobile/ios/BuzzPushKit"),
  ],
  targets: [
    .target(
      name: "BuzzPadApp",
      dependencies: ["BuzzCore", "BuzzPushKit"],
      path: ".",
      exclude: ["Buzz/Assets.xcassets", "Buzz/Buzz.entitlements"],
      // Embedded/ links the files the standalone project takes from mobile/
      // directly: the shared huddle audio engine, emoji catalog and mark.
      sources: ["Buzz", "Embedded/HuddleAudioEngine.swift"],
      resources: [.copy("Embedded/emoji-data.json"), .copy("Embedded/aitaco-mark.png")],
      linkerSettings: [.linkedFramework("DeclaredAgeRange")]
    )
  ]
)
