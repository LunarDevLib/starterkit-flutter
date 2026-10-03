import Flutter
import Foundation

public final class StarterkitQrBarcodePlugin: NSObject, FlutterPlugin {
  private var channel: FlutterMethodChannel?
  private let engine = QRBarcodeEngineState()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = StarterkitQrBarcodePlugin()
    let channel = FlutterMethodChannel(
      name: "starterkit/qr_barcode", binaryMessenger: registrar.messenger()
    )
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.publish(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { self.handle(call, result: result) }
      return
    }
    guard engine.isAttached else {
      result(QRBarcodeOutcome.engineDetached.wire)
      return
    }
    guard call.method == "decodeImage" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard engine.pending == nil else {
      result(QRBarcodeOutcome.operationInProgress.wire)
      return
    }
    guard let arguments = call.arguments as? [String: Any],
      Set(arguments.keys) == ["bytes"],
      let typed = arguments["bytes"] as? FlutterStandardTypedData,
      // Flutter's public elementSize is 1 only for UInt8 typed data; all other
      // StandardCodec numeric buffers use 4 or 8 bytes per element.
      typed.elementSize == 1
    else {
      result(QRBarcodeOutcome.invalidRequest.wire)
      return
    }
    guard !typed.data.isEmpty else {
      result(QRBarcodeOutcome.invalidImage.wire)
      return
    }
    guard typed.data.count <= QRBarcodePolicy.maximumBytes else {
      result(QRBarcodeOutcome.imageTooLarge.wire)
      return
    }
    guard QRBarcodeProcessAdmission.shared.acquire() else {
      result(QRBarcodeOutcome.operationInProgress.wire)
      return
    }

    let operation = QRBarcodeOperation(completion: { outcome in result(outcome) })
    let operationGeneration = engine.begin(operation)
    // The bytes are copied only after successful process-wide admission.
    let snapshot = Data(typed.data)
    QRBarcodeScheduling.enqueue(
      using: qrBarcodeScheduleWorker, admission: QRBarcodeProcessAdmission.shared,
      work: { [weak self, operation] in
        let outcome = QRBarcodeOutcome.decode { try QRBarcodeDecoder().decode(snapshot) }
        DispatchQueue.main.async { [weak self, operation] in
          guard let self else {
            operation.workerFinished()
            return
          }
          self.engine.finish(operation, generation: operationGeneration, outcome: outcome)
        }
      },
      onFailure: { [weak self, operation] in
        guard let self else {
          operation.workerFinished()
          return
        }
        self.engine.finish(
          operation, generation: operationGeneration, outcome: QRBarcodeOutcome.decodeError.wire
        )
      }
    )
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { self.detachFromEngine(for: registrar) }
      return
    }
    channel?.setMethodCallHandler(nil)
    channel = nil
    engine.detach()
  }
}

/// Internal scheduling seam keeps failure handling deterministic in tests.
var qrBarcodeScheduleWorker: (@escaping () -> Void) -> Bool = { work in
  DispatchQueue.global(qos: .userInitiated).async(execute: work)
  return true
}
