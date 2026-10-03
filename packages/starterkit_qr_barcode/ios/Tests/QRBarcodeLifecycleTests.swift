import Foundation
import XCTest
@testable import StarterkitQrBarcodeNative

final class QRBarcodeLifecycleTests: XCTestCase {
  func testProcessAdmissionIsSingleFlightUntilRealWorkerFinishesAfterDetach() {
    let admission = QRBarcodeProcessAdmission()
    XCTAssertTrue(admission.acquire())
    XCTAssertFalse(admission.acquire())

    var detachSettlements = 0
    let engine = QRBarcodeEngineState()
    let operation = QRBarcodeOperation { outcome in
      XCTAssertEqual(outcome["kind"] as? String, "cancelled")
      XCTAssertEqual(outcome["code"] as? String, "qr.engine_detached")
      detachSettlements += 1
    }
    let generation = engine.begin(operation)
    var worker: (() -> Void)?
    XCTAssertTrue(QRBarcodeScheduling.enqueue(
      using: { worker = $0; return true }, admission: admission,
      work: {
        XCTAssertTrue(admission.isOccupied)
        XCTAssertFalse(engine.finish(
          operation, generation: generation, outcome: QRBarcodeOutcome.noResult.wire
        ))
        XCTAssertTrue(admission.isOccupied, "completion must not release before worker unwind")
      }, onFailure: { XCTFail("accepted worker cannot fail scheduling") }
    ))
    engine.detach()
    XCTAssertNil(engine.pending)
    XCTAssertFalse(engine.isAttached)
    engine.detach()
    XCTAssertEqual(detachSettlements, 1)
    XCTAssertFalse(admission.acquire(), "reattach cannot overlap still-running native decode")

    XCTAssertNotNil(worker)
    worker?()
    XCTAssertEqual(detachSettlements, 1)
    XCTAssertTrue(operation.isInvalidated)
    XCTAssertTrue(admission.acquire())
    admission.release()
    XCTAssertFalse(admission.isOccupied)
  }

  func testGenerationAndIdentityFencePreservesNewPendingOperation() {
    let engine = QRBarcodeEngineState()
    var oldSettlements = 0
    let old = QRBarcodeOperation { _ in oldSettlements += 1 }
    let oldGeneration = engine.begin(old)
    XCTAssertTrue(engine.finish(old, generation: oldGeneration, outcome: QRBarcodeOutcome.noResult.wire))
    XCTAssertEqual(oldSettlements, 1)

    var nextSettlements = 0
    let next = QRBarcodeOperation(completion: { _ in nextSettlements += 1 })
    let nextGeneration = engine.begin(next)
    XCTAssertNotEqual(oldGeneration, nextGeneration)
    XCTAssertFalse(engine.finish(old, generation: nextGeneration, outcome: QRBarcodeOutcome.noResult.wire))
    XCTAssertFalse(engine.finish(old, generation: oldGeneration, outcome: QRBarcodeOutcome.noResult.wire))
    XCTAssertTrue(engine.pending === next)
    XCTAssertFalse(next.isInvalidated)
    XCTAssertEqual(nextSettlements, 0)
    XCTAssertTrue(engine.finish(next, generation: nextGeneration, outcome: QRBarcodeOutcome.noResult.wire))
    XCTAssertFalse(next.detach(QRBarcodeOutcome.engineDetached.wire))
    XCTAssertEqual(nextSettlements, 1)
  }

  func testSchedulerFailureSettlesAndReleasesTheAcquiredLease() {
    let admission = QRBarcodeProcessAdmission()
    XCTAssertTrue(admission.acquire())
    let engine = QRBarcodeEngineState()
    var settlements = 0
    let operation = QRBarcodeOperation(completion: { outcome in
      XCTAssertEqual(outcome["kind"] as? String, "failure")
      XCTAssertEqual(outcome["code"] as? String, "qr.decode_error")
      settlements += 1
    })
    let generation = engine.begin(operation)
    var failureCount = 0
    let scheduled = QRBarcodeScheduling.enqueue(
      using: { _ in false },
      admission: admission,
      work: { XCTFail("rejected worker must not execute") },
      onFailure: {
        XCTAssertTrue(engine.finish(
          operation, generation: generation, outcome: QRBarcodeOutcome.decodeError.wire
        ))
        failureCount += 1
      }
    )
    XCTAssertFalse(scheduled)
    XCTAssertEqual(failureCount, 1)
    XCTAssertEqual(settlements, 1)
    XCTAssertNil(engine.pending)
    XCTAssertTrue(operation.isInvalidated)
    XCTAssertFalse(admission.isOccupied)
    XCTAssertTrue(admission.acquire())
    admission.release()
  }

