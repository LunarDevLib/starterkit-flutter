import Foundation
import XCTest
@testable import StarterkitPlatformPolicy

final class LocationPolicyTests: XCTestCase {
  private let requestID = "0123456789abcdef0123456789abcdef"

  func testRequestIDRequiresExactly32LowercaseHexCharacters() {
    XCTAssertTrue(LocationPolicy.isValidRequestID(requestID))
    XCTAssertFalse(LocationPolicy.isValidRequestID("0123456789abcdef0123456789abcde"))
    XCTAssertFalse(LocationPolicy.isValidRequestID(requestID + "0"))
    XCTAssertFalse(LocationPolicy.isValidRequestID("0123456789ABCDEF0123456789ABCDEF"))
    XCTAssertFalse(LocationPolicy.isValidRequestID(String(repeating: "g", count: 32)))
  }

  func testTimeoutAndAgeLimitsRejectBooleanFloatingAndOutOfRangeValues() {
    XCTAssertEqual(
      LocationPolicy.timeoutMillis(nil, defaultValue: LocationPolicy.defaultPermissionTimeoutMillis), 60_000
    )
    XCTAssertEqual(LocationPolicy.timeoutMillis(1, defaultValue: 15_000), 1)
    XCTAssertEqual(LocationPolicy.timeoutMillis(60_000, defaultValue: 15_000), 60_000)
    XCTAssertNil(LocationPolicy.timeoutMillis(0, defaultValue: 15_000))
    XCTAssertNil(LocationPolicy.timeoutMillis(60_001, defaultValue: 15_000))
    XCTAssertNil(LocationPolicy.timeoutMillis(NSNumber(value: true), defaultValue: 15_000))
    XCTAssertNil(LocationPolicy.timeoutMillis(NSNumber(value: 1.5), defaultValue: 15_000))

    XCTAssertEqual(LocationPolicy.parseMaximumAgeMillis(nil), 5_000)
    XCTAssertEqual(LocationPolicy.parseMaximumAgeMillis(1), 1)
    XCTAssertEqual(LocationPolicy.parseMaximumAgeMillis(60_000), 60_000)
    XCTAssertNil(LocationPolicy.parseMaximumAgeMillis(0))
    XCTAssertNil(LocationPolicy.parseMaximumAgeMillis(60_001))
    XCTAssertNil(LocationPolicy.parseMaximumAgeMillis(NSNumber(value: false)))
    XCTAssertNil(LocationPolicy.parseMaximumAgeMillis(NSNumber(value: 5.0)))
  }

  func testPurposeConfigurationRequiresNonemptyTrimmedString() {
    XCTAssertTrue(LocationPolicy.hasPurpose("Use location while the app is open."))
    XCTAssertFalse(LocationPolicy.hasPurpose(nil))
    XCTAssertFalse(LocationPolicy.hasPurpose(" \n\t "))
  }

