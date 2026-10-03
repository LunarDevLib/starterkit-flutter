import Foundation

enum BiometricType: Equatable {
  case none
  case touchID
  case faceID
}

enum BiometricFailureReason: Equatable {
  case authenticationFailed
  case userCancel
  case appCancel
  case systemCancel
  case userFallback
  case biometryLockout
  case biometryNotEnrolled
  case biometryNotAvailable
  case passcodeNotSet
  case other
}

enum BiometricAvailabilityState: String, Equatable {
  case ready
  case permissionRequired
  case noHardware
  case notEnrolled
  case lockedOut
  case unavailable
}

enum BiometricResultKind: String, Equatable {
  case authenticated
  case cancelled
  case denied
  case lockedOut
  case unavailable
  case invalid
  case conflict
  case failure
}

enum BiometricForegroundState: Equatable {
  case active
  case inactive
  case background
  case unavailable
}

struct BiometricAvailability: Equatable {
  let state: BiometricAvailabilityState
  let code: String
}

struct BiometricOutcome: Equatable {
  let kind: BiometricResultKind
  let code: String
}

struct BiometricRequest: Equatable {
  let requestID: String
  let reason: String
}

enum BiometricRequestValidation: Equatable {
  case valid(BiometricRequest)
  case invalidRequest(requestID: String)
  case invalidReason(requestID: String)
}

enum BiometricPolicy {
  static let faceIDPurposeKey = "NSFaceIDUsageDescription"
  static let maximumReasonUTF8Bytes = 256

  static func isValidRequestID(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    return bytes.count == 32 && bytes.allSatisfy {
      ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
    }
  }

  static func isValidReason(_ reason: String) -> Bool {
    !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && reason.utf8.count <= maximumReasonUTF8Bytes
      && !reason.unicodeScalars.contains(where: { $0.value == 0 })
  }

  static func validateAuthenticationArguments(
    _ arguments: [String: Any]?
  ) -> BiometricRequestValidation {
    let candidateID = arguments?["requestId"] as? String
    let requestID = candidateID.flatMap { isValidRequestID($0) ? $0 : nil } ?? ""
    guard let arguments, Set(arguments.keys) == ["requestId", "reason"],
      let suppliedID = arguments["requestId"] as? String,
      isValidRequestID(suppliedID),
      let reason = arguments["reason"] as? String
    else {
      return .invalidRequest(requestID: requestID)
    }
    guard isValidReason(reason) else { return .invalidReason(requestID: suppliedID) }
    return .valid(BiometricRequest(requestID: suppliedID, reason: reason))
  }

  static func availability(
    canEvaluate: Bool,
    error: BiometricFailureReason?,
    biometryType: BiometricType,
    faceIDPurposeConfigured: Bool
  ) -> BiometricAvailability {
    if biometryType == .faceID && !faceIDPurposeConfigured {
      return BiometricAvailability(state: .unavailable, code: "biometric.face_id_not_configured")
    }
    guard canEvaluate else {
      guard let error else {
        return BiometricAvailability(state: .unavailable, code: "biometric.unavailable")
      }
      return availability(for: error)
    }
    guard error == nil else {
      return BiometricAvailability(state: .unavailable, code: "biometric.platform_failure")
    }
    return BiometricAvailability(state: .ready, code: "biometric.ready")
  }

  static func authenticationPreflightFailure(
    canEvaluate: Bool,
    error: BiometricFailureReason?,
    biometryType: BiometricType,
    faceIDPurposeConfigured: Bool
  ) -> BiometricOutcome? {
    if biometryType == .faceID && !faceIDPurposeConfigured {
      return BiometricOutcome(kind: .unavailable, code: "biometric.face_id_not_configured")
    }
    if canEvaluate, error == nil { return nil }
    guard let error else {
      return BiometricOutcome(kind: .unavailable, code: "biometric.unavailable")
    }
    switch error {
    case .passcodeNotSet:
      return BiometricOutcome(kind: .denied, code: "biometric.permission_required")
    case .biometryNotAvailable:
      return BiometricOutcome(kind: .unavailable, code: "biometric.no_hardware")
    case .biometryNotEnrolled:
      return BiometricOutcome(kind: .unavailable, code: "biometric.not_enrolled")
    case .biometryLockout:
      return BiometricOutcome(kind: .lockedOut, code: "biometric.locked_out")
    case .authenticationFailed, .userCancel, .appCancel, .systemCancel, .userFallback, .other:
      return BiometricOutcome(kind: .failure, code: "biometric.platform_failure")
    }
  }

  static func authenticationOutcome(
    success: Bool,
    error: BiometricFailureReason?,
    foreground: BiometricForegroundState,
    requestID: String
  ) -> [String: String] {
    let outcome: BiometricOutcome
    switch foreground {
    case .background:
      outcome = BiometricOutcome(kind: .cancelled, code: "biometric.backgrounded")
    case .unavailable:
      outcome = BiometricOutcome(kind: .unavailable, code: "biometric.activity_unavailable")
    case .active, .inactive:
      if success {
        outcome = error == nil
          ? BiometricOutcome(kind: .authenticated, code: "biometric.authenticated")
          : BiometricOutcome(kind: .failure, code: "biometric.platform_failure")
      } else {
        outcome = authenticationFailure(error)
      }
    }
    return authenticationEnvelope(outcome, requestID: requestID)
  }

