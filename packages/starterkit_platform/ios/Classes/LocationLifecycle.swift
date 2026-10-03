import Foundation

enum LocationOperationKind: Equatable {
  case permission
  case location
}

struct LocationOperation: Equatable {
  let requestID: String
  let generation: UInt64
  let kind: LocationOperationKind
  let deadline: TimeInterval
}

enum LocationOperationStart {
  case started(LocationOperation)
  case conflict
  case exhausted
  case invalidated
}

enum LocationOperationSettlement: Equatable {
  case settled
  case expired
  case stale
}

/// Foundation-only generation fence shared by the CoreLocation adapter and host-side tests.
final class LocationOperationLifecycle {
  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var current: LocationOperation?
  private var invalidated = false

  var hasPending: Bool {
    lock.lock()
    defer { lock.unlock() }
    return current != nil
  }

  func begin(
    requestID: String, kind: LocationOperationKind, timeoutMillis: Int, now: TimeInterval
  ) -> LocationOperationStart {
    lock.lock()
    defer { lock.unlock() }
    guard !invalidated else { return .invalidated }
    guard current == nil else { return .conflict }
    guard generation < UInt64.max, timeoutMillis > 0, now.isFinite else { return .exhausted }
    generation += 1
    let operation = LocationOperation(
      requestID: requestID,
      generation: generation,
      kind: kind,
      deadline: now + Double(timeoutMillis) / 1_000
    )
    current = operation
    return .started(operation)
  }

  func isCurrent(_ operation: LocationOperation) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return current == operation
  }

  func settle(
    _ operation: LocationOperation,
    at now: TimeInterval,
    onTerminal: () -> Void
  ) -> LocationOperationSettlement {
    lock.lock()
    guard current == operation else {
      lock.unlock()
      return .stale
    }
    current = nil
    let result: LocationOperationSettlement = now >= operation.deadline ? .expired : .settled
    lock.unlock()
    onTerminal()
    return result
  }

  @discardableResult
  func expire(
    _ operation: LocationOperation,
    at now: TimeInterval,
    onTerminal: () -> Void
  ) -> Bool {
    guard now >= operation.deadline else { return false }
    return settle(operation, at: now, onTerminal: onTerminal) != .stale
  }

  func cancel(
    requestID: String, onTerminal: (LocationOperation) -> Void
  ) -> LocationOperation? {
    lock.lock()
    guard let operation = current, operation.requestID == requestID else {
      lock.unlock()
      return nil
    }
    current = nil
    lock.unlock()
    onTerminal(operation)
    return operation
  }

  func invalidate(onTerminal: (LocationOperation) -> Void) -> LocationOperation? {
    lock.lock()
    guard !invalidated else {
      lock.unlock()
      return nil
    }
    invalidated = true
    let operation = current
    current = nil
    lock.unlock()
    if let operation { onTerminal(operation) }
    return operation
  }
}
