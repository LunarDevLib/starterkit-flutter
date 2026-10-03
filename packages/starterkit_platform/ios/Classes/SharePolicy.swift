import CoreFoundation
import Foundation

enum ShareOutcome: String, CaseIterable {
  case completed, cancelled, invalidPayload, hostUnavailable, fileUnavailable
  case conflict, engineDetached, platformFailure

  var wire: [String: String] {
    let pair: (String, String)
    switch self {
    case .completed: pair = ("completed", "share.completed")
    case .cancelled: pair = ("cancelled", "share.cancelled")
    case .invalidPayload: pair = ("invalid", "share.invalid_payload")
    case .hostUnavailable: pair = ("unavailable", "share.host_unavailable")
    case .fileUnavailable: pair = ("unavailable", "share.file_unavailable")
    case .conflict: pair = ("conflict", "share.operation_in_progress")
    case .engineDetached: pair = ("cancelled", "share.engine_detached")
    case .platformFailure: pair = ("failure", "share.platform_failure")
    }
    return ["kind": pair.0, "code": pair.1]
  }
}

struct SharePayload {
  let text: String?
  let httpsURL: URL?
  let fileURL: URL?
  let anchor: CGRect
}

enum SharePolicy {
  static let maximumFileBytes = 10 * 1024 * 1024
  private static let sensitiveKeys = [
    "token", "access_token", "authorization", "auth", "api_key", "key",
    "password", "secret", "session", "code",
  ]

  static func parse(_ arguments: [String: Any]?) -> SharePayload? {
    guard let arguments,
      Set(arguments.keys).isSubset(of: ["text", "httpsUrl", "fileUri", "anchor"]),
      let rect = anchor(arguments["anchor"])
    else { return nil }
    var values: [String: String] = [:]
    for key in ["text", "httpsUrl", "fileUri"] {
      guard let raw = arguments[key], !(raw is NSNull) else { continue }
      guard let value = validString(raw, maximumUTF16: key == "text" ? 8000 : 2048) else {
        return nil
      }
      values[key] = value
    }
    let text = values["text"]
    if let text, text.unicodeScalars.count > 4000 || text.utf8.count > 16384
      || hasControls(text) { return nil }
    let https = values["httpsUrl"].flatMap(httpsURL)
    let file = values["fileUri"].flatMap(fileURL)
    guard (values["httpsUrl"] == nil || https != nil),
      (values["fileUri"] == nil || file != nil),
      !(text ?? "").isEmpty || https != nil || file != nil
    else { return nil }
    return SharePayload(text: text, httpsURL: https, fileURL: file, anchor: rect)
  }

  // Inspect UTF-16 before bridging NSString: Swift String would repair lone surrogates.
  private static func validString(_ raw: Any, maximumUTF16: Int) -> String? {
    guard let value = raw as? NSString, value.length <= maximumUTF16 else { return nil }
    var index = 0
    while index < value.length {
      let unit = value.character(at: index)
      if (0xD800...0xDBFF).contains(unit) {
        index += 1
        guard index < value.length,
          (0xDC00...0xDFFF).contains(value.character(at: index)) else { return nil }
      } else if (0xDC00...0xDFFF).contains(unit) {
        return nil
      }
      index += 1
    }
    return value as String
  }

  private static func hasControls(_ value: String) -> Bool {
    value.unicodeScalars.contains { $0.value < 32 || (127...159).contains($0.value) }
  }