  static func authenticationEnvelope(
    _ outcome: BiometricOutcome, requestID: String
  ) -> [String: String] {
    return ["kind": outcome.kind.rawValue, "code": outcome.code, "requestId": requestID]
  }

  static func availabilityEnvelope(_ availability: BiometricAvailability) -> [String: String] {
    return ["state": availability.state.rawValue, "code": availability.code]
  }

  static func invalidAuthenticationResponse(requestID: String) -> [String: String] {
    return authenticationEnvelope(
      BiometricOutcome(kind: .invalid, code: "biometric.invalid_request"), requestID: requestID
    )
  }

  static func invalidReasonResponse(requestID: String) -> [String: String] {
    return authenticationEnvelope(
      BiometricOutcome(kind: .denied, code: "biometric.invalid_reason"), requestID: requestID
    )
  }

  static func conflictResponse(requestID: String) -> [String: String] {
    return authenticationEnvelope(
      BiometricOutcome(kind: .conflict, code: "biometric.operation_in_progress"),
      requestID: requestID
    )
  }

  static func detachedResponse(method: String, arguments: [String: Any]?) -> Any? {
    let candidateID = arguments?["requestId"] as? String
    let requestID = candidateID.flatMap { isValidRequestID($0) ? $0 : nil } ?? ""
    switch method {
    case "biometricAvailability":
      return availabilityEnvelope(
        BiometricAvailability(state: .unavailable, code: "biometric.platform_unavailable")
      )
    case "authenticateBiometric":
      return authenticationEnvelope(
        BiometricOutcome(kind: .cancelled, code: "biometric.engine_detached"),
        requestID: requestID
      )
    case "cancelBiometric":
      return false
    default:
      return nil
    }
  }

  static func classifyError(
    domain: String,
    code: Int,
    localAuthenticationDomain: String,
    classifyLocalCode: (Int) -> BiometricFailureReason?
  ) -> BiometricFailureReason {
    guard domain == localAuthenticationDomain else { return .other }
    return classifyLocalCode(code) ?? .other
  }

  static func canStart(in foreground: BiometricForegroundState) -> Bool {
    foreground == .active
  }

  static func startFailure(in foreground: BiometricForegroundState) -> BiometricOutcome? {
    switch foreground {
    case .active: return nil
    case .inactive, .background:
      return BiometricOutcome(kind: .unavailable, code: "biometric.foreground_required")
    case .unavailable:
      return BiometricOutcome(kind: .unavailable, code: "biometric.activity_unavailable")
    }
  }

  static func promptStartFailure(in foreground: BiometricForegroundState) -> BiometricOutcome? {
    switch foreground {
    case .active: return nil
    case .inactive:
      return BiometricOutcome(kind: .unavailable, code: "biometric.foreground_required")
    case .background:
      return BiometricOutcome(kind: .cancelled, code: "biometric.backgrounded")
    case .unavailable:
      return BiometricOutcome(kind: .unavailable, code: "biometric.activity_unavailable")
    }
  }

  static func canAcceptReply(in foreground: BiometricForegroundState) -> Bool {
    foreground == .active || foreground == .inactive
  }

  private static func availability(for error: BiometricFailureReason) -> BiometricAvailability {
    switch error {
    case .passcodeNotSet:
      return BiometricAvailability(state: .permissionRequired, code: "biometric.permission_required")
    case .biometryNotAvailable:
      return BiometricAvailability(state: .noHardware, code: "biometric.no_hardware")
    case .biometryNotEnrolled:
      return BiometricAvailability(state: .notEnrolled, code: "biometric.not_enrolled")
    case .biometryLockout:
      return BiometricAvailability(state: .lockedOut, code: "biometric.locked_out")
    case .authenticationFailed, .userCancel, .appCancel, .systemCancel, .userFallback, .other:
      return BiometricAvailability(state: .unavailable, code: "biometric.platform_failure")
    }
  }

  private static func authenticationFailure(_ error: BiometricFailureReason?) -> BiometricOutcome {
    guard let error else {
      return BiometricOutcome(kind: .denied, code: "biometric.denied")
    }
    switch error {
    case .authenticationFailed:
      return BiometricOutcome(kind: .denied, code: "biometric.denied")
    case .userCancel, .appCancel, .systemCancel, .userFallback:
      return BiometricOutcome(kind: .cancelled, code: "biometric.cancelled")
    case .biometryLockout:
      return BiometricOutcome(kind: .lockedOut, code: "biometric.locked_out")
    case .biometryNotEnrolled:
      return BiometricOutcome(kind: .unavailable, code: "biometric.not_enrolled")
    case .biometryNotAvailable:
      return BiometricOutcome(kind: .unavailable, code: "biometric.no_hardware")
    case .passcodeNotSet:
      return BiometricOutcome(kind: .denied, code: "biometric.permission_required")
    case .other:
      return BiometricOutcome(kind: .failure, code: "biometric.platform_failure")
    }
  }
}
