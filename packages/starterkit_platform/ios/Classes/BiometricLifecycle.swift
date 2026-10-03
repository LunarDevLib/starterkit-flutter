import Foundation

struct BiometricOperationToken: Equatable {
  let requestID: String
  let generation: UInt64
}

enum BiometricOperationStart: Equatable {
  case started(BiometricOperationToken)
  case conflict
  case exhausted
  case invalidated
}

/// Single-pending-operation fence used by the LocalAuthentication adapter.
final class BiometricOperationLifecycle {
  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var current: BiometricOperationToken?
  private var invalidated = false

  var hasPending: Bool {
    lock.lock()
    defer { lock.unlock() }
    return current != nil
  }

  func begin(requestID: String) -> BiometricOperationStart {
    lock.lock()
    defer { lock.unlock() }
    guard !invalidated else { return .invalidated }
    guard current == nil else { return .conflict }
    guard generation < UInt64.max else { return .exhausted }
    generation += 1
    let token = BiometricOperationToken(requestID: requestID, generation: generation)
    current = token
    return .started(token)
  }

  func isCurrent(_ token: BiometricOperationToken) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return current == token
  }

  @discardableResult
  func settle(_ token: BiometricOperationToken, cleanup: () -> Void) -> Bool {
    lock.lock()
    guard current == token else {
      lock.unlock()
      return false
    }
    current = nil
    lock.unlock()
    cleanup()
    return true
  }

  @discardableResult
  func cancel(requestID: String, cleanup: (BiometricOperationToken) -> Void) -> BiometricOperationToken? {
    lock.lock()
    guard let token = current, token.requestID == requestID else {
      lock.unlock()
      return nil
    }
    current = nil
    lock.unlock()
    cleanup(token)
    return token
  }

  func invalidate(cleanup: (BiometricOperationToken) -> Void) -> BiometricOperationToken? {
    lock.lock()
    guard !invalidated else {
      lock.unlock()
      return nil
    }
    invalidated = true
    let token = current
    current = nil
    lock.unlock()
    if let token { cleanup(token) }
    return token
  }
}

/// Idempotent ownership wrapper for one LAContext invalidation closure.
final class BiometricContextLease {
  private var invalidateContext: (() -> Void)?

  init(invalidate: @escaping () -> Void) {
    invalidateContext = invalidate
  }

  func invalidate() {
    guard let invalidateContext else { return }
    self.invalidateContext = nil
    invalidateContext()
  }

  deinit {
    invalidate()
  }
}
