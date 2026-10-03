import CoreLocation
import Flutter
import UIKit

/// UIKit/CoreLocation boundary. This file is excluded from macOS SwiftPM but included by the podspec.
final class IOSLocationAdapter: NSObject, CLLocationManagerDelegate {
  private let lifecycle = LocationOperationLifecycle()
  private var pending: PendingLocationOperation?
  private var detached = false

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in
        guard let self else {
          result(
            LocationPolicy.detachedResponse(method: call.method, arguments: call.arguments as? [String: Any])
              ?? FlutterMethodNotImplemented
          )
          return
        }
        self.handle(call, result: result)
      }
      return
    }
    guard !detached else {
      result(
        LocationPolicy.detachedResponse(method: call.method, arguments: call.arguments as? [String: Any])
          ?? FlutterMethodNotImplemented
      )
      return
    }
    switch call.method {
    case "locationPermissionStatus": permissionStatus(call.arguments, result: result)
    case "requestLocationPermission": requestPermission(call.arguments, result: result)
    case "locate": locate(call.arguments, result: result)
    case "cancelLocation": cancel(call.arguments, result: result)
    default: result(FlutterMethodNotImplemented)
    }
  }

  func detach() {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in self?.detach() }
      return
    }
    guard !detached else { return }
    detached = true
    let operation = pending
    _ = lifecycle.invalidate { [weak self, weak operation] _ in
      guard let self, let operation else { return }
      self.cleanup(operation)
    }
    if let operation {
      operation.result(terminalResponse(
        operation, kind: "cancelled", code: "location.engine_detached"
      ))
    }
  }

  @available(iOS 14.0, *)
  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    authorizationDidChange(manager)
  }

  func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
    authorizationDidChange(manager)
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let operation = activeOperation(for: manager) else { return }
    guard operation.token.kind == .location else { return }
    guard CLLocationManager.locationServicesEnabled() else {
      finish(operation, response: LocationPolicy.locationProviderError(disabled: true, requestID: operation.token.requestID))
      return
    }
    guard isForeground else {
      finish(operation, response: LocationPolicy.backgroundedResponse(kind: .location, requestID: operation.token.requestID))
      return
    }
    let authorization = currentAuthorization(manager)
    guard authorization == .granted else {
      finish(operation, response: LocationPolicy.locationAuthorizationError(authorization, requestID: operation.token.requestID))
      return
    }
    guard let sample = locations.last else {
      finish(operation, response: LocationPolicy.locationProviderError(disabled: false, requestID: operation.token.requestID))
      return
    }
    let assessment = LocationPolicy.assessSample(
      latitude: sample.coordinate.latitude,
      longitude: sample.coordinate.longitude,
      accuracyMeters: sample.horizontalAccuracy,
      timestamp: sample.timestamp,
      now: Date(),
      maxAgeMillis: operation.maxAgeMillis,
      approximate: isApproximate(manager),
      isForeground: isForeground
    )
    switch assessment {
    case .valid(let location): finish(operation, response: LocationPolicy.locationSuccess(location, requestID: operation.token.requestID))
    case .invalid(.foregroundRequired): finish(operation, response: LocationPolicy.backgroundedResponse(kind: .location, requestID: operation.token.requestID))
    case .invalid(let error): finish(operation, kind: "invalid", code: error.rawValue)
    }
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    guard let operation = activeOperation(for: manager) else { return }
    let failure = LocationPolicy.nativeFailure(
      reason: nativeErrorReason(error),
      servicesEnabled: CLLocationManager.locationServicesEnabled(),
      authorization: currentAuthorization(manager)
    )
    finish(operation, response: LocationPolicy.nativeFailureResponse(
      failure, operationKind: operation.token.kind, requestID: operation.token.requestID
    ))
  }

  private func permissionStatus(_ arguments: Any?, result: @escaping FlutterResult) {
    guard arguments == nil else {
      result(LocationPolicy.permissionEnvelope(
        kind: "invalid", code: "location.invalid_request", status: .unavailable, approximate: nil
      ))
      return
    }
    guard LocationPolicy.hasPurpose(purposeText) else {
      result(LocationPolicy.permissionStatusEnvelope(LocationPolicy.permissionSnapshot(
        authorization: .unavailable, servicesEnabled: true, purposeConfigured: false, approximate: false
      )))
      return
    }
    guard CLLocationManager.locationServicesEnabled() else {
      result(LocationPolicy.permissionStatusEnvelope(LocationPolicy.permissionSnapshot(
        authorization: .unavailable, servicesEnabled: false, purposeConfigured: true, approximate: false
      )))
      return
    }
    let manager = CLLocationManager()
    let snapshot = permissionSnapshot(manager)
    result(LocationPolicy.permissionStatusEnvelope(snapshot))
  }

  private func requestPermission(_ rawArguments: Any?, result: @escaping FlutterResult) {
    let arguments = rawArguments as? [String: Any]
    let requestID = LocationPolicy.echoedRequestID(arguments)
    guard let arguments, Set(arguments.keys).isSubset(of: ["requestId", "timeoutMillis"]),
      let suppliedID = arguments["requestId"] as? String,
      LocationPolicy.isValidRequestID(suppliedID)
    else {
      result(LocationPolicy.permissionError("invalid", "location.invalid_request", requestID: requestID))
      return
    }
    guard let timeout = LocationPolicy.timeoutMillis(
      arguments["timeoutMillis"], defaultValue: LocationPolicy.defaultPermissionTimeoutMillis
    ) else {
      result(LocationPolicy.permissionError("invalid", "location.invalid_limits", requestID: suppliedID))
      return
    }
    guard !lifecycle.hasPending else {
      result(LocationPolicy.permissionError("conflict", "location.operation_in_progress", requestID: suppliedID))
      return
    }
    guard isForeground else {
      result(LocationPolicy.permissionError("unavailable", "location.foreground_required", requestID: suppliedID))
      return
    }
    guard LocationPolicy.hasPurpose(purposeText) else {
      result(LocationPolicy.permissionError("unavailable", "location.permission_not_configured", requestID: suppliedID))
      return
    }
    guard CLLocationManager.locationServicesEnabled() else {
      result(LocationPolicy.permissionError("unavailable", "location.disabled", requestID: suppliedID))
      return
    }

    let manager = CLLocationManager()
    let snapshot = permissionSnapshot(manager)
    guard snapshot.status == .notDetermined,
      LocationPolicy.shouldRequestAuthorization(currentAuthorization(manager))
    else {
      result(LocationPolicy.permissionOperationEnvelope(snapshot, requestID: suppliedID))
      return
    }
    guard let operation = begin(
      requestID: suppliedID, kind: .permission, timeoutMillis: timeout, maxAgeMillis: nil,
      manager: manager, result: result
    ) else { return }

    manager.delegate = self
    issueAuthorizationRequestIfNeeded(operation)
  }

  private func locate(_ rawArguments: Any?, result: @escaping FlutterResult) {
    let arguments = rawArguments as? [String: Any]
    let echoedID = LocationPolicy.echoedRequestID(arguments)
    guard let arguments, Set(arguments.keys).isSubset(of: ["requestId", "timeoutMillis", "maxAgeMillis"]),
      let suppliedID = arguments["requestId"] as? String,
      LocationPolicy.isValidRequestID(suppliedID)
    else {
      result(LocationPolicy.locationError("invalid", "location.invalid_request", requestID: echoedID))
      return
    }
    guard let timeout = LocationPolicy.timeoutMillis(
      arguments["timeoutMillis"], defaultValue: LocationPolicy.defaultLocationTimeoutMillis
    ), let maxAge = LocationPolicy.parseMaximumAgeMillis(arguments["maxAgeMillis"]) else {
      result(LocationPolicy.locationError("invalid", "location.invalid_limits", requestID: suppliedID))
      return
    }
    guard !lifecycle.hasPending else {
      result(LocationPolicy.locationError("conflict", "location.operation_in_progress", requestID: suppliedID))
      return
    }
    guard isForeground else {
      result(LocationPolicy.locationError("unavailable", "location.foreground_required", requestID: suppliedID))
      return
    }
    guard LocationPolicy.hasPurpose(purposeText) else {
      result(LocationPolicy.locationError("unavailable", "location.permission_not_configured", requestID: suppliedID))
      return
    }
    guard CLLocationManager.locationServicesEnabled() else {
      result(LocationPolicy.locationProviderError(disabled: true, requestID: suppliedID))
      return
    }

    let manager = CLLocationManager()
    let authorization = currentAuthorization(manager)
    guard authorization == .granted else {
      result(LocationPolicy.locationAuthorizationError(authorization, requestID: suppliedID))
      return
    }
    guard let operation = begin(
      requestID: suppliedID, kind: .location, timeoutMillis: timeout, maxAgeMillis: maxAge,
      manager: manager, result: result
    ) else { return }

    manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    manager.delegate = self
    guard pending === operation, lifecycle.isCurrent(operation.token) else { return }
    guard isForeground else {
      finish(operation, response: LocationPolicy.backgroundedResponse(kind: .location, requestID: operation.token.requestID))
      return
    }
    guard currentAuthorization(manager) == .granted else {
      finishForCurrentAuthorization(operation, manager: manager, locating: true)
      return
    }
    manager.requestLocation()
  }

  private func cancel(_ rawArguments: Any?, result: @escaping FlutterResult) {
    guard let arguments = rawArguments as? [String: Any],
      Set(arguments.keys) == ["requestId"],
      let requestID = arguments["requestId"] as? String,
      LocationPolicy.isValidRequestID(requestID),
      let operation = pending,
      operation.token.requestID == requestID
    else {
      result(false)
      return
    }
    if ProcessInfo.processInfo.systemUptime >= operation.token.deadline {
      expire(operation)
      result(false)
      return
    }
    guard let cancelled = lifecycle.cancel(requestID: requestID, onTerminal: { [weak self, weak operation] _ in
      guard let self, let operation else { return }
      self.cleanup(operation)
    }), cancelled == operation.token else {
      result(false)
      return
    }
    operation.result(terminalResponse(operation, kind: "cancelled", code: "location.cancelled"))
    result(true)
  }

  private func begin(
    requestID: String,
    kind: LocationOperationKind,
    timeoutMillis: Int,
    maxAgeMillis: Int?,
    manager: CLLocationManager,
    result: @escaping FlutterResult
  ) -> PendingLocationOperation? {
    let start = lifecycle.begin(
      requestID: requestID, kind: kind, timeoutMillis: timeoutMillis,
      now: ProcessInfo.processInfo.systemUptime
    )
    let token: LocationOperation
    switch start {
    case .started(let operation): token = operation
    case .conflict:
      result(startError(kind, "conflict", "location.operation_in_progress", requestID))
      return nil
    case .exhausted:
      result(startError(kind, "failure", "location.request_codes_exhausted", requestID))
      return nil
    case .invalidated:
      result(startError(kind, "cancelled", "location.engine_detached", requestID))
      return nil
    }
    let operation = PendingLocationOperation(
      token: token, manager: manager, maxAgeMillis: maxAgeMillis ?? 0, result: result
    )
    pending = operation
    installBackgroundObservers(for: operation)
    scheduleTimeout(for: operation, timeoutMillis: timeoutMillis)
    return operation
  }

  private func installBackgroundObservers(for operation: PendingLocationOperation) {
    let center = NotificationCenter.default
    for name in [UIApplication.didEnterBackgroundNotification, UIScene.didEnterBackgroundNotification] {
      let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self, weak operation] _ in
        guard let self, let operation, self.activeOperation(for: operation.manager) === operation else { return }
        self.finish(operation, kind: "cancelled", code: "location.backgrounded")
      }
      operation.observers.append(observer)
    }
  }

  private func scheduleTimeout(for operation: PendingLocationOperation, timeoutMillis: Int) {
    let work = DispatchWorkItem { [weak self, weak operation] in
      guard let self, let operation else { return }
      let expired = self.lifecycle.expire(
        operation.token,
        at: ProcessInfo.processInfo.systemUptime,
        onTerminal: { [weak self] in self?.cleanup(operation) }
      )
      if expired {
        operation.result(self.terminalResponse(operation, kind: "timeout", code: "location.timeout"))
      }
    }
    operation.timeoutWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(timeoutMillis), execute: work)
  }

  private func authorizationDidChange(_ manager: CLLocationManager) {
    guard let operation = activeOperation(for: manager) else { return }
    guard CLLocationManager.locationServicesEnabled() else {
      let code = operation.token.kind == .location ? "location.provider_disabled" : "location.disabled"
      finish(operation, kind: "unavailable", code: code)
      return
    }
    if operation.token.kind == .permission {
      let authorization = currentAuthorization(manager)
      if authorization == .notDetermined {
        issueAuthorizationRequestIfNeeded(operation)
      } else {
        finishForCurrentAuthorization(operation, manager: manager, locating: false)
      }
    } else {
      finishForCurrentAuthorization(operation, manager: manager, locating: true)
    }
  }

  private func issueAuthorizationRequestIfNeeded(_ operation: PendingLocationOperation) {
    guard activeOperation(for: operation.manager) === operation,
      !operation.authorizationRequestIssued
    else { return }
    let authorization = currentAuthorization(operation.manager)
    guard LocationPolicy.shouldRequestAuthorization(authorization) else {
      finishForCurrentAuthorization(operation, manager: operation.manager, locating: false)
      return
    }
    operation.authorizationRequestIssued = true
    operation.manager.requestWhenInUseAuthorization()
  }

  private func finishForCurrentAuthorization(
    _ operation: PendingLocationOperation, manager: CLLocationManager, locating: Bool
  ) {
    let snapshot = permissionSnapshot(manager)
    if locating {
      switch snapshot.status {
      case .granted: return
      case .denied:
        finish(operation, kind: "denied", code: "location.denied")
      case .restricted:
        finish(operation, kind: "restricted", code: "location.restricted")
      case .notDetermined:
        finish(operation, kind: "unavailable", code: "location.permission_required")
      case .unavailable:
        finish(operation, kind: "unavailable", code: snapshot.code)
      }
    } else {
      finish(operation, response: LocationPolicy.permissionOperationEnvelope(snapshot, requestID: operation.token.requestID))
    }
  }

  private func activeOperation(for manager: CLLocationManager) -> PendingLocationOperation? {
    guard let operation = pending, operation.manager === manager,
      lifecycle.isCurrent(operation.token)
    else { return nil }
    if ProcessInfo.processInfo.systemUptime >= operation.token.deadline {
      expire(operation)
      return nil
    }
    return operation
  }

  private func expire(_ operation: PendingLocationOperation) {
    let expired = lifecycle.expire(
      operation.token,
      at: ProcessInfo.processInfo.systemUptime,
      onTerminal: { [weak self] in self?.cleanup(operation) }
    )
    if expired {
      operation.result(terminalResponse(operation, kind: "timeout", code: "location.timeout"))
    }
  }

  private func finish(
    _ operation: PendingLocationOperation, kind: String, code: String
  ) {
    finish(operation, response: terminalResponse(operation, kind: kind, code: code))
  }

  private func finish(_ operation: PendingLocationOperation, response: [String: Any]) {
    let state = lifecycle.settle(
      operation.token,
      at: ProcessInfo.processInfo.systemUptime,
      onTerminal: { [weak self] in self?.cleanup(operation) }
    )
    switch state {
    case .settled: operation.result(response)
    case .expired: operation.result(terminalResponse(operation, kind: "timeout", code: "location.timeout"))
    case .stale: break
    }
  }

  private func cleanup(_ operation: PendingLocationOperation) {
    if pending === operation { pending = nil }
    operation.timeoutWork?.cancel()
    operation.timeoutWork = nil
    let center = NotificationCenter.default
    for observer in operation.observers { center.removeObserver(observer) }
    operation.observers.removeAll()
    operation.manager.stopUpdatingLocation()
    operation.manager.delegate = nil
  }

  private func terminalResponse(
    _ operation: PendingLocationOperation, kind: String, code: String
  ) -> [String: Any] {
    switch operation.token.kind {
    case .permission:
      return LocationPolicy.permissionError(kind, code, requestID: operation.token.requestID)
    case .location:
      return LocationPolicy.locationError(kind, code, requestID: operation.token.requestID)
    }
  }

  private func startError(
    _ kind: LocationOperationKind, _ responseKind: String, _ code: String, _ requestID: String
  ) -> [String: Any] {
    switch kind {
    case .permission:
      return LocationPolicy.permissionError(responseKind, code, requestID: requestID)
    case .location:
      return LocationPolicy.locationError(responseKind, code, requestID: requestID)
    }
  }

  private func permissionSnapshot(_ manager: CLLocationManager) -> LocationPermissionSnapshot {
    LocationPolicy.permissionSnapshot(
      authorization: currentAuthorization(manager),
      servicesEnabled: CLLocationManager.locationServicesEnabled(),
      purposeConfigured: LocationPolicy.hasPurpose(purposeText),
      approximate: isApproximate(manager)
    )
  }

  private func currentAuthorization(_ manager: CLLocationManager) -> LocationAuthorization {
    let status: CLAuthorizationStatus
    if #available(iOS 14.0, *) {
      status = manager.authorizationStatus
    } else {
      status = CLLocationManager.authorizationStatus()
    }
    switch status {
    case .notDetermined: return .notDetermined
    case .authorizedAlways, .authorizedWhenInUse: return .granted
    case .denied: return .denied
    case .restricted: return .restricted
    @unknown default: return .unavailable
    }
  }

  private func nativeErrorReason(_ error: Error) -> LocationNativeErrorReason {
    let nativeError = error as NSError
    guard nativeError.domain == kCLErrorDomain else { return .other }
    switch nativeError.code {
    case CLError.Code.locationUnknown.rawValue: return .locationUnknown
    case CLError.Code.denied.rawValue: return .denied
    default: return .other
    }
  }

  private func isApproximate(_ manager: CLLocationManager) -> Bool {
    if #available(iOS 14.0, *) { return manager.accuracyAuthorization == .reducedAccuracy }
    return false
  }

  private var purposeText: String? {
    Bundle.main.object(forInfoDictionaryKey: LocationPolicy.debugPurposeKey) as? String
  }

  private var isForeground: Bool {
    guard UIApplication.shared.applicationState == .active else { return false }
    let scenes = UIApplication.shared.connectedScenes
    return scenes.isEmpty || scenes.contains { $0.activationState == .foregroundActive }
  }
}

private final class PendingLocationOperation {
  let token: LocationOperation
  let manager: CLLocationManager
  let maxAgeMillis: Int
  let result: FlutterResult
  var authorizationRequestIssued = false
  var timeoutWork: DispatchWorkItem?
  var observers = [NSObjectProtocol]()

  init(
    token: LocationOperation, manager: CLLocationManager, maxAgeMillis: Int, result: @escaping FlutterResult
  ) {
    self.token = token
    self.manager = manager
    self.maxAgeMillis = maxAgeMillis
    self.result = result
  }
}