  func testSuccessfulWorkerSchedulingDoesNotRunFailurePath() {
    let admission = QRBarcodeProcessAdmission()
    XCTAssertTrue(admission.acquire())
    var enqueued = false
    var worker: (() -> Void)?
    var executions = 0
    let scheduled = QRBarcodeScheduling.enqueue(
      using: { worker = $0; enqueued = true; return true },
      admission: admission,
      work: { XCTAssertTrue(admission.isOccupied); executions += 1 },
      onFailure: { XCTFail("successful scheduling cannot fail") }
    )
    XCTAssertTrue(scheduled)
    XCTAssertTrue(enqueued)
    XCTAssertEqual(executions, 0)
    XCTAssertTrue(admission.isOccupied)
    XCTAssertNotNil(worker)
    worker?()
    XCTAssertEqual(executions, 1)
    XCTAssertFalse(admission.isOccupied)
  }

  func testEveryProductionWireOutcomeMatchesFrozenKindCodeAndExactKeys() {
    let expected = [
      "qr.no_result": "noResult", "qr.invalid_request": "invalid",
      "qr.invalid_image": "invalid", "qr.image_too_large": "invalid",
      "qr.image_dimensions": "invalid", "qr.invalid_payload": "invalid",
      "qr.unavailable": "unavailable", "qr.engine_detached": "cancelled",
      "qr.operation_in_progress": "conflict", "qr.decode_error": "failure",
    ]
    XCTAssertEqual(QRBarcodeOutcome.allCases.count, expected.count)
    for outcome in QRBarcodeOutcome.allCases {
      let wire = outcome.wire
      XCTAssertEqual(Set(wire.keys), ["kind", "code"])
      let code = wire["code"] as? String
      XCTAssertNotNil(code)
      XCTAssertEqual(wire["kind"] as? String, expected[code ?? ""])
    }
  }

  func testProductionDecodeWireMapsSuccessEmptyAndTypedFailuresWithoutRawDetails() {
    let text = "  π  "
    let success = QRBarcodeOutcome.decode { [QRBarcodeObservation(value: text, format: "qr")] }
    XCTAssertEqual(Set(success.keys), ["kind", "code", "codes"])
    XCTAssertEqual(success["kind"] as? String, "success")
    XCTAssertEqual(success["code"] as? String, "qr.success")
    XCTAssertEqual(success["codes"] as? [[String: String]], [["value": text, "format": "QR"]])
    let empty = QRBarcodeOutcome.decode { [] }
    XCTAssertEqual(empty["kind"] as? String, "noResult")
    XCTAssertEqual(empty["code"] as? String, "qr.no_result")
    let failures: [(QRBarcodeFailure, QRBarcodeOutcome)] = [
      (.tooLarge, .imageTooLarge), (.dimensions, .imageDimensions),
      (.invalidPayload, .invalidPayload), (.invalidImage, .invalidImage),
      (.unavailable, .unavailable), (.decode, .decodeError),
    ]
    for (failure, expected) in failures {
      let wire = QRBarcodeOutcome.decode { throw failure }
      XCTAssertEqual(wire as NSDictionary, expected.wire as NSDictionary)
    }
    let unknown = QRBarcodeOutcome.decode { throw NSError(domain: "not-exposed", code: 123) }
    XCTAssertEqual(unknown as NSDictionary, QRBarcodeOutcome.decodeError.wire as NSDictionary)
  }

