// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "StarterkitQrBarcodeNative",
  platforms: [.macOS(.v12)],
  products: [
    .library(name: "StarterkitQrBarcodeNative", targets: ["StarterkitQrBarcodeNative"])
  ],
  targets: [
    .target(
      name: "StarterkitQrBarcodeNative",
      path: "Classes",
      exclude: ["StarterkitQrBarcodePlugin.swift"]
    ),
    .testTarget(
      name: "StarterkitQrBarcodeNativeTests",
      dependencies: ["StarterkitQrBarcodeNative"],
      path: "Tests"
    ),
  ]
)
