import Flutter
import LocalAuthentication
import UIKit

/// UIKit/LocalAuthentication boundary. Excluded from macOS SwiftPM; included by CocoaPods.
final class IOSBiometricAdapter: NSObject {
  private let lifecycle = BiometricOperationLifecycle()
  private var pending: PendingBiometricOperation?
  private var detached = false

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in
        guard let self else {
          result(
            BiometricPolicy.detachedResponse(
              method: call.method, arguments: call.arguments as? [String: Any]
            ) ?? FlutterMethodNotImplemented
          )
          return
        }
        self.handle(call, result: result)
      }
      return
    }
    guard !detached else {
      result(
        BiometricPolicy.detachedResponse(
          method: call.method, arguments: call.arguments as? [String: Any]
        ) ?? FlutterMethodNotImplemented
      )
      return
    }
    switch call.method {
    case "biometricAvailability": availability(call.arguments, result: result)
    case "authenticateBiometric": authenticate(call.arguments, result: result)
    case "cancelBiometric": cancel(call.arguments, result: result)
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
    let invalidated = lifecycle.invalidate { [weak self] token in
      guard let self, let operation, operation.token == token else { return }
      self.cleanup(operation)
    }
    guard let invalidated, let operation, operation.token == invalidated else { return }
    operation.result(
      BiometricPolicy.authenticationEnvelope(
        BiometricOutcome(kind: .cancelled, code: "biometric.engine_detached"),
        requestID: operation.token.requestID
      )
    )
  }

  private func availability(_ rawArguments: Any?, result: @escaping FlutterResult) {
    guard rawArguments == nil else {
      result(BiometricPolicy.availabilityEnvelope(
        BiometricAvailability(state: .unavailable, code: "biometric.invalid_request")
      ))
      return
    }

    let context = LAContext()
    let lease = BiometricContextLease { context.invalidate() }
    defer { lease.invalidate() }

    var nativeError: NSError?
    let canEvaluate = context.canEvaluatePolicy(
      .deviceOwnerAuthenticationWithBiometrics, error: &nativeError
    )
    // LocalAuthentication updates biometryType during the check, including failure.
    let type = Self.biometryType(context.biometryType)
    let availability = BiometricPolicy.availability(
      canEvaluate: canEvaluate,
      error: Self.failureReason(nativeError),
      biometryType: type,
      faceIDPurposeConfigured: hasFaceIDPurpose
    )
    result(BiometricPolicy.availabilityEnvelope(availability))
  }

  private func authenticate(_ rawArguments: Any?, result: @escaping FlutterResult) {
    let arguments = rawArguments as? [String: Any]
    switch BiometricPolicy.validateAuthenticationArguments(arguments) {
    case .invalidRequest(let requestID):
      result(BiometricPolicy.invalidAuthenticationResponse(requestID: requestID))
      return
    case .invalidReason(let requestID):
      result(BiometricPolicy.invalidReasonResponse(requestID: requestID))
      return
    case .valid(let request):
      startAuthentication(request, result: result)
    }
  }

  private func startAuthentication(
    _ request: BiometricRequest, result: @escaping FlutterResult
  ) {
    guard !lifecycle.hasPending else {
      result(BiometricPolicy.conflictResponse(requestID: request.requestID))
      return
    }
    if let foregroundFailure = BiometricPolicy.startFailure(in: foregroundState) {
      result(BiometricPolicy.authenticationEnvelope(foregroundFailure, requestID: request.requestID))
      return
    }

    let context = LAContext()
    let lease = BiometricContextLease { context.invalidate() }
    var nativeError: NSError?
    let canEvaluate = context.canEvaluatePolicy(
      .deviceOwnerAuthenticationWithBiometrics, error: &nativeError
    )
    let type = Self.biometryType(context.biometryType)
    let failureReason = Self.failureReason(nativeError)
    if let preflight = BiometricPolicy.authenticationPreflightFailure(
      canEvaluate: canEvaluate,
      error: failureReason,
      biometryType: type,
      faceIDPurposeConfigured: hasFaceIDPurpose
    ) {
      lease.invalidate()
      result(BiometricPolicy.authenticationEnvelope(preflight, requestID: request.requestID))
      return
    }

    let token: BiometricOperationToken
    switch lifecycle.begin(requestID: request.requestID) {
    case .started(let started): token = started
    case .conflict:
      lease.invalidate()
      result(BiometricPolicy.conflictResponse(requestID: request.requestID))
      return
    case .exhausted, .invalidated:
      lease.invalidate()
      result(BiometricPolicy.authenticationEnvelope(
        BiometricOutcome(kind: .failure, code: "biometric.platform_failure"),
        requestID: request.requestID
      ))
      return
    }

    let operation = PendingBiometricOperation(
      token: token, context: context, contextLease: lease, result: result
    )
    pending = operation
    installBackgroundObservers(for: operation)

    guard pending === operation, lifecycle.isCurrent(token) else {
      cleanup(operation)
      return
    }
    if let foregroundFailure = BiometricPolicy.promptStartFailure(in: foregroundState) {
      finish(operation, BiometricPolicy.authenticationEnvelope(
        foregroundFailure, requestID: request.requestID
      ))
      return
    }

    // Install the pending identity and observers before evaluatePolicy: its completion may
    // arrive immediately, and no policy check is made from inside this reply.
    context.evaluatePolicy(
      .deviceOwnerAuthenticationWithBiometrics,
      localizedReason: request.reason
    ) { [weak self, weak operation] success, error in
      let reason = Self.failureReason(error)
      DispatchQueue.main.async { [weak self, weak operation] in
        guard let self, let operation,
          self.pending === operation,
          self.lifecycle.isCurrent(operation.token)
        else { return }
        let response = BiometricPolicy.authenticationOutcome(
          success: success,
          error: reason,
          foreground: self.foregroundState,
          requestID: operation.token.requestID
        )
        self.finish(operation, response)
      }
    }
  }

  private func cancel(_ rawArguments: Any?, result: @escaping FlutterResult) {
    guard let arguments = rawArguments as? [String: Any],
      Set(arguments.keys) == ["requestId"],
      let requestID = arguments["requestId"] as? String,
      BiometricPolicy.isValidRequestID(requestID),
      let operation = pending,
      operation.token.requestID == requestID
    else {
      result(false)
      return
    }

    guard let cancelled = lifecycle.cancel(requestID: requestID, cleanup: { [weak self, weak operation] token in
      guard let self, let operation, operation.token == token else { return }
      self.cleanup(operation)
    }), cancelled == operation.token else {
      result(false)
      return
    }
    operation.result(BiometricPolicy.authenticationEnvelope(
      BiometricOutcome(kind: .cancelled, code: "biometric.cancelled"),
      requestID: requestID
    ))
    result(true)
  }

  private func installBackgroundObservers(for operation: PendingBiometricOperation) {
    let center = NotificationCenter.default
    for name in [UIApplication.didEnterBackgroundNotification, UIScene.didEnterBackgroundNotification] {
      let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self, weak operation] _ in
        guard let self, let operation,
          self.pending === operation,
          self.lifecycle.isCurrent(operation.token)
        else { return }
        self.finish(operation, BiometricPolicy.authenticationEnvelope(
          BiometricOutcome(kind: .cancelled, code: "biometric.backgrounded"),
          requestID: operation.token.requestID
        ))
      }
      operation.observers.append(observer)
    }
  }

  private func finish(_ operation: PendingBiometricOperation, _ response: [String: String]) {
    guard lifecycle.settle(operation.token, cleanup: { [weak self] in self?.cleanup(operation) }) else {
      return
    }
    operation.result(response)
  }

  private func cleanup(_ operation: PendingBiometricOperation) {
    if pending === operation { pending = nil }
    let center = NotificationCenter.default
    for observer in operation.observers { center.removeObserver(observer) }
    operation.observers.removeAll()
    operation.contextLease.invalidate()
    operation.context = nil
  }

  private var hasFaceIDPurpose: Bool {
    guard let purpose = Bundle.main.object(
      forInfoDictionaryKey: BiometricPolicy.faceIDPurposeKey
    ) as? String else { return false }
    return !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var foregroundState: BiometricForegroundState {
    let applicationState = UIApplication.shared.applicationState
    let scenes = UIApplication.shared.connectedScenes
    let sceneStates = scenes.compactMap { $0 as? UIWindowScene }.map(\.activationState)
    if !scenes.isEmpty && sceneStates.isEmpty { return .unavailable }
    if applicationState == .background || (!sceneStates.isEmpty && sceneStates.allSatisfy({ $0 == .background })) {
      return .background
    }
    if applicationState == .active {
      if scenes.isEmpty || sceneStates.contains(.foregroundActive) { return .active }
      return .unavailable
    }
    if applicationState == .inactive {
      if scenes.isEmpty || sceneStates.contains(.foregroundActive) || sceneStates.contains(.foregroundInactive) {
        return .inactive
      }
      return .unavailable
    }
    return .unavailable
  }

  private static func biometryType(_ type: LABiometryType) -> BiometricType {
    switch type {
    case .touchID: return .touchID
    case .faceID: return .faceID
    case .none: return .none
    @unknown default: return .none
    }
  }

  private static func failureReason(_ error: Error?) -> BiometricFailureReason? {
    guard let error else { return nil }
    let nativeError = error as NSError
    return BiometricPolicy.classifyError(
      domain: nativeError.domain,
      code: nativeError.code,
      localAuthenticationDomain: LAError.errorDomain
    ) { rawCode in
      guard let code = LAError.Code(rawValue: rawCode) else { return nil }
      switch code {
      case .authenticationFailed: return .authenticationFailed
      case .userCancel: return .userCancel
      case .appCancel: return .appCancel
      case .systemCancel: return .systemCancel
      case .userFallback: return .userFallback
      case .biometryLockout: return .biometryLockout
      case .biometryNotEnrolled: return .biometryNotEnrolled
      case .biometryNotAvailable: return .biometryNotAvailable
      case .passcodeNotSet: return .passcodeNotSet
      @unknown default: return .other
      }
    }
  }
}

private final class PendingBiometricOperation {
  let token: BiometricOperationToken
  var context: LAContext?
  let contextLease: BiometricContextLease
  let result: FlutterResult
  var observers = [NSObjectProtocol]()

  init(
    token: BiometricOperationToken,
    context: LAContext,
    contextLease: BiometricContextLease,
    result: @escaping FlutterResult
  ) {
    self.token = token
    self.context = context
    self.contextLease = contextLease
    self.result = result
  }
}