  private static func validEscapes(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    func hex(_ byte: UInt8) -> Bool {
      (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }
    var index = 0
    while index < bytes.count {
      if bytes[index] == 37 {
        guard index + 2 < bytes.count, hex(bytes[index + 1]), hex(bytes[index + 2]) else {
          return false
        }
        index += 2
      }
      index += 1
    }
    return true
  }

  static func httpsURL(_ value: String) -> URL? {
    guard !value.isEmpty, value.utf8.count <= 2048,
      value.utf8.allSatisfy({ (33...126).contains($0) }),
      !value.contains("\\"), validEscapes(value),
      let components = URLComponents(string: value), components.scheme?.lowercased() == "https",
      components.user == nil, components.password == nil, components.fragment == nil,
      components.port == nil || components.port == 443,
      let host = components.host, !host.isEmpty, host.utf8.count <= 253,
      !host.hasSuffix("."), let separator = value.range(of: "://")
    else { return nil }
    let authority = String(value[separator.upperBound...].prefix { !"/?#".contains($0) })
    guard authority.lowercased() == host.lowercased()
      || authority.lowercased() == host.lowercased() + ":443" else { return nil }
    for label in host.split(separator: ".", omittingEmptySubsequences: false) {
      guard !label.isEmpty, label.utf8.count <= 63, !label.hasPrefix("-"), !label.hasSuffix("-"),
        label.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
          || (97...122).contains($0) || $0 == 45 }) else { return nil }
    }
    for parameter in (components.percentEncodedQuery ?? "").split(separator: "&") {
      var key = String(parameter.split(separator: "=", maxSplits: 1,
        omittingEmptySubsequences: false)[0])
      // Repeated encoding must not conceal a sensitive key.
      while key.contains("%") {
        guard validEscapes(key), let decoded = key.removingPercentEncoding, decoded != key else {
          return nil
        }
        key = decoded
      }
      guard !hasControls(key), !sensitiveKeys.contains(where: { key.lowercased().contains($0) }) else {
        return nil
      }
    }
    return components.url
  }

  static func fileURL(_ value: String) -> URL? {
    guard !value.isEmpty, value.utf8.count <= 2048, !hasControls(value),
      !value.contains("\\"), validEscapes(value),
      let components = URLComponents(string: value), components.scheme?.lowercased() == "file",
      components.query == nil, components.fragment == nil,
      components.user == nil, components.password == nil, components.port == nil,
      components.host == nil || components.host == "" || components.host == "localhost",
      components.path.hasPrefix("/"), !hasControls(components.path),
      let url = components.url, url.isFileURL
    else { return nil }
    return url
  }

  // Called only by an explicit share request, never registration or syntax validation.
  static func fileIsAvailable(_ url: URL) -> Bool {
    guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path),
      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      attributes[.type] as? FileAttributeType == .typeRegular,
      let size = attributes[.size] as? NSNumber
    else { return false }
    return size.int64Value >= 0 && size.int64Value <= Int64(maximumFileBytes)
  }

  static func anchor(_ raw: Any?) -> CGRect? {
    guard let values = raw as? [String: Any], Set(values.keys) == ["x", "y", "width", "height"]
    else { return nil }
    var numbers: [String: Double] = [:]
    for key in ["x", "y", "width", "height"] {
      guard let number = values[key] as? NSNumber,
        CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite
      else { return nil }
      numbers[key] = number.doubleValue
    }
    guard let x = numbers["x"], let y = numbers["y"], let width = numbers["width"],
      let height = numbers["height"], x >= 0, y >= 0, width > 0, height > 0,
      (x + width).isFinite, (y + height).isFinite else { return nil }
    return CGRect(x: x, y: y, width: width, height: height)
  }

  static func anchorFits(_ rect: CGRect, bounds: CGRect) -> Bool {
    !bounds.isEmpty && bounds.contains(rect)
  }

  static func completion(completed: Bool, failed: Bool) -> ShareOutcome {
    failed ? .platformFailure : (completed ? .completed : .cancelled)
  }
}

/// Main-thread-only single callback; clear ownership before invoking a reentrant reply.
final class ShareOperation {
  private var reply: (([String: String]) -> Void)?

  init(reply: @escaping ([String: String]) -> Void) { self.reply = reply }

  func settle(_ outcome: ShareOutcome) {
    let callback = reply
    reply = nil
    callback?(outcome.wire)
  }
}
