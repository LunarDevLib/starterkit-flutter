// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "StarterkitPlatformPolicy",
  platforms: [.macOS(.v12)],
  products: [
    .library(name: "StarterkitPlatformPolicy", targets: ["StarterkitPlatformPolicy"])
  ],
  targets: [
    .target(
      name: "StarterkitPlatformPolicy",
      path: "Classes",
      exclude: ["StarterkitPlatformPlugin.swift", "IOSLocationAdapter.swift"]
    ),
    .testTarget(
      name: "StarterkitPlatformPolicyTests",
      dependencies: ["StarterkitPlatformPolicy"],
      path: "Tests"
    ),
  ]
)
