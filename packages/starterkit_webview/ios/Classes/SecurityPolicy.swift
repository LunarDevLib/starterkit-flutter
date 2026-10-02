import CoreFoundation
import Foundation

struct TrustedOrigin: Equatable {
  let host: String
  let port: Int

  init?(configured value: String) {
    guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty,
      let boundary = value.range(of: "://")
    else { return nil }
    let start = boundary.upperBound
    let end = value[start...].firstIndex(where: { "/?#".contains($0) }) ?? value.endIndex
    let authority = value[start..<end]
    guard !authority.isEmpty, !authority.contains("%"), !authority.contains(where: \.isWhitespace),
      let components = URLComponents(string: value),
      components.scheme?.lowercased() == "https",
      components.user == nil, components.password == nil,
      components.path.isEmpty || components.path == "/",
      components.query == nil, components.fragment == nil,
      let host = components.host?.lowercased(), !host.isEmpty
    else { return nil }

    let suppliedPort: Substring?
    if authority.first == "[" {
      guard let close = authority.firstIndex(of: "]") else { return nil }
      let suffix = authority[authority.index(after: close)...]
      if suffix.isEmpty {
        suppliedPort = nil
      } else {
        guard suffix.first == ":" else { return nil }
        let digits = suffix.dropFirst()
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        suppliedPort = digits
      }
    } else if let colon = authority.lastIndex(of: ":") {
      let digits = authority[authority.index(after: colon)...]
      guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
      suppliedPort = digits
    } else {
      suppliedPort = nil
    }

    let port = components.port ?? 443
    if let suppliedPort, Int(suppliedPort) != port { return nil }
    guard (1...65535).contains(port) else { return nil }
    self.host = host
    self.port = port
  }

  var rule: String {
    let normalizedHost = host.contains(":") ? "[\(host)]" : host
    return "https://\(normalizedHost)\(port == 443 ? "" : ":\(port)")"
  }

  func matches(_ url: URL) -> Bool {
    guard url.user == nil, url.password == nil, let scheme = url.scheme,
      let start = url.absoluteString.range(of: "://")?.upperBound
    else { return false }
    let source = url.absoluteString
    let end = source[start...].firstIndex(where: { "/?#".contains($0) }) ?? source.endIndex
    return TrustedOrigin(configured: "\(scheme)://\(source[start..<end])") == self
  }

  func matches(protocol scheme: String, host otherHost: String, port otherPort: Int) -> Bool {
    scheme.lowercased() == "https" &&
      otherHost.lowercased() == host &&
      (otherPort == 0 ? 443 : otherPort) == port
  }
}

enum NavigationDecision: Equatable {
  case trustedInternal
  case localAsset
  case externalBrowser
  case externalApp
  case blocked
}

struct NavigationPolicy {
  static let localHost = "appassets.starterkit.invalid"
  static let localOrigin = "https://\(localHost)"
  static let localStartURL = "\(localOrigin)/starterkit-webview/index.html"

  let trustedOrigin: TrustedOrigin
  let externalSchemes: Set<String>

  func decide(_ url: URL, isMainFrame: Bool, linkActivated: Bool) -> NavigationDecision {
    if isLocal(url) { return .localAsset }
    if trustedOrigin.matches(url) { return .trustedInternal }
    guard isMainFrame && linkActivated, let scheme = url.scheme?.lowercased() else {
      return .blocked
    }
    if scheme == "https", url.user == nil, url.password == nil { return .externalBrowser }
    if externalSchemes.contains(scheme), url.user == nil, url.password == nil {
      return .externalApp
    }
    return .blocked
  }

  private func isLocal(_ url: URL) -> Bool {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return false
    }
    return components.scheme?.lowercased() == "https" &&
      components.host?.lowercased() == Self.localHost &&
      (components.port ?? 443) == 443 &&
      components.user == nil && components.password == nil &&
      components.query == nil && components.fragment == nil &&
      components.path.hasPrefix("/starterkit-webview/") &&
      !components.path.split(separator: "/").contains(where: {
        $0 == "." || $0 == ".." || $0.contains("%") || $0.contains("\\")
      })
  }
}

struct BridgeRequest {
  let id: String
  let method: String
}

enum BridgeRequestValidator {
  static let maxEnvelopeBytes = 16_384

  static func validate(_ body: [String: Any]) -> BridgeRequest? {
    guard JSONSerialization.isValidJSONObject(body),
      let data = try? JSONSerialization.data(withJSONObject: body),
      data.count <= maxEnvelopeBytes,
      let rawVersion = body["version"] as? NSNumber,
      CFGetTypeID(rawVersion) != CFBooleanGetTypeID(),
      rawVersion.doubleValue == 1,
      let id = body["id"] as? String, (1...128).contains(id.utf16.count),
      let method = body["method"] as? String, (1...128).contains(method.utf16.count),
      let params = body["params"] as? [String: Any],
      params.keys.allSatisfy({ !$0.isEmpty })
    else { return nil }
    return BridgeRequest(id: id, method: method)
  }
}