  func testPermissionStatusAndRequestEnvelopesDistinguishInformationalDenial() {
    let cases: [(LocationAuthorization, LocationPermissionStatus, String, String)] = [
      (.notDetermined, .notDetermined, "success", "location.permission_status"),
      (.granted, .granted, "success", "location.permission_status"),
      (.denied, .denied, "success", "location.permission_status"),
      (.restricted, .restricted, "success", "location.permission_status"),
    ]
    for (authorization, status, kind, code) in cases {
      let snapshot = LocationPolicy.permissionSnapshot(
        authorization: authorization, servicesEnabled: true, purposeConfigured: true,
        approximate: authorization == .granted
      )
      let response = LocationPolicy.permissionStatusEnvelope(snapshot)
      XCTAssertEqual(response["kind"] as? String, kind)
      XCTAssertEqual(response["code"] as? String, code)
      XCTAssertEqual(response["status"] as? String, status.rawValue)
      XCTAssertEqual(Set(response.keys), ["kind", "code", "status", "approximate"])
      if status == .denied || status == .restricted {
        XCTAssertEqual(response["approximate"] as? NSNull, NSNull())
      }
    }

    let denied = LocationPolicy.permissionSnapshot(
      authorization: .denied, servicesEnabled: true, purposeConfigured: true, approximate: false
    )
    let deniedRequest = LocationPolicy.permissionOperationEnvelope(denied, requestID: requestID)
    XCTAssertEqual(deniedRequest["kind"] as? String, "denied")
    XCTAssertEqual(deniedRequest["code"] as? String, "location.denied")
    XCTAssertEqual(deniedRequest["status"] as? String, "denied")
    XCTAssertEqual(deniedRequest["approximate"] as? NSNull, NSNull())
    XCTAssertEqual(deniedRequest["requestId"] as? String, requestID)
    XCTAssertEqual(Set(deniedRequest.keys), ["kind", "code", "status", "approximate", "requestId"])

    let restricted = LocationPolicy.permissionSnapshot(
      authorization: .restricted, servicesEnabled: true, purposeConfigured: true, approximate: false
    )
    let restrictedRequest = LocationPolicy.permissionOperationEnvelope(restricted, requestID: requestID)
    XCTAssertEqual(restrictedRequest["kind"] as? String, "restricted")
    XCTAssertEqual(restrictedRequest["code"] as? String, "location.restricted")
    XCTAssertEqual(restrictedRequest["status"] as? String, "restricted")
    XCTAssertEqual(restrictedRequest["approximate"] as? NSNull, NSNull())
    XCTAssertEqual(restrictedRequest["requestId"] as? String, requestID)
    XCTAssertEqual(Set(restrictedRequest.keys), ["kind", "code", "status", "approximate", "requestId"])
  }

  func testUnavailablePermissionRequiresConfiguredPurposeAndEnabledServices() {
    let missingPurpose = LocationPolicy.permissionSnapshot(
      authorization: .granted, servicesEnabled: true, purposeConfigured: false, approximate: true
    )
    XCTAssertEqual(missingPurpose.status, .unavailable)
    XCTAssertEqual(missingPurpose.code, "location.permission_not_configured")
    XCTAssertNil(missingPurpose.approximate)

    let disabled = LocationPolicy.permissionSnapshot(
      authorization: .granted, servicesEnabled: false, purposeConfigured: true, approximate: true
    )
    XCTAssertEqual(disabled.status, .unavailable)
    XCTAssertEqual(disabled.code, "location.disabled")
    XCTAssertNil(disabled.approximate)
    XCTAssertEqual(LocationPolicy.permissionStatusEnvelope(disabled)["kind"] as? String, "unavailable")
  }

  func testPermissionPromptIsRequestedOnlyWhileAuthorizationIsUndetermined() {
    XCTAssertTrue(LocationPolicy.shouldRequestAuthorization(.notDetermined))
    XCTAssertFalse(LocationPolicy.shouldRequestAuthorization(.granted))
    XCTAssertFalse(LocationPolicy.shouldRequestAuthorization(.denied))
    XCTAssertFalse(LocationPolicy.shouldRequestAuthorization(.restricted))
    XCTAssertFalse(LocationPolicy.shouldRequestAuthorization(.unavailable))
  }

  func testUndeterminedPermissionRequestNeverReportsQueryStatusAsCompletedGrant() {
    let snapshot = LocationPolicy.permissionSnapshot(
      authorization: .notDetermined,
      servicesEnabled: true,
      purposeConfigured: true,
      approximate: false
    )
    let informationalStatus = LocationPolicy.permissionStatusEnvelope(snapshot)
    XCTAssertEqual(informationalStatus["kind"] as? String, "success")
    XCTAssertEqual(informationalStatus["code"] as? String, "location.permission_status")
    XCTAssertEqual(informationalStatus["status"] as? String, "notDetermined")

    let requestResult = LocationPolicy.permissionOperationEnvelope(snapshot, requestID: requestID)
    XCTAssertEqual(Set(requestResult.keys), ["kind", "code", "status", "approximate", "requestId"])
    XCTAssertEqual(requestResult["kind"] as? String, "unavailable")
    XCTAssertEqual(requestResult["code"] as? String, "location.permission_required")
    XCTAssertEqual(requestResult["status"] as? String, "unavailable")
    XCTAssertEqual(requestResult["approximate"] as? NSNull, NSNull())
    XCTAssertEqual(requestResult["requestId"] as? String, requestID)
  }

