import Flutter
import UserNotifications

/// Notification permission only; no remote registration, delegate, or startup access.
final class IOSPushAdapter {
  private let pendingPermission = PushPendingPermission()

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in
        guard let self else {
          if PushPolicy.supports(call.method) {
            result(PushPermissionOutcome.engineDetached.wire)
          } else {
            result(FlutterMethodNotImplemented)
          }
          return
        }
        self.handle(call, result: result)
      }
      return
    }
    guard PushPolicy.supports(call.method) else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard PushPolicy.validArguments(call.arguments) else {
      result(PushPermissionOutcome.invalidArguments.wire)
      return
    }
    guard let operation = pendingPermission.begin(reply: { result($0) }) else { return }
    // No center is retained/created at registration; both operations are explicit.
    let center = UNUserNotificationCenter.current()
    if call.method == "permissionStatus" {
      center.getNotificationSettings { [weak self, weak operation] settings in
        let outcome = PushPolicy.status(Self.authorizationState(settings.authorizationStatus))
        DispatchQueue.main.async { [weak self, weak operation] in
          guard let self, let operation else { return }
          self.pendingPermission.finish(operation, outcome: outcome)
        }
      }
    } else {
      center.requestAuthorization(options: [.alert, .badge, .sound]) {
        [weak self, weak operation] granted, error in
        let outcome = PushPolicy.requestOutcome(granted: granted, failed: error != nil)
        DispatchQueue.main.async { [weak self, weak operation] in
          guard let self, let operation else { return }
          self.pendingPermission.finish(operation, outcome: outcome)
        }
      }
    }
  }

  func detach() {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in self?.detach() }
      return
    }
    pendingPermission.detach()
  }

  private static func authorizationState(_ status: UNAuthorizationStatus) -> PushAuthorizationState {
    if status == .authorized { return .authorized }
    if status == .provisional { return .provisional }
    if #available(iOS 14.0, *), status == .ephemeral { return .ephemeral }
    if status == .denied { return .denied }
    if status == .notDetermined { return .notDetermined }
    // Future SDK enum values fail closed without requiring a newer system API.
    return .restricted
  }
}
