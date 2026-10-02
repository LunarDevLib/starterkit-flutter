// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "StarterkitPreferencesNative",
  platforms: [.macOS(.v12)],
  products: [.library(name: "StarterkitPreferencesNative", targets: ["StarterkitPreferencesNative"])],
  targets: [
    .target(
      name: "StarterkitPreferencesNative",
      path: "Classes",
      exclude: ["StarterkitPreferencesPlugin.swift"]
    ),
    .testTarget(
      name: "StarterkitPreferencesNativeTests",
      dependencies: ["StarterkitPreferencesNative"],
      path: "Tests"
    ),
  ]
)