  func testDetachClearsCallbackWhileWorkerRetainsOperationAndLeaseNotEngine() {
    let admission = QRBarcodeProcessAdmission()
    XCTAssertTrue(admission.acquire())
    var engine: QRBarcodeEngineState? = QRBarcodeEngineState()
    weak var weakEngine = engine
    weak var weakOperation: QRBarcodeOperation?
    var callbackOwner: NSObject? = NSObject()
    weak var weakCallbackOwner = callbackOwner
    var worker: (() -> Void)?
    var settlements = 0
    do {
      let operation = QRBarcodeOperation { [owner = callbackOwner!] outcome in
        _ = owner
        XCTAssertEqual(outcome["code"] as? String, "qr.engine_detached")
        settlements += 1
      }
      weakOperation = operation
      let generation = engine!.begin(operation)
      XCTAssertTrue(QRBarcodeScheduling.enqueue(
        using: { worker = $0; return true }, admission: admission,
        work: { [weak engine, operation] in
          XCTAssertTrue(admission.isOccupied)
          guard let engine else { operation.workerFinished(); return }
          engine.finish(operation, generation: generation, outcome: QRBarcodeOutcome.noResult.wire)
        }, onFailure: { XCTFail("accepted worker cannot fail scheduling") }
      ))
    }
    callbackOwner = nil
    XCTAssertNotNil(weakCallbackOwner)
    engine!.detach()
    XCTAssertEqual(settlements, 1)
    XCTAssertNil(weakCallbackOwner, "detach must release the engine result callback immediately")
    engine = nil
    XCTAssertNil(weakEngine, "the queued worker must not retain engine state")
    XCTAssertNotNil(weakOperation, "the queued worker intentionally owns operation cleanup")
    XCTAssertFalse(admission.acquire())
    XCTAssertNotNil(worker)
    worker?()
    worker = nil
    XCTAssertNil(weakOperation)
    XCTAssertFalse(admission.isOccupied)
    XCTAssertEqual(settlements, 1)
  }

  func testLateDeliveryAfterWorkerUnwindCannotAffectAnotherEngine() {
    let admission = QRBarcodeProcessAdmission()
    XCTAssertTrue(admission.acquire())
    let oldEngine = QRBarcodeEngineState()
    var oldSettlements = 0
    let old = QRBarcodeOperation { _ in oldSettlements += 1 }
    let generation = oldEngine.begin(old)
    var delivery: (() -> Void)?
    XCTAssertTrue(QRBarcodeScheduling.enqueue(
      using: { work in work(); return true }, admission: admission,
      work: {
        delivery = {
          XCTAssertFalse(oldEngine.finish(old, generation: generation, outcome: QRBarcodeOutcome.noResult.wire))
        }
      }, onFailure: { XCTFail("accepted worker cannot fail scheduling") }
    ))
    XCTAssertFalse(admission.isOccupied)
    oldEngine.detach()
    let nextEngine = QRBarcodeEngineState()
    var nextSettlements = 0
    let next = QRBarcodeOperation { _ in nextSettlements += 1 }
    let nextGeneration = nextEngine.begin(next)
    XCTAssertTrue(admission.acquire())
    XCTAssertNotNil(delivery)
    delivery?()
    XCTAssertTrue(admission.isOccupied)
    XCTAssertTrue(nextEngine.pending === next)
    XCTAssertFalse(next.isInvalidated)
    XCTAssertEqual(oldSettlements, 1)
    XCTAssertEqual(nextSettlements, 0)
    XCTAssertTrue(nextEngine.finish(next, generation: nextGeneration, outcome: QRBarcodeOutcome.noResult.wire))
    admission.release()
    XCTAssertEqual(nextSettlements, 1)
  }

  func testConcurrentOperationSettleAndDetachInvokeCallbackOnlyOnce() {
    let counterLock = NSLock()
    var settlements = 0
    let operation = QRBarcodeOperation { _ in
      counterLock.lock()
      settlements += 1
      counterLock.unlock()
    }
    DispatchQueue.concurrentPerform(iterations: 64) { index in
      if index.isMultiple(of: 2) {
        operation.settle(QRBarcodeOutcome.noResult.wire)
      } else {
        operation.detach(QRBarcodeOutcome.engineDetached.wire)
      }
    }
    XCTAssertEqual(settlements, 1)
    XCTAssertTrue(operation.isInvalidated)
    XCTAssertFalse(operation.settle(QRBarcodeOutcome.noResult.wire))
  }
}
