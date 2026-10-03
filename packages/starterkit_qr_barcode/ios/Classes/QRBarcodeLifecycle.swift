import Foundation

/// Closed wire outcomes shared by the Flutter adapter and native regressions.
enum QRBarcodeOutcome: CaseIterable {
  case noResult, invalidRequest, invalidImage, imageTooLarge, imageDimensions
  case invalidPayload, unavailable, engineDetached, operationInProgress, decodeError

  var wire: [String: Any] {
    let pair: (String, String)
    switch self {
    case .noResult: pair = ("noResult", "qr.no_result")
    case .invalidRequest: pair = ("invalid", "qr.invalid_request")
    case .invalidImage: pair = ("invalid", "qr.invalid_image")
    case .imageTooLarge: pair = ("invalid", "qr.image_too_large")
    case .imageDimensions: pair = ("invalid", "qr.image_dimensions")
    case .invalidPayload: pair = ("invalid", "qr.invalid_payload")
    case .unavailable: pair = ("unavailable", "qr.unavailable")
    case .engineDetached: pair = ("cancelled", "qr.engine_detached")
    case .operationInProgress: pair = ("conflict", "qr.operation_in_progress")
    case .decodeError: pair = ("failure", "qr.decode_error")
    }
    return ["kind": pair.0, "code": pair.1]
  }

  static func decode(using decoder: () throws -> [QRBarcodeObservation]) -> [String: Any] {
    do {
      let codes = try QRBarcodePolicy.normalize(decoder())
      guard !codes.isEmpty else { return QRBarcodeOutcome.noResult.wire }
      return [
        "kind": "success", "code": "qr.success",
        "codes": codes.map { ["value": $0.value, "format": $0.format] },
      ]
    } catch QRBarcodeFailure.tooLarge {
      return QRBarcodeOutcome.imageTooLarge.wire
    } catch QRBarcodeFailure.dimensions {
      return QRBarcodeOutcome.imageDimensions.wire
    } catch QRBarcodeFailure.invalidPayload {
      return QRBarcodeOutcome.invalidPayload.wire
    } catch QRBarcodeFailure.invalidImage {
      return QRBarcodeOutcome.invalidImage.wire
    } catch QRBarcodeFailure.unavailable {
      return QRBarcodeOutcome.unavailable.wire
    } catch {
      return QRBarcodeOutcome.decodeError.wire
    }
  }
}

/// Process-wide single-flight admission. It owns no engine or callback references.
final class QRBarcodeProcessAdmission {
  static let shared = QRBarcodeProcessAdmission()
  private let lock = NSLock()
  private var occupied = false

  func acquire() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !occupied else { return false }
    occupied = true
    return true
  }

  func release() {
    lock.lock()
    occupied = false
    lock.unlock()
  }

  var isOccupied: Bool {
    lock.lock()
    defer { lock.unlock() }
    return occupied
  }
}

/// One engine-bound callback. Detach clears it immediately; a late worker can only
/// complete this invalidated object and can never reach a subsequently attached engine.
final class QRBarcodeOperation {
  private let lock = NSLock()
  private var callback: (([String: Any]) -> Void)?
  private var invalidated = false

  var isInvalidated: Bool {
    lock.lock()
    defer { lock.unlock() }
    return invalidated
  }

  init(completion: @escaping ([String: Any]) -> Void) { callback = completion }

  @discardableResult
  func settle(_ outcome: [String: Any]) -> Bool {
    lock.lock()
    guard !invalidated, let callback else {
      lock.unlock()
      return false
    }
    invalidated = true
    self.callback = nil
    lock.unlock()
    callback(outcome)
    return true
  }

  @discardableResult
  func detach(_ outcome: [String: Any]) -> Bool {
    lock.lock()
    guard !invalidated else {
      lock.unlock()
      return false
    }
    invalidated = true
    let pending = callback
    callback = nil
    lock.unlock()
    pending?(outcome)
    return pending != nil
  }

  func workerFinished() {
    lock.lock()
    invalidated = true
    callback = nil
    lock.unlock()
  }
}

/// Engine state is confined to the main/engine boundary by the Flutter adapter.
/// A worker owns its operation, not this state or the plugin. Both generation and
/// object identity must match before it may clear pending state or deliver a result.
final class QRBarcodeEngineState {
  private(set) var isAttached = true
  private(set) var pending: QRBarcodeOperation?
  private var generation: UInt64 = 0

  func begin(_ operation: QRBarcodeOperation) -> UInt64 {
    precondition(isAttached && pending == nil)
    generation &+= 1
    pending = operation
    return generation
  }

  @discardableResult
  func finish(
    _ operation: QRBarcodeOperation, generation operationGeneration: UInt64,
    outcome: [String: Any]
  ) -> Bool {
    guard isAttached, generation == operationGeneration, pending === operation else {
      operation.workerFinished()
      return false
    }
    pending = nil
    return operation.settle(outcome)
  }

  func detach() {
    isAttached = false
    generation &+= 1
    let operation = pending
    pending = nil
    _ = operation?.detach(QRBarcodeOutcome.engineDetached.wire)
  }
}

enum QRBarcodeScheduling {
  @discardableResult
  static func enqueue(
    using schedule: (@escaping () -> Void) -> Bool,
    admission: QRBarcodeProcessAdmission,
    work: @escaping () -> Void,
    onFailure: () -> Void
  ) -> Bool {
    // The scheduler accepts exactly one execution, or rejects without executing.
    // Release belongs to real worker unwind (or rejection), never engine detach.
    guard schedule({
      defer { admission.release() }
      work()
    }) else {
      defer { admission.release() }
      onFailure()
      return false
    }
    return true
  }
}
