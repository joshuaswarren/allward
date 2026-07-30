// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "Allward",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "AllwardCore", targets: ["AllwardCore"])
  ],
  targets: [
    .target(name: "AllwardCore"),
    .testTarget(
      name: "AllwardCoreTests",
      dependencies: ["AllwardCore"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
