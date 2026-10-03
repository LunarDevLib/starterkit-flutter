import Foundation

enum LocationPermissionStatus: String, Equatable {
  case notDetermined
  case granted
  case denied
  case restricted
  case unavailable
}

enum LocationAuthorization: Equatable {
  case notDetermined
  case granted
  case denied
  case restricted
  case unavailable
}

enum LocationNativeErrorReason: Equatable {
  case locationUnknown
  case denied
  case other
}

enum LocationNativeFailure: Equatable {
  case providerDisabled
  case denied
  case restricted
  case providerUnavailable
  case platformFailure
}

struct LocationPermissionSnapshot: Equatable {
  let status: LocationPermissionStatus
  let code: String
  let approximate: Bool?

  var kind: String {
    switch status {
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .unavailable: return "unavailable"
    case .notDetermined, .granted: return "success"
    }
  }
}

struct ForegroundLocation: Equatable {
  let latitude: Double
  let longitude: Double
  let accuracyMeters: Double
  let approximate: Bool
  let ageMillis: Int
}

enum LocationSampleError: String, Equatable {
  case invalidCoordinate = "location.invalid_coordinate"
  case invalidAccuracy = "location.invalid_accuracy"
  case stale = "location.sample_stale"
  case invalidTime = "location.invalid_sample_time"
  case foregroundRequired = "location.foreground_required"
  case invalidLimits = "location.invalid_limits"
}

enum LocationSampleAssessment: Equatable {
  case valid(ForegroundLocation)
  case invalid(LocationSampleError)
}

enum LocationPolicy {
  static let defaultPermissionTimeoutMillis = 60_000
  static let defaultLocationTimeoutMillis = 15_000
  static let defaultMaximumAgeMillis = 5_000
  static let maximumTimeoutMillis = 60_000
  static let maximumAgeMillis = 60_000
  static let futureTimestampToleranceSeconds = 1.0
  static let debugPurposeKey = "NSLocationWhenInUseUsageDescription"

  static func isValidRequestID(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    return bytes.count == 32 && bytes.allSatisfy {
      ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
    }
  }

  static func echoedRequestID(_ arguments: [String: Any]?) -> String {
    arguments?["requestId"] as? String ?? ""
  }

  /// Flutter's standard message codec carries integer arguments as NSNumber. Reject booleans
  /// and floating-point values instead of accepting NSNumber's lossy Int conversions.
  static func strictInteger(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber else { return nil }
    let type = String(cString: number.objCType)
    guard ["s", "i", "l", "q", "S", "I", "L", "Q", "C"].contains(type) else {
      return nil
    }
    return Int(number.stringValue)
  }

  static func timeoutMillis(
    _ raw: Any?, defaultValue: Int
  ) -> Int? {
    guard (1...maximumTimeoutMillis).contains(defaultValue) else { return nil }
    guard let raw else { return defaultValue }
    guard let value = strictInteger(raw), (1...maximumTimeoutMillis).contains(value) else {
      return nil
    }
    return value
  }

  static func parseMaximumAgeMillis(_ raw: Any?) -> Int? {
    guard let raw else { return defaultMaximumAgeMillis }
    guard let value = strictInteger(raw), (1...maximumAgeMillis).contains(value) else {
      return nil
    }
    return value
  }

