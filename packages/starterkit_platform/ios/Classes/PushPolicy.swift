import Foundation

enum PushAuthorizationState: CaseIterable {
  case authorized, provisional, ephemeral, denied, notDetermined, restricted
}

enum PushPermissionOutcome: CaseIterable {
  case granted, denied, notDetermined, restricted
  case invalidArguments, permissionFailed, conflict, engineDetached

  var wire: [String: String] {
    let pair: (String, String)
    switch self {
    case .granted: pair = ("granted", "push.permission_granted")
    case .denied: pair = ("denied", "push.permission_denied")
    case .notDetermined: pair = ("notDetermined", "push.permission_not_determined")
    case .restricted: pair = ("restricted", "push.permission_restricted")
    case .invalidArguments: pair = ("invalid", "push.invalid_arguments")
    case .permissionFailed: pair = ("failure", "push.permission_failed")
    case .conflict: pair = ("conflict", "push.operation_in_progress")
    case .engineDetached: pair = ("failure", "push.engine_detached")
    }
    return ["kind": pair.0, "code": pair.1]
  }
}

enum PushPolicy {
  static func supports(_ method: String) -> Bool {
    method == "permissionStatus" || method == "requestPermission"
  }

  static func validArguments(_ arguments: Any?) -> Bool {
    arguments == nil || arguments is NSNull
  }

  static func status(_ state: PushAuthorizationState) -> PushPermissionOutcome {
    switch state {
    case .authorized, .provisional, .ephemeral: return .granted
    case .denied: return .denied
    case .notDetermined: return .notDetermined
    case .restricted: return .restricted
    }
  }

  static func requestOutcome(granted: Bool, failed: Bool) -> PushPermissionOutcome {
    failed ? .permissionFailed : (granted ? .granted : .denied)
  }
}

/// Main-thread-only ownership for the two asynchronous permission methods.
final class PushPermissionOperation {
  private var reply: (([String: String]) -> Void)?

  init(reply: @escaping ([String: String]) -> Void) { self.reply = reply }

  func settle(_ outcome: PushPermissionOutcome) {
    let callback = reply
    reply = nil
    callback?(outcome.wire)
  }
}

final class PushPendingPermission {
  private(set) var pending: PushPermissionOperation?
  private var detached = false

  func begin(reply: @escaping ([String: String]) -> Void) -> PushPermissionOperation? {
    guard !detached else { reply(PushPermissionOutcome.engineDetached.wire); return nil }
    guard pending == nil else { reply(PushPermissionOutcome.conflict.wire); return nil }
    let operation = PushPermissionOperation(reply: reply)
    pending = operation
    return operation
  }

  func finish(_ operation: PushPermissionOperation, outcome: PushPermissionOutcome) {
    guard !detached, pending === operation else { return }
    pending = nil
    operation.settle(outcome)
  }

  func detach() {
    guard !detached else { return }
    detached = true
    let operation = pending
    pending = nil
    operation?.settle(.engineDetached)
  }
}
