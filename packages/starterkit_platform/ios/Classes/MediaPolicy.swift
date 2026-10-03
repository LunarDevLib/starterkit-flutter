import Foundation
import CoreGraphics
import Darwin
import ImageIO

struct MediaLimits: Equatable {
  static let maximumBytes = 20 * 1024 * 1024
  static let maximumPixels = 50 * 1000 * 1000

  let maxBytes: Int
  let maxPixels: Int

  static func parse(_ raw: [String: Any]?) -> MediaLimits? {
    guard let maxBytes = raw?["maxBytes"] as? NSNumber,
      let maxPixels = raw?["maxPixels"] as? NSNumber
    else { return nil }
    let bytes = maxBytes.intValue
    let pixels = maxPixels.intValue
    guard (1...maximumBytes).contains(bytes),
      (1...maximumPixels).contains(pixels)
    else { return nil }
    return MediaLimits(maxBytes: bytes, maxPixels: pixels)
  }
}

enum MediaPolicy {
  static func validDimensions(width: Int, height: Int, limits: MediaLimits) -> Bool {
    guard width > 0, height > 0 else { return false }
    let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
    return !overflow && (1...limits.maxPixels).contains(pixels)
  }

  static func owns(root: URL, candidate: URL) -> Bool {
    let normalizedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
    let normalizedCandidate = candidate.standardizedFileURL.resolvingSymlinksInPath().path
    return normalizedCandidate.hasPrefix(normalizedRoot + "/")
  }
}

enum MediaFileError: Error, Equatable {
  case invalidSource
  case empty
  case tooLarge
  case changed
  case invalidImage
  case invalidDimensions
  case output
  case cancelled
}

struct VerifiedMediaFile {
  let byteLength: Int
  let width: Int
  let height: Int
  let mimeType: String
}

enum MediaFilePolicy {
  private static let chunkSize = 64 * 1024
  private static let thumbnailMaximumDimension = 2_048

  /// Copies a regular, non-symlink source through an open descriptor, enforcing the
  /// limit against bytes actually read. The destination must be a new private path.
  static func copyAndValidate(
    source: URL,
    destination: URL,
    maxBytes: Int,
    maxPixels: Int,
    beforeCopy: (() throws -> Void)? = nil,
    isCancelled: () -> Bool = { false }
  ) throws -> VerifiedMediaFile {
    if isCancelled() { throw MediaFileError.cancelled }
    guard source.isFileURL, destination.isFileURL, maxBytes > 0, maxPixels > 0 else {
      throw MediaFileError.invalidSource
    }

    let sourceFD = source.path.withCString {
      open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    }
    guard sourceFD >= 0 else { throw MediaFileError.invalidSource }
    defer { _ = close(sourceFD) }

    var initial = stat()
    guard fstat(sourceFD, &initial) == 0, (initial.st_mode & S_IFMT) == S_IFREG else {
      throw MediaFileError.invalidSource
    }
    guard initial.st_size > 0 else { throw MediaFileError.empty }
    guard initial.st_size <= off_t(maxBytes) else { throw MediaFileError.tooLarge }
    try beforeCopy?()

    let destinationFD = destination.path.withCString {
      open($0, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
    }
    guard destinationFD >= 0 else { throw MediaFileError.output }
    var keepDestination = false
    defer {
      _ = close(destinationFD)
      if !keepDestination { _ = destination.path.withCString { unlink($0) } }
    }

    var total = 0
    var buffer = [UInt8](repeating: 0, count: chunkSize)
    while true {
      if isCancelled() { throw MediaFileError.cancelled }
      let count = buffer.withUnsafeMutableBytes { raw in
        read(sourceFD, raw.baseAddress!, raw.count)
      }
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw MediaFileError.invalidSource
      }
      guard count <= maxBytes - total else { throw MediaFileError.tooLarge }
      var written = 0
      while written < count {
        let result = buffer.withUnsafeBytes { raw in
          write(destinationFD, raw.baseAddress!.advanced(by: written), count - written)
        }
        if result < 0 {
          if errno == EINTR { continue }
          throw MediaFileError.output
        }
        guard result > 0 else { throw MediaFileError.output }
        written += result
      }
      total += count
    }
    guard total > 0 else { throw MediaFileError.empty }

    var finalSource = stat()
    var pathSource = stat()
    guard fstat(sourceFD, &finalSource) == 0,
      source.path.withCString({ lstat($0, &pathSource) }) == 0,
      sameSnapshot(initial, finalSource), sameSnapshot(initial, pathSource),
      initial.st_size == off_t(total)
    else {
      throw MediaFileError.changed
    }

    guard fsync(destinationFD) == 0 else { throw MediaFileError.output }
    var destinationStat = stat()
    guard fstat(destinationFD, &destinationStat) == 0,
      (destinationStat.st_mode & S_IFMT) == S_IFREG,
      destinationStat.st_size == off_t(total)
    else {
      throw MediaFileError.output
    }

    if isCancelled() { throw MediaFileError.cancelled }
    let imageURL = destination as CFURL
    guard let imageSource = CGImageSourceCreateWithURL(imageURL, nil),
      CGImageSourceGetCount(imageSource) == 1,
      let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)
        as? [CFString: Any],
      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
    else { throw MediaFileError.invalidImage }
    guard MediaPolicy.validDimensions(
      width: width,
      height: height,
      limits: MediaLimits(maxBytes: maxBytes, maxPixels: maxPixels)
    ) else { throw MediaFileError.invalidDimensions }
    guard let type = CGImageSourceGetType(imageSource) as String?,
      CGImageSourceGetStatus(imageSource) == .statusComplete,
      CGImageSourceGetStatusAtIndex(imageSource, 0) == .statusComplete
    else { throw MediaFileError.invalidImage }
    if type == "public.png" {
      let copiedBytes = try readBounded(fd: destinationFD, maxBytes: maxBytes, expectedBytes: total, isCancelled: isCancelled)
      try PNGIntegrity.validate(
        copiedBytes, maxBytes: maxBytes, maxPixels: maxPixels, isCancelled: isCancelled
      )
    }
    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
        imageSource,
        0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: thumbnailMaximumDimension,
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
      ),
      thumbnail.width > 0, thumbnail.height > 0,
      CGImageSourceGetStatus(imageSource) == .statusComplete,
      CGImageSourceGetStatusAtIndex(imageSource, 0) == .statusComplete
    else {
      throw MediaFileError.invalidImage
    }
    var finalDestinationStat = stat()
    guard destination.path.withCString({ lstat($0, &finalDestinationStat) }) == 0,
      sameSnapshot(destinationStat, finalDestinationStat)
    else {
      throw MediaFileError.output
    }

    if isCancelled() { throw MediaFileError.cancelled }
    keepDestination = true
    return VerifiedMediaFile(
      byteLength: total,
      width: width,
      height: height,
      mimeType: type
    )
  }

  private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
      && (rhs.st_mode & S_IFMT) == S_IFREG
  }

  private static func readBounded(
    fd: Int32, maxBytes: Int, expectedBytes: Int, isCancelled: () -> Bool
  ) throws -> Data {
    var contents = Data()
    contents.reserveCapacity(expectedBytes)
    var buffer = [UInt8](repeating: 0, count: chunkSize)
    var total = 0
    while true {
      if isCancelled() { throw MediaFileError.cancelled }
      let count = buffer.withUnsafeMutableBytes { bytes in
        pread(fd, bytes.baseAddress!, bytes.count, off_t(total))
      }
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw MediaFileError.invalidImage
      }
      guard count <= maxBytes - total else { throw MediaFileError.tooLarge }
      guard count <= expectedBytes - total else { throw MediaFileError.changed }
      contents.append(contentsOf: buffer.prefix(count))
      total += count
    }
    guard total == expectedBytes, total > 0 else { throw MediaFileError.changed }
    return contents
  }

  private static func sameSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
    sameFile(lhs, rhs) && lhs.st_size == rhs.st_size
      && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
      && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
      && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
      && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
  }
}