  static func hasPurpose(_ purpose: String?) -> Bool {
    guard let purpose else { return false }
    return !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  static func shouldRequestAuthorization(_ authorization: LocationAuthorization) -> Bool {
    authorization == .notDetermined
  }

  static func permissionSnapshot(
    authorization: LocationAuthorization,
    servicesEnabled: Bool,
    purposeConfigured: Bool,
    approximate: Bool
  ) -> LocationPermissionSnapshot {
    guard servicesEnabled else {
      return LocationPermissionSnapshot(status: .unavailable, code: "location.disabled", approximate: nil)
    }
    guard purposeConfigured else {
      return LocationPermissionSnapshot(
        status: .unavailable, code: "location.permission_not_configured", approximate: nil
      )
    }
    switch authorization {
    case .notDetermined:
      return LocationPermissionSnapshot(
        status: .notDetermined, code: "location.permission_status", approximate: nil
      )
    case .granted:
      return LocationPermissionSnapshot(
        status: .granted, code: "location.permission_status", approximate: approximate
      )
    case .denied:
      return LocationPermissionSnapshot(status: .denied, code: "location.permission_status", approximate: nil)
    case .restricted:
      return LocationPermissionSnapshot(
        status: .restricted, code: "location.permission_status", approximate: nil
      )
    case .unavailable:
      return LocationPermissionSnapshot(
        status: .unavailable, code: "location.platform_unavailable", approximate: nil
      )
    }
  }

  static func permissionEnvelope(
    kind: String,
    code: String,
    status: LocationPermissionStatus,
    approximate: Bool?,
    requestID: String? = nil
  ) -> [String: Any] {
    let approximateValue: Any = approximate.map { $0 as Any } ?? NSNull()
    var result: [String: Any] = [
      "kind": kind,
      "code": code,
      "status": status.rawValue,
      "approximate": approximateValue,
    ]
    if let requestID { result["requestId"] = requestID }
    return result
  }

  static func permissionStatusEnvelope(_ snapshot: LocationPermissionSnapshot) -> [String: Any] {
    permissionEnvelope(
      kind: snapshot.status == .unavailable ? "unavailable" : "success",
      code: snapshot.code, status: snapshot.status,
      approximate: snapshot.approximate
    )
  }

  static func permissionOperationEnvelope(
    _ snapshot: LocationPermissionSnapshot, requestID: String
  ) -> [String: Any] {
    let code: String
    switch snapshot.status {
    case .granted: code = "location.permission_granted"
    case .denied: code = "location.denied"
    case .restricted: code = "location.restricted"
    case .notDetermined:
      return permissionEnvelope(
        kind: "unavailable",
        code: "location.permission_required",
        status: .unavailable,
        approximate: nil,
        requestID: requestID
      )
    case .unavailable: code = snapshot.code
    }
    return permissionEnvelope(
      kind: snapshot.kind,
      code: code,
      status: snapshot.status,
      approximate: snapshot.approximate,
      requestID: requestID
    )
  }

  static func permissionError(
    _ kind: String,
    _ code: String,
    requestID: String,
    status: LocationPermissionStatus = .unavailable,
    approximate: Bool? = nil
  ) -> [String: Any] {
    permissionEnvelope(
      kind: kind, code: code, status: status, approximate: approximate, requestID: requestID
    )
  }

  static func locationError(_ kind: String, _ code: String, requestID: String) -> [String: Any] {
    ["kind": kind, "code": code, "requestId": requestID]
  }

  static func locationAuthorizationError(
    _ authorization: LocationAuthorization, requestID: String
  ) -> [String: Any] {
    switch authorization {
    case .denied: return locationError("denied", "location.denied", requestID: requestID)
    case .restricted: return locationError("restricted", "location.restricted", requestID: requestID)
    case .notDetermined: return locationError("unavailable", "location.permission_required", requestID: requestID)
    case .unavailable: return locationError("unavailable", "location.platform_unavailable", requestID: requestID)
    case .granted: return locationError("failure", "location.platform_failure", requestID: requestID)
    }
  }

  static func nativeFailure(
    reason: LocationNativeErrorReason,
    servicesEnabled: Bool,
    authorization: LocationAuthorization
  ) -> LocationNativeFailure {
    guard servicesEnabled else { return .providerDisabled }
    switch authorization {
    case .denied: return .denied
    case .restricted: return .restricted
    case .notDetermined, .granted, .unavailable: break
    }
    switch reason {
    case .locationUnknown: return .providerUnavailable
    case .denied: return .denied
    case .other: return .platformFailure
    }
  }

  static func nativeFailureResponse(
    _ failure: LocationNativeFailure,
    operationKind: LocationOperationKind,
    requestID: String
  ) -> [String: Any] {
    switch operationKind {
    case .permission:
      switch failure {
      case .providerDisabled:
        return permissionError("unavailable", "location.disabled", requestID: requestID)
      case .denied:
        return permissionError(
          "denied", "location.denied", requestID: requestID, status: .denied
        )
      case .restricted:
        return permissionError(
          "restricted", "location.restricted", requestID: requestID, status: .restricted
        )
      case .providerUnavailable:
        return permissionError("unavailable", "location.provider_unavailable", requestID: requestID)
      case .platformFailure:
        return permissionError("failure", "location.platform_failure", requestID: requestID)
      }
    case .location:
      switch failure {
      case .providerDisabled:
        return locationProviderError(disabled: true, requestID: requestID)
      case .denied:
        return locationAuthorizationError(.denied, requestID: requestID)
      case .restricted:
        return locationAuthorizationError(.restricted, requestID: requestID)
      case .providerUnavailable:
        return locationProviderError(disabled: false, requestID: requestID)
      case .platformFailure:
        return locationError("failure", "location.platform_failure", requestID: requestID)
      }
    }
  }

  static func locationProviderError(disabled: Bool, requestID: String) -> [String: Any] {
    locationError(
      "unavailable", disabled ? "location.provider_disabled" : "location.provider_unavailable",
      requestID: requestID
    )
  }

  static func backgroundedResponse(
    kind: LocationOperationKind, requestID: String
  ) -> [String: Any] {
    switch kind {
    case .permission: return permissionError("cancelled", "location.backgrounded", requestID: requestID)
    case .location: return locationError("cancelled", "location.backgrounded", requestID: requestID)
    }
  }

  static func locationSuccess(_ location: ForegroundLocation, requestID: String) -> [String: Any] {
    [
      "kind": "success",
      "code": "location.success",
      "requestId": requestID,
      "location": [
        "latitude": location.latitude,
        "longitude": location.longitude,
        "accuracyMeters": location.accuracyMeters,
        "approximate": location.approximate,
        "ageMillis": location.ageMillis,
      ],
    ]
  }

  static func assessSample(
    latitude: Double,
    longitude: Double,
    accuracyMeters: Double,
    timestamp: Date,
    now: Date,
    maxAgeMillis: Int,
    approximate: Bool,
    isForeground: Bool
  ) -> LocationSampleAssessment {
    guard (1...maximumAgeMillis).contains(maxAgeMillis) else { return .invalid(.invalidLimits) }
    guard isForeground else { return .invalid(.foregroundRequired) }
    guard latitude.isFinite, longitude.isFinite,
      (-90.0...90.0).contains(latitude), (-180.0...180.0).contains(longitude)
    else { return .invalid(.invalidCoordinate) }
    guard accuracyMeters.isFinite, accuracyMeters >= 0 else { return .invalid(.invalidAccuracy) }
    let timestampSeconds = timestamp.timeIntervalSince1970
    let nowSeconds = now.timeIntervalSince1970
    guard timestampSeconds.isFinite, nowSeconds.isFinite else { return .invalid(.invalidTime) }
    let rawAgeSeconds = nowSeconds - timestampSeconds
    guard rawAgeSeconds.isFinite, rawAgeSeconds >= -futureTimestampToleranceSeconds else {
      return .invalid(.invalidTime)
    }
    let ageSeconds = max(0, rawAgeSeconds)
    guard ageSeconds <= Double(maxAgeMillis) / 1_000 else { return .invalid(.stale) }
    return .valid(
      ForegroundLocation(
        latitude: latitude,
        longitude: longitude,
        accuracyMeters: accuracyMeters,
        approximate: approximate,
        ageMillis: Int(ageSeconds * 1_000)
      )
    )
  }

  static func detachedResponse(method: String, arguments: [String: Any]?) -> Any? {
    let requestID = echoedRequestID(arguments)
    switch method {
    case "locationPermissionStatus":
      return permissionEnvelope(
        kind: "unavailable", code: "location.platform_unavailable", status: .unavailable,
        approximate: nil
      )
    case "requestLocationPermission":
      return permissionError("cancelled", "location.engine_detached", requestID: requestID)
    case "locate":
      return locationError("cancelled", "location.engine_detached", requestID: requestID)
    case "cancelLocation":
      return false
    default:
      return nil
    }
  }
}
