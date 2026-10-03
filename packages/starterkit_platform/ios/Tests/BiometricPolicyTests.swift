import Foundation
import XCTest
@testable import StarterkitPlatformPolicy

final class BiometricPolicyTests: XCTestCase {
  private let requestID = "0123456789abcdef0123456789abcdef"

  func testRequestIDsAndReasonUseExactUTF8AndNULRules() {
    XCTAssertTrue(BiometricPolicy.isValidRequestID(requestID))
    XCTAssertFalse(BiometricPolicy.isValidRequestID("0123456789ABCDEF0123456789ABCDEF"))
    XCTAssertFalse(BiometricPolicy.isValidRequestID(String(repeating: "g", count: 32)))

    XCTAssertTrue(BiometricPolicy.isValidReason("  Approve local action  "))
    XCTAssertTrue(BiometricPolicy.isValidReason(String(repeating: "a", count: 256)))
    XCTAssertTrue(BiometricPolicy.isValidReason(String(repeating: "💡", count: 64)))
    XCTAssertFalse(BiometricPolicy.isValidReason(" \n\t "))
    XCTAssertFalse(BiometricPolicy.isValidReason(String(repeating: "a", count: 257)))
    XCTAssertFalse(BiometricPolicy.isValidReason(String(repeating: "💡", count: 65)))
    XCTAssertFalse(BiometricPolicy.isValidReason("Approve\0action"))
  }

  func testAuthenticationArgumentsRequireExactMapAndPreserveValidIDAndOriginalReason() {
    guard case .valid(let request) = BiometricPolicy.validateAuthenticationArguments([
      "requestId": requestID,
      "reason": "  Confirm local action  ",
    ]) else { return XCTFail("Expected valid request") }
    XCTAssertEqual(request.requestID, requestID)
    XCTAssertEqual(request.reason, "  Confirm local action  ")

    XCTAssertEqual(
      BiometricPolicy.validateAuthenticationArguments(["requestId": requestID]),
      .invalidRequest(requestID: requestID)
    )
    XCTAssertEqual(
      BiometricPolicy.validateAuthenticationArguments([
        "requestId": requestID, "reason": "Approve", "extra": true,
      ]),
      .invalidRequest(requestID: requestID)
    )
    XCTAssertEqual(
      BiometricPolicy.validateAuthenticationArguments([
        "requestId": requestID, "reason": 1,
      ]),
      .invalidRequest(requestID: requestID)
    )
    XCTAssertEqual(
      BiometricPolicy.validateAuthenticationArguments([
        "requestId": requestID, "reason": " \n ",
      ]),
      .invalidReason(requestID: requestID)
    )
    XCTAssertEqual(
      BiometricPolicy.validateAuthenticationArguments([
        "requestId": "bad", "reason": "Approve",
      ]),
      .invalidRequest(requestID: "")
    )
    XCTAssertEqual(BiometricPolicy.validateAuthenticationArguments(nil), .invalidRequest(requestID: ""))
  }

  func testAvailabilityIsAdvisoryAndMapsAssessmentBooleanAndErrors() {
    let ready = BiometricPolicy.availability(
      canEvaluate: true, error: nil, biometryType: .touchID, faceIDPurposeConfigured: false
    )
    XCTAssertEqual(ready, BiometricAvailability(state: .ready, code: "biometric.ready"))

    let noError = BiometricPolicy.availability(
      canEvaluate: false, error: nil, biometryType: .none, faceIDPurposeConfigured: true
    )
    XCTAssertEqual(noError, BiometricAvailability(state: .unavailable, code: "biometric.unavailable"))

    let cases: [(BiometricFailureReason, BiometricAvailability)] = [
      (.passcodeNotSet, BiometricAvailability(state: .permissionRequired, code: "biometric.permission_required")),
      (.biometryNotAvailable, BiometricAvailability(state: .noHardware, code: "biometric.no_hardware")),
      (.biometryNotEnrolled, BiometricAvailability(state: .notEnrolled, code: "biometric.not_enrolled")),
      (.biometryLockout, BiometricAvailability(state: .lockedOut, code: "biometric.locked_out")),
      (.other, BiometricAvailability(state: .unavailable, code: "biometric.platform_failure")),
    ]
    for (reason, expected) in cases {
      XCTAssertEqual(
        BiometricPolicy.availability(
          canEvaluate: false, error: reason, biometryType: .none, faceIDPurposeConfigured: true
        ), expected
      )
    }
    XCTAssertEqual(
      BiometricPolicy.availability(
        canEvaluate: true, error: .other, biometryType: .touchID, faceIDPurposeConfigured: true
      ),
      BiometricAvailability(state: .unavailable, code: "biometric.platform_failure")
    )
  }

