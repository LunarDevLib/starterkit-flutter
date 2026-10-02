import Foundation

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
