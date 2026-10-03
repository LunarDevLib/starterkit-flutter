import Darwin
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

  func testBoundedCopyAcceptsAndMeasuresDecodedStillImage() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.png")
    let destination = directory.appendingPathComponent("copy.img")
    try pngFixture.write(to: source)

    let media = try MediaFilePolicy.copyAndValidate(
      source: source,
      destination: destination,
      maxBytes: pngFixture.count,
      maxPixels: 1
    )
    XCTAssertEqual(media.byteLength, pngFixture.count)
    XCTAssertEqual(media.width, 1)
    XCTAssertEqual(media.height, 1)
    XCTAssertEqual(media.mimeType, "public.png")
    XCTAssertEqual(try Data(contentsOf: destination), pngFixture)
    let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  func testBoundedCopyRejectsOversizeAndCleansOutput() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.png")
    let destination = directory.appendingPathComponent("copy.img")
    try pngFixture.write(to: source)

    XCTAssertThrowsError(
      try MediaFilePolicy.copyAndValidate(
        source: source,
        destination: destination,
        maxBytes: pngFixture.count - 1,
        maxPixels: 1
      )
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

    try pngFixture.write(to: source)
    let growingDestination = directory.appendingPathComponent("growing.img")
    XCTAssertThrowsError(
      try MediaFilePolicy.copyAndValidate(
        source: source,
        destination: growingDestination,
        maxBytes: pngFixture.count,
        maxPixels: 1,
        beforeCopy: {
          let handle = try FileHandle(forWritingTo: source)
          try handle.seekToEnd()
          try handle.write(contentsOf: Data([0x00]))
          try handle.close()
        }
      )
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: growingDestination.path))
  }

  func testBoundedCopyRejectsSymlinkDirectoryAndChangedPath() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.png")
    let link = directory.appendingPathComponent("link.png")
    let folder = directory.appendingPathComponent("folder")
    try pngFixture.write(to: source)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)

    for invalidSource in [link, folder] {
      let destination = directory.appendingPathComponent(UUID().uuidString)
      XCTAssertThrowsError(
        try MediaFilePolicy.copyAndValidate(
          source: invalidSource,
          destination: destination,
          maxBytes: pngFixture.count + 1,
          maxPixels: 1
        )
      )
      XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    let changedDestination = directory.appendingPathComponent("changed.img")
    XCTAssertThrowsError(
      try MediaFilePolicy.copyAndValidate(
        source: source,
        destination: changedDestination,
        maxBytes: pngFixture.count + 1,
        maxPixels: 1,
        beforeCopy: {
          try FileManager.default.removeItem(at: source)
          try Data([0x01]).write(to: source)
        }
      )
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: changedDestination.path))
  }

  func testBoundedCopyRejectsTruncatedAndCorruptImages() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let corruptPayload = Data(
      base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAACklEQVR4nABpbnZhbGlkjwsOygAAAABJRU5ErkJggg=="
    )!
    for invalidBytes in [
      Data(pngFixture.dropLast(8)), Data(repeating: 0x41, count: 64), corruptPayload,
    ] {
      let source = directory.appendingPathComponent(UUID().uuidString)
      let destination = directory.appendingPathComponent(UUID().uuidString)
      try invalidBytes.write(to: source)
      XCTAssertThrowsError(
        try MediaFilePolicy.copyAndValidate(
          source: source,
          destination: destination,
          maxBytes: invalidBytes.count,
          maxPixels: 1
        )
      )
      XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
  }

  func testPNGIntegrityAcceptsCompleteFixtureAndHonorsCancellation() throws {
    XCTAssertNoThrow(
      try PNGIntegrity.validate(
        pngFixture, maxBytes: pngFixture.count, maxPixels: 1, isCancelled: { false }
      )
    )
    XCTAssertThrowsError(
      try PNGIntegrity.validate(
        pngFixture, maxBytes: pngFixture.count, maxPixels: 1, isCancelled: { true }
      )
    ) { XCTAssertEqual($0 as? MediaFileError, .cancelled) }
  }

  func testPixelCapRejectsBeforeThumbnailDecode() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("two-pixels.png")
    let destination = directory.appendingPathComponent("copy.img")
    let twoPixels = Data(
      base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAAD0lEQVR4nGP4z8DA8J8BAAf/Af8Bf4mnAAAAAElFTkSuQmCC"
    )!
    try twoPixels.write(to: source)
    XCTAssertThrowsError(
      try MediaFilePolicy.copyAndValidate(
        source: source, destination: destination, maxBytes: twoPixels.count, maxPixels: 1
      )
    ) { XCTAssertEqual($0 as? MediaFileError, .invalidDimensions) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
  }

  func testInPlaceSourceMutationShrinkAndWithinLimitGrowthAreRejected() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    for changedBytes in [
      Data(pngFixture.dropLast()), pngFixture + Data([0]), Data(repeating: 0x41, count: pngFixture.count),
    ] {
      let source = directory.appendingPathComponent(UUID().uuidString)
      let destination = directory.appendingPathComponent(UUID().uuidString)
      try pngFixture.write(to: source)
      XCTAssertThrowsError(
        try MediaFilePolicy.copyAndValidate(
          source: source, destination: destination,
          maxBytes: pngFixture.count + 1, maxPixels: 1,
          beforeCopy: {
            let handle = try FileHandle(forWritingTo: source)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: changedBytes)
            // Make same-length mutation deterministic on filesystems with coarse timestamps.
            try FileManager.default.setAttributes(
              [.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: source.path
            )
          }
        )
      ) { XCTAssertEqual($0 as? MediaFileError, .changed) }
      XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
  }

  func testEmptySourceAndFIFOFailWithoutCreatingOutput() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let empty = directory.appendingPathComponent("empty")
    let fifo = directory.appendingPathComponent("fifo")
    try Data().write(to: empty)
    XCTAssertEqual(fifo.path.withCString { mkfifo($0, mode_t(0o600)) }, 0)
    for source in [empty, fifo] {
      let destination = directory.appendingPathComponent(UUID().uuidString)
      XCTAssertThrowsError(
        try MediaFilePolicy.copyAndValidate(
          source: source, destination: destination, maxBytes: pngFixture.count, maxPixels: 1
        )
      )
      XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
  }

  func testExistingOutputIsNeitherOverwrittenNorDeleted() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.png")
    let destination = directory.appendingPathComponent("existing")
    let existing = Data([1, 2, 3])
    try pngFixture.write(to: source)
    try existing.write(to: destination)
    XCTAssertThrowsError(
      try MediaFilePolicy.copyAndValidate(
        source: source, destination: destination, maxBytes: pngFixture.count, maxPixels: 1
      )
    ) { XCTAssertEqual($0 as? MediaFileError, .output) }
    XCTAssertEqual(try Data(contentsOf: destination), existing)
  }

  func testInvalidatedWorkerCopyCleansPrivateOutput() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.png")
    let destination = directory.appendingPathComponent("copy.img")
    try pngFixture.write(to: source)
    let operation = MediaOperationLifecycle { _ in XCTFail("Rejected copy owns its own cleanup") }
    XCTAssertTrue(operation.queueWork())
    XCTAssertTrue(operation.startWork())
    XCTAssertThrowsError(
      try MediaFilePolicy.copyAndValidate(
        source: source, destination: destination, maxBytes: pngFixture.count, maxPixels: 1,
        beforeCopy: { operation.invalidate() },
        isCancelled: { operation.isInvalidated }
      )
    ) { XCTAssertEqual($0 as? MediaFileError, .cancelled) }
    XCTAssertFalse(operation.completeWork(output: nil))
    XCTAssertFalse(operation.settle())
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
  }

  private var pngFixture: Data {
    Data(
      base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
    )!
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