  func testFaceIDPurposeIsRequiredBeforeEvaluationButTouchIDIsNotBlocked() {
    XCTAssertEqual(
      BiometricPolicy.availability(
        canEvaluate: true, error: nil, biometryType: .faceID, faceIDPurposeConfigured: false
      ),
      BiometricAvailability(state: .unavailable, code: "biometric.face_id_not_configured")
    )
    XCTAssertEqual(
      BiometricPolicy.authenticationPreflightFailure(
        canEvaluate: true, error: nil, biometryType: .faceID, faceIDPurposeConfigured: false
      ),
      BiometricOutcome(kind: .unavailable, code: "biometric.face_id_not_configured")
    )
    XCTAssertNil(
      BiometricPolicy.authenticationPreflightFailure(
        canEvaluate: true, error: nil, biometryType: .touchID, faceIDPurposeConfigured: false
      )
    )
    XCTAssertNil(
      BiometricPolicy.authenticationPreflightFailure(
        canEvaluate: true, error: nil, biometryType: .faceID, faceIDPurposeConfigured: true
      )
    )
  }

  func testAuthenticationPreflightNeverTreatsFalseOrMissingErrorAsReady() {
    XCTAssertEqual(
      BiometricPolicy.authenticationPreflightFailure(
        canEvaluate: false, error: nil, biometryType: .none, faceIDPurposeConfigured: true
      ),
      BiometricOutcome(kind: .unavailable, code: "biometric.unavailable")
    )
    let mapped: [(BiometricFailureReason, BiometricOutcome)] = [
      (.passcodeNotSet, BiometricOutcome(kind: .denied, code: "biometric.permission_required")),
      (.biometryNotAvailable, BiometricOutcome(kind: .unavailable, code: "biometric.no_hardware")),
      (.biometryNotEnrolled, BiometricOutcome(kind: .unavailable, code: "biometric.not_enrolled")),
      (.biometryLockout, BiometricOutcome(kind: .lockedOut, code: "biometric.locked_out")),
      (.other, BiometricOutcome(kind: .failure, code: "biometric.platform_failure")),
    ]
    for (reason, expected) in mapped {
      XCTAssertEqual(
        BiometricPolicy.authenticationPreflightFailure(
          canEvaluate: false, error: reason, biometryType: .none, faceIDPurposeConfigured: true
        ), expected
      )
    }
  }

  func testAuthenticationEvaluationUsesTerminalTypedOutcomesAndExactEnvelopes() {
    let cases: [(BiometricFailureReason, String, String)] = [
      (.authenticationFailed, "denied", "biometric.denied"),
      (.userCancel, "cancelled", "biometric.cancelled"),
      (.appCancel, "cancelled", "biometric.cancelled"),
      (.systemCancel, "cancelled", "biometric.cancelled"),
      (.userFallback, "cancelled", "biometric.cancelled"),
      (.biometryLockout, "lockedOut", "biometric.locked_out"),
      (.biometryNotEnrolled, "unavailable", "biometric.not_enrolled"),
      (.biometryNotAvailable, "unavailable", "biometric.no_hardware"),
      (.passcodeNotSet, "denied", "biometric.permission_required"),
      (.other, "failure", "biometric.platform_failure"),
    ]
    for (reason, kind, code) in cases {
      let response = BiometricPolicy.authenticationOutcome(
        success: false, error: reason, foreground: .active, requestID: requestID
      )
      XCTAssertEqual(response["kind"], kind)
      XCTAssertEqual(response["code"], code)
      XCTAssertEqual(response["requestId"], requestID)
      XCTAssertEqual(Set(response.keys), ["kind", "code", "requestId"])
    }

    let noMatch = BiometricPolicy.authenticationOutcome(
      success: false, error: nil, foreground: .active, requestID: requestID
    )
    XCTAssertEqual(noMatch["kind"], "denied")
    XCTAssertEqual(noMatch["code"], "biometric.denied")
    XCTAssertEqual(
      BiometricPolicy.authenticationOutcome(
        success: true, error: nil, foreground: .active, requestID: requestID
      )["kind"], "authenticated"
    )
    let contradictory = BiometricPolicy.authenticationOutcome(
      success: true, error: .userCancel, foreground: .active, requestID: requestID
    )
    XCTAssertEqual(contradictory["kind"], "failure")
    XCTAssertEqual(contradictory["code"], "biometric.platform_failure")
  }