  func testApproximateAuthorizationAndLocationSuccessSchemaArePreserved() {
    let approximate = LocationPolicy.permissionSnapshot(
      authorization: .granted, servicesEnabled: true, purposeConfigured: true, approximate: true
    )
    XCTAssertEqual(approximate.approximate, true)
    let exact = LocationPolicy.permissionSnapshot(
      authorization: .granted, servicesEnabled: true, purposeConfigured: true, approximate: false
    )
    XCTAssertEqual(exact.approximate, false)

    let sample = ForegroundLocation(
      latitude: 1.25, longitude: -2.5, accuracyMeters: 100, approximate: true, ageMillis: 30
    )
    let response = LocationPolicy.locationSuccess(sample, requestID: requestID)
    XCTAssertEqual(Set(response.keys), ["kind", "code", "requestId", "location"])
    XCTAssertEqual(response["kind"] as? String, "success")
    XCTAssertEqual(response["code"] as? String, "location.success")
    XCTAssertEqual(response["requestId"] as? String, requestID)
    let payload = response["location"] as? [String: Any]
    XCTAssertNotNil(payload)
    XCTAssertEqual(Set(payload!.keys), ["latitude", "longitude", "accuracyMeters", "approximate", "ageMillis"])
    XCTAssertEqual(payload?["approximate"] as? Bool, true)
    XCTAssertEqual(payload?["ageMillis"] as? Int, 30)
  }

  func testAuthorizationDenialAndProviderFailureUseContractCodes() {
    let denied = LocationPolicy.locationAuthorizationError(.denied, requestID: requestID)
    XCTAssertEqual(denied["kind"] as? String, "denied")
    XCTAssertEqual(denied["code"] as? String, "location.denied")
    XCTAssertEqual(denied["requestId"] as? String, requestID)
    let restricted = LocationPolicy.locationAuthorizationError(.restricted, requestID: requestID)
    XCTAssertEqual(restricted["kind"] as? String, "restricted")
    XCTAssertEqual(restricted["code"] as? String, "location.restricted")
    XCTAssertEqual(
      LocationPolicy.locationProviderError(disabled: true, requestID: requestID)["code"] as? String,
      "location.provider_disabled"
    )
    XCTAssertEqual(
      LocationPolicy.locationProviderError(disabled: false, requestID: requestID)["code"] as? String,
      "location.provider_unavailable"
    )
    let defensiveGranted = LocationPolicy.locationAuthorizationError(.granted, requestID: requestID)
    XCTAssertEqual(defensiveGranted["kind"] as? String, "failure")
    XCTAssertEqual(defensiveGranted["code"] as? String, "location.platform_failure")
  }

