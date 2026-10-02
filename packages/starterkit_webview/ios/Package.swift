// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "StarterkitWebViewNativePolicy",
  platforms: [.macOS(.v12)],
  products: [
    .library(name: "StarterkitWebViewNativePolicy", targets: ["StarterkitWebViewNativePolicy"])
  ],
  targets: [
    .target(
      name: "StarterkitWebViewNativePolicy",
      path: "Classes",
      exclude: ["StarterkitWebViewPlugin.swift"]
    ),
    .testTarget(
      name: "StarterkitWebViewNativePolicyTests",
      dependencies: ["StarterkitWebViewNativePolicy"],
      path: "Tests"
    ),
  ]
)
