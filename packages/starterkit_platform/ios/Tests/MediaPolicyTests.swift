import XCTest
@testable import StarterkitPlatformPolicy

final class MediaPolicyTests: XCTestCase {
  func testLimitsFailClosed() {
    XCTAssertNotNil(MediaLimits.parse(["maxBytes": 1024, "maxPixels": 4000]))
    XCTAssertNil(MediaLimits.parse(["maxBytes": 0, "maxPixels": 4000]))
    XCTAssertNil(
      MediaLimits.parse([
        "maxBytes": MediaLimits.maximumBytes + 1,
        "maxPixels": 4000,
      ])
    )
  }

  func testDimensionBounds() {
    let limits = MediaLimits(maxBytes: 1024, maxPixels: 100)
    XCTAssertTrue(MediaPolicy.validDimensions(width: 10, height: 10, limits: limits))
    XCTAssertFalse(MediaPolicy.validDimensions(width: 11, height: 10, limits: limits))
    XCTAssertFalse(MediaPolicy.validDimensions(width: 0, height: 10, limits: limits))
  }

  func testCleanupOwnershipRejectsSibling() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    XCTAssertTrue(
      MediaPolicy.owns(root: root, candidate: root.appendingPathComponent("child.jpg"))
    )
    XCTAssertFalse(
      MediaPolicy.owns(
        root: root,
        candidate: root.deletingLastPathComponent().appendingPathComponent("sibling.jpg")
      )
    )
  }
}