  func testNativeErrorClassificationKeepsProviderPermissionAndFailureOutcomesDistinct() {
    XCTAssertEqual(
      LocationPolicy.nativeFailure(
        reason: .other, servicesEnabled: false, authorization: .granted
      ), .providerDisabled
    )
    let locationServicesDisabled = LocationPolicy.nativeFailureResponse(
      .providerDisabled, operationKind: .location, requestID: requestID
    )
    XCTAssertEqual(locationServicesDisabled["kind"] as? String, "unavailable")
    XCTAssertEqual(locationServicesDisabled["code"] as? String, "location.provider_disabled")
    let permissionServicesDisabled = LocationPolicy.nativeFailureResponse(
      .providerDisabled, operationKind: .permission, requestID: requestID
    )
    XCTAssertEqual(permissionServicesDisabled["kind"] as? String, "unavailable")
    XCTAssertEqual(permissionServicesDisabled["code"] as? String, "location.disabled")
    XCTAssertEqual(
      LocationPolicy.nativeFailure(
        reason: .other, servicesEnabled: true, authorization: .denied
      ), .denied
    )
    XCTAssertEqual(
      LocationPolicy.nativeFailure(
        reason: .other, servicesEnabled: true, authorization: .restricted
      ), .restricted
    )
    XCTAssertEqual(
      LocationPolicy.nativeFailure(
        reason: .locationUnknown, servicesEnabled: true, authorization: .granted
      ), .providerUnavailable
    )
    XCTAssertEqual(
      LocationPolicy.nativeFailure(
        reason: .denied, servicesEnabled: true, authorization: .granted
      ), .denied
    )
    XCTAssertEqual(
      LocationPolicy.nativeFailure(
        reason: .other, servicesEnabled: true, authorization: .granted
      ), .platformFailure
    )

    let permissionDenied = LocationPolicy.nativeFailureResponse(
      .denied, operationKind: .permission, requestID: requestID
    )
    XCTAssertEqual(permissionDenied["kind"] as? String, "denied")
    XCTAssertEqual(permissionDenied["code"] as? String, "location.denied")
    XCTAssertEqual(permissionDenied["status"] as? String, "denied")
    XCTAssertEqual(permissionDenied["approximate"] as? NSNull, NSNull())
    XCTAssertEqual(permissionDenied["requestId"] as? String, requestID)

    let permissionRestricted = LocationPolicy.nativeFailureResponse(
      .restricted, operationKind: .permission, requestID: requestID
    )
    XCTAssertEqual(permissionRestricted["kind"] as? String, "restricted")
    XCTAssertEqual(permissionRestricted["code"] as? String, "location.restricted")
    XCTAssertEqual(permissionRestricted["status"] as? String, "restricted")
    XCTAssertEqual(permissionRestricted["approximate"] as? NSNull, NSNull())
    XCTAssertEqual(permissionRestricted["requestId"] as? String, requestID)

    let unavailableProvider = LocationPolicy.nativeFailureResponse(
      .providerUnavailable, operationKind: .location, requestID: requestID
    )
    XCTAssertEqual(unavailableProvider["kind"] as? String, "unavailable")
    XCTAssertEqual(unavailableProvider["code"] as? String, "location.provider_unavailable")
    let platformFailure = LocationPolicy.nativeFailureResponse(
      .platformFailure, operationKind: .location, requestID: requestID
    )
    XCTAssertEqual(platformFailure["kind"] as? String, "failure")
    XCTAssertEqual(platformFailure["code"] as? String, "location.platform_failure")
    let permissionFailure = LocationPolicy.nativeFailureResponse(
      .platformFailure, operationKind: .permission, requestID: requestID
    )
    XCTAssertEqual(permissionFailure["kind"] as? String, "failure")
    XCTAssertEqual(permissionFailure["code"] as? String, "location.platform_failure")
  }

  func testDetachedStatusUsesInformationalUnavailableSchema() {
    let response = LocationPolicy.detachedResponse(method: "locationPermissionStatus", arguments: nil)
    let envelope = response as? [String: Any]
    XCTAssertNotNil(envelope)
    XCTAssertEqual(Set(envelope!.keys), ["kind", "code", "status", "approximate"])
    XCTAssertEqual(envelope?["kind"] as? String, "unavailable")
    XCTAssertEqual(envelope?["code"] as? String, "location.platform_unavailable")
    XCTAssertEqual(envelope?["status"] as? String, "unavailable")
    XCTAssertEqual(envelope?["approximate"] as? NSNull, NSNull())
    XCTAssertNil(envelope?["requestId"])
  }

