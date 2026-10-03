import Flutter
import UIKit

/// Inert at registration. Only an explicit validated request can present system UI.
final class IOSNativeShareAdapter {
  private weak var host: UIViewController?
  private var pending: ShareOperation?
  private var activityController: UIActivityViewController?
  private var detached = false

  init(host: UIViewController?) { self.host = host }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in
        guard let self else {
          if call.method == "share" {
            result(ShareOutcome.engineDetached.wire)
          } else {
            result(FlutterMethodNotImplemented)
          }
          return
        }
        self.handle(call, result: result)
      }
      return
    }
    guard call.method == "share" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard !detached else { result(ShareOutcome.engineDetached.wire); return }
    guard pending == nil else { result(ShareOutcome.conflict.wire); return }
    guard let payload = SharePolicy.parse(call.arguments as? [String: Any]) else {
      result(ShareOutcome.invalidPayload.wire)
      return
    }
    guard let host, let view = host.viewIfLoaded, let window = view.window,
      window.windowScene?.activationState == .foregroundActive,
      !window.isHidden, host.presentedViewController == nil,
      !host.isBeingDismissed, !host.isBeingPresented
    else { result(ShareOutcome.hostUnavailable.wire); return }
    guard SharePolicy.anchorFits(payload.anchor, bounds: view.bounds) else {
      result(ShareOutcome.invalidPayload.wire)
      return
    }
    if let file = payload.fileURL, !SharePolicy.fileIsAvailable(file) {
      result(ShareOutcome.fileUnavailable.wire)
      return
    }
    var items: [Any] = []
    if let text = payload.text, !text.isEmpty { items.append(text) }
    if let url = payload.httpsURL { items.append(url) }
    if let file = payload.fileURL { items.append(file) }
    let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
    controller.popoverPresentationController?.sourceView = view
    controller.popoverPresentationController?.sourceRect = payload.anchor
    let operation = ShareOperation { result($0) }
    pending = operation
    activityController = controller
    controller.completionWithItemsHandler = { [weak self, weak operation] _, completed, _, error in
      let outcome = SharePolicy.completion(completed: completed, failed: error != nil)
      DispatchQueue.main.async { [weak self, weak operation] in
        guard let self, let operation, self.pending === operation else { return }
        self.pending = nil
        self.activityController?.completionWithItemsHandler = nil
        self.activityController = nil
        operation.settle(outcome)
      }
    }
    host.present(controller, animated: true)
  }

  func detach() {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in self?.detach() }
      return
    }
    guard !detached else { return }
    detached = true
    let operation = pending
    pending = nil
    let controller = activityController
    activityController = nil
    controller?.completionWithItemsHandler = nil
    controller?.dismiss(animated: false)
    host = nil
    operation?.settle(.engineDetached)
  }
}
