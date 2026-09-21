// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "BuzzCore",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [.library(name: "BuzzCore", targets: ["BuzzCore"])],
  dependencies: [
    .package(path: "../../mobile/ios/BuzzPushKit"),
    .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1.git", exact: "0.23.2"),
    .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", exact: "1.10.0"),
  ],
  targets: [
    .target(
      name: "BuzzCore",
      dependencies: [
        "BuzzPushKit", .product(name: "P256K", package: "swift-secp256k1"),
        .product(name: "CryptoSwift", package: "CryptoSwift"),
      ]),
    .testTarget(name: "BuzzCoreTests", dependencies: ["BuzzCore"]),
  ]
)