  func testSampleAcceptsBoundariesAndClampsOnlyAllowedFutureTolerance() {
    let now = Date(timeIntervalSince1970: 10_000)
    let boundary = LocationPolicy.assessSample(
      latitude: -90, longitude: 180, accuracyMeters: 0,
      timestamp: Date(timeIntervalSince1970: 9_995), now: now, maxAgeMillis: 5_000,
      approximate: true, isForeground: true
    )
    XCTAssertEqual(
      boundary,
      .valid(ForegroundLocation(
        latitude: -90, longitude: 180, accuracyMeters: 0, approximate: true, ageMillis: 5_000
      ))
    )

    let toleratedFuture = LocationPolicy.assessSample(
      latitude: 90, longitude: -180, accuracyMeters: 1,
      timestamp: Date(timeIntervalSince1970: 10_001), now: now, maxAgeMillis: 5_000,
      approximate: false, isForeground: true
    )
    XCTAssertEqual(
      toleratedFuture,
      .valid(ForegroundLocation(
        latitude: 90, longitude: -180, accuracyMeters: 1, approximate: false, ageMillis: 0
      ))
    )

    let overTolerance = LocationPolicy.assessSample(
      latitude: 0, longitude: 0, accuracyMeters: 1,
      timestamp: Date(timeIntervalSince1970: 10_001.001), now: now, maxAgeMillis: 5_000,
      approximate: false, isForeground: true
    )
    XCTAssertEqual(overTolerance, .invalid(.invalidTime))
  }

  func testSampleRejectsCoordinatesAccuracyStalenessAndBadTime() {
    let now = Date(timeIntervalSince1970: 1_000)
    func assess(
      latitude: Double = 0, longitude: Double = 0, accuracy: Double = 1,
      timestamp: Date = Date(timeIntervalSince1970: 1_000), maxAge: Int = 5_000,
      foreground: Bool = true
    ) -> LocationSampleAssessment {
      LocationPolicy.assessSample(
        latitude: latitude, longitude: longitude, accuracyMeters: accuracy,
        timestamp: timestamp, now: now, maxAgeMillis: maxAge,
        approximate: false, isForeground: foreground
      )
    }
    XCTAssertEqual(assess(latitude: .nan), .invalid(.invalidCoordinate))
    XCTAssertEqual(assess(longitude: .infinity), .invalid(.invalidCoordinate))
    XCTAssertEqual(assess(latitude: 90.0001), .invalid(.invalidCoordinate))
    XCTAssertEqual(assess(longitude: -180.0001), .invalid(.invalidCoordinate))
    XCTAssertEqual(assess(accuracy: -0.1), .invalid(.invalidAccuracy))
    XCTAssertEqual(assess(accuracy: .infinity), .invalid(.invalidAccuracy))
    XCTAssertEqual(assess(accuracy: .nan), .invalid(.invalidAccuracy))
    XCTAssertEqual(
      assess(timestamp: Date(timeIntervalSince1970: 994.999)), .invalid(.stale)
    )
    XCTAssertEqual(
      assess(timestamp: Date(timeIntervalSince1970: .infinity)), .invalid(.invalidTime)
    )
    XCTAssertEqual(assess(maxAge: 0), .invalid(.invalidLimits))
    XCTAssertEqual(assess(maxAge: 60_001), .invalid(.invalidLimits))
    XCTAssertEqual(assess(foreground: false), .invalid(.foregroundRequired))
  }

  func testTerminalResponsesEchoOperationIDsAndBackgroundIsCancellation() {
    let permission = LocationPolicy.permissionError(
      "timeout", "location.timeout", requestID: requestID
    )
    XCTAssertEqual(Set(permission.keys), ["kind", "code", "status", "approximate", "requestId"])
    XCTAssertEqual(permission["requestId"] as? String, requestID)
    XCTAssertEqual(permission["status"] as? String, "unavailable")
    XCTAssertEqual(permission["approximate"] as? NSNull, NSNull())

    let background = LocationPolicy.backgroundedResponse(kind: .location, requestID: requestID)
    XCTAssertEqual(Set(background.keys), ["kind", "code", "requestId"])
    XCTAssertEqual(background["kind"] as? String, "cancelled")
    XCTAssertEqual(background["code"] as? String, "location.backgrounded")
    XCTAssertEqual(background["requestId"] as? String, requestID)
  }
}