/// Per-request ownership shared by the main-thread picker/settlement and its worker.
/// Invalidation never deletes a file while the worker may still be writing it.
final class MediaOperationLifecycle {
  private enum State { case selecting, queued, running, completed, settled, invalidated }
  private let lock = NSLock()
  private var state = State.selecting
  private var workCompleted = false
  private var output: URL?
  private let cleanup: (URL) -> Void

  init(cleanup: @escaping (URL) -> Void) {
    self.cleanup = cleanup
  }

  var isInvalidated: Bool {
    lock.lock()
    defer { lock.unlock() }
    return state == .invalidated
  }

  func queueWork() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard state == .selecting else { return false }
    state = .queued
    return true
  }

  func startWork() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard state == .queued else { return false }
    state = .running
    return true
  }

  /// Called once after all writes stop, before dispatching settlement to main.
  func completeWork(output: URL?) -> Bool {
    lock.lock()
    guard !workCompleted, state == .running || state == .invalidated else {
      lock.unlock()
      return false
    }
    workCompleted = true
    let accepted = state == .running
    if accepted {
      self.output = output
      state = .completed
    }
    lock.unlock()
    if !accepted, let output { cleanup(output) }
    return accepted
  }

  /// Main-thread delivery transfers ownership to the caller exactly once.
  func settle(fromWorker: Bool = false) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    // A duplicate picker cancellation must not consume a completed worker's output.
    guard state == (fromWorker ? .completed : .selecting) else { return false }
    state = .settled
    output = nil
    return true
  }

  func invalidate() {
    lock.lock()
    guard state != .settled, state != .invalidated else {
      lock.unlock()
      return
    }
    state = .invalidated
    let abandoned = output
    output = nil
    lock.unlock()
    if let abandoned { cleanup(abandoned) }
  }
}

struct MediaMetadata {
  let path: String
  let byteLength: Int
  let width: Int
  let height: Int
  let mimeType: String

  var map: [String: Any] {
    [
      "path": path,
      "byteLength": byteLength,
      "width": width,
      "height": height,
      "mimeType": mimeType,
    ]
  }
}

func mediaOutcome(_ kind: String, _ code: String, image: MediaMetadata? = nil) -> [String: Any] {
  var value: [String: Any] = ["kind": kind, "code": code]
  if let image { value["image"] = image.map }
  return value
}