  func testInactiveModalAllowsReplyButActualBackgroundCannotAuthenticate() {
    XCTAssertTrue(BiometricPolicy.canStart(in: .active))
    XCTAssertFalse(BiometricPolicy.canStart(in: .inactive))
    XCTAssertFalse(BiometricPolicy.canStart(in: .background))
    XCTAssertNil(BiometricPolicy.startFailure(in: .active))
    XCTAssertEqual(
      BiometricPolicy.startFailure(in: .inactive),
      BiometricOutcome(kind: .unavailable, code: "biometric.foreground_required")
    )
    XCTAssertEqual(
      BiometricPolicy.startFailure(in: .unavailable),
      BiometricOutcome(kind: .unavailable, code: "biometric.activity_unavailable")
    )
    XCTAssertEqual(
      BiometricPolicy.promptStartFailure(in: .background),
      BiometricOutcome(kind: .cancelled, code: "biometric.backgrounded")
    )
    XCTAssertTrue(BiometricPolicy.canAcceptReply(in: .inactive))
    XCTAssertFalse(BiometricPolicy.canAcceptReply(in: .background))

    XCTAssertEqual(
      BiometricPolicy.authenticationOutcome(
        success: true, error: nil, foreground: .inactive, requestID: requestID
      )["kind"], "authenticated"
    )
    let background = BiometricPolicy.authenticationOutcome(
      success: true, error: nil, foreground: .background, requestID: requestID
    )
    XCTAssertEqual(background["kind"], "cancelled")
    XCTAssertEqual(background["code"], "biometric.backgrounded")
    let unavailable = BiometricPolicy.authenticationOutcome(
      success: true, error: nil, foreground: .unavailable, requestID: requestID
    )
    XCTAssertEqual(unavailable["kind"], "unavailable")
    XCTAssertEqual(unavailable["code"], "biometric.activity_unavailable")
  }

  func testNonLocalAuthenticationErrorDomainCannotUseLocalCodeMapping() {
    var classifications = 0
    let foreign = BiometricPolicy.classifyError(
      domain: "untrusted.error.domain", code: 6,
      localAuthenticationDomain: "local.authentication.domain"
    ) { _ in
      classifications += 1
      return .biometryLockout
    }
    XCTAssertEqual(foreign, .other)
    XCTAssertEqual(classifications, 0)

    let local = BiometricPolicy.classifyError(
      domain: "local.authentication.domain", code: 6,
      localAuthenticationDomain: "local.authentication.domain"
    ) { code in code == 6 ? .biometryLockout : nil }
    XCTAssertEqual(local, .biometryLockout)
    let unknownLocal = BiometricPolicy.classifyError(
      domain: "local.authentication.domain", code: 99,
      localAuthenticationDomain: "local.authentication.domain"
    ) { _ in nil }
    XCTAssertEqual(unknownLocal, .other)
  }

  func testAvailabilityAuthenticationAndDetachedSchemasRemainSeparate() {
    let availability = BiometricPolicy.availabilityEnvelope(
      BiometricAvailability(state: .ready, code: "biometric.ready")
    )
    XCTAssertEqual(availability, ["state": "ready", "code": "biometric.ready"])
    XCTAssertEqual(Set(availability.keys), ["state", "code"])

    let invalidReason = BiometricPolicy.invalidReasonResponse(requestID: requestID)
    XCTAssertEqual(invalidReason, [
      "kind": "denied", "code": "biometric.invalid_reason", "requestId": requestID,
    ])
    XCTAssertEqual(
      BiometricPolicy.invalidAuthenticationResponse(requestID: requestID),
      ["kind": "invalid", "code": "biometric.invalid_request", "requestId": requestID]
    )
    XCTAssertEqual(
      BiometricPolicy.detachedResponse(method: "biometricAvailability", arguments: nil) as? [String: String],
      ["state": "unavailable", "code": "biometric.platform_unavailable"]
    )
    XCTAssertEqual(
      BiometricPolicy.detachedResponse(
        method: "authenticateBiometric", arguments: ["requestId": requestID]
      ) as? [String: String],
      ["kind": "cancelled", "code": "biometric.engine_detached", "requestId": requestID]
    )
  }
}
