import Foundation
import XCTest
@testable import StarterkitPlatformPolicy

final class BiometricLifecycleTests: XCTestCase {
  func testSinglePendingConflictAndExactlyOnceTerminalCleanup() throws {
    let lifecycle = BiometricOperationLifecycle()
    let first = try started(lifecycle, id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    guard case .conflict = lifecycle.begin(requestID: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb") else {
      return XCTFail("Concurrent authentication must preserve the incumbent")
    }
    XCTAssertTrue(lifecycle.isCurrent(first))

    var cleanups = 0
    XCTAssertTrue(lifecycle.settle(first) { cleanups += 1 })
    XCTAssertFalse(lifecycle.settle(first) { cleanups += 1 })
    XCTAssertEqual(cleanups, 1)
    XCTAssertFalse(lifecycle.hasPending)
  }

  func testCancelMatchesOnlyCurrentIDAndOldCallbackCannotAffectNewGeneration() throws {
    let lifecycle = BiometricOperationLifecycle()
    let old = try started(lifecycle, id: "11111111111111111111111111111111")
    var cleanups = 0
    XCTAssertNil(lifecycle.cancel(requestID: "22222222222222222222222222222222") { _ in cleanups += 1 })
    XCTAssertTrue(lifecycle.isCurrent(old))
    XCTAssertEqual(
      lifecycle.cancel(requestID: old.requestID) { token in
        XCTAssertEqual(token, old)
        cleanups += 1
      },
      old
    )
    let current = try started(lifecycle, id: "33333333333333333333333333333333")
    XCTAssertNotEqual(old.generation, current.generation)
    XCTAssertFalse(lifecycle.isCurrent(old))
    XCTAssertTrue(lifecycle.isCurrent(current))
    XCTAssertNil(lifecycle.cancel(requestID: old.requestID) { _ in cleanups += 1 })
    XCTAssertFalse(lifecycle.settle(old) { cleanups += 1 })
    XCTAssertTrue(lifecycle.isCurrent(current))
    XCTAssertEqual(cleanups, 1)
  }

  func testReusedRequestIDFencesOldCallbackButCancelsCurrentGeneration() throws {
    let lifecycle = BiometricOperationLifecycle()
    let requestID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    let old = try started(lifecycle, id: requestID)
    var cleanups: [BiometricOperationToken] = []

    XCTAssertEqual(
      lifecycle.cancel(requestID: old.requestID) { cleanups.append($0) },
      old
    )
    let current = try started(lifecycle, id: requestID)
    XCTAssertNotEqual(old.generation, current.generation)
    XCTAssertFalse(lifecycle.isCurrent(old))
    XCTAssertFalse(lifecycle.settle(old) { cleanups.append(old) })
    XCTAssertTrue(lifecycle.isCurrent(current))
    XCTAssertEqual(cleanups, [old])

    XCTAssertEqual(
      lifecycle.cancel(requestID: current.requestID) { token in
        XCTAssertEqual(token, current)
        cleanups.append(token)
      },
      current
    )
    XCTAssertFalse(lifecycle.hasPending)
    XCTAssertNil(lifecycle.cancel(requestID: current.requestID) { cleanups.append($0) })
    XCTAssertFalse(lifecycle.settle(current) { cleanups.append(current) })
    XCTAssertEqual(cleanups, [old, current])
  }

  func testEngineInvalidationCleansPendingOnceAndRejectsNewWork() throws {
    let lifecycle = BiometricOperationLifecycle()
    let operation = try started(lifecycle, id: "33333333333333333333333333333333")
    var cleaned: [BiometricOperationToken] = []
    XCTAssertEqual(lifecycle.invalidate { cleaned.append($0) }, operation)
    XCTAssertNil(lifecycle.invalidate { cleaned.append($0) })
    XCTAssertFalse(lifecycle.settle(operation) { XCTFail("Detached callback must be stale") })
    guard case .invalidated = lifecycle.begin(requestID: "44444444444444444444444444444444") else {
      return XCTFail("Detached lifecycle cannot accept work")
    }
    XCTAssertEqual(cleaned, [operation])
  }

  func testContextLeaseInvalidatesUnderlyingContextExactlyOnce() {
    var invalidations = 0
    let lease = BiometricContextLease { invalidations += 1 }
    lease.invalidate()
    lease.invalidate()
    XCTAssertEqual(invalidations, 1)
  }

  func testContextLeaseIsInvalidatedByCancelAndEngineDetachCleanup() throws {
    let cancellationLifecycle = BiometricOperationLifecycle()
    let cancelled = try started(
      cancellationLifecycle, id: "88888888888888888888888888888888"
    )
    var cancelInvalidations = 0
    let cancelLease = BiometricContextLease { cancelInvalidations += 1 }
    XCTAssertEqual(
      cancellationLifecycle.cancel(requestID: cancelled.requestID) { token in
        XCTAssertEqual(token, cancelled)
        cancelLease.invalidate()
      },
      cancelled
    )
    cancelLease.invalidate()
    XCTAssertEqual(cancelInvalidations, 1)

    let detachLifecycle = BiometricOperationLifecycle()
    let detached = try started(
      detachLifecycle, id: "99999999999999999999999999999999"
    )
    var detachInvalidations = 0
    let detachLease = BiometricContextLease { detachInvalidations += 1 }
    XCTAssertEqual(detachLifecycle.invalidate { token in
      XCTAssertEqual(token, detached)
      detachLease.invalidate()
    }, detached)
    detachLease.invalidate()
    XCTAssertEqual(detachInvalidations, 1)
  }

  func testSynchronousFakeCompletionBeforePostEvaluateSetupCleansContextOnce() throws {
    let lifecycle = BiometricOperationLifecycle()
    let operation = try started(lifecycle, id: "55555555555555555555555555555555")
    var cleanups = 0
    var contextInvalidations = 0
    var outcome: [String: String]?
    let lease = BiometricContextLease { contextInvalidations += 1 }
    let driver = SynchronousFakeBiometricDriver()

    // Production registers the operation and cleanup ownership before evaluatePolicy.
    driver.evaluate { success, error in
      guard lifecycle.isCurrent(operation) else { return }
      outcome = BiometricPolicy.authenticationOutcome(
        success: success, error: error, foreground: .active, requestID: operation.requestID
      )
      XCTAssertTrue(lifecycle.settle(operation) {
        cleanups += 1
        lease.invalidate()
      })
    }

    XCTAssertEqual(outcome?["kind"], "authenticated")
    XCTAssertEqual(cleanups, 1)
    XCTAssertEqual(contextInvalidations, 1)
    // A cancel handle installed after synchronous completion sees no pending request.
    XCTAssertNil(lifecycle.cancel(requestID: operation.requestID) { _ in
      cleanups += 1
      lease.invalidate()
    })
    XCTAssertEqual(cleanups, 1)
    XCTAssertEqual(contextInvalidations, 1)
  }

  func testBackgroundCancellationAndLateReplyCannotSettleAnotherRequest() throws {
    let lifecycle = BiometricOperationLifecycle()
    let backgrounded = try started(lifecycle, id: "66666666666666666666666666666666")
    var cleanups = 0
    let backgroundResponse = BiometricPolicy.authenticationOutcome(
      success: true, error: nil, foreground: .background, requestID: backgrounded.requestID
    )
    XCTAssertEqual(backgroundResponse["kind"], "cancelled")
    XCTAssertTrue(lifecycle.settle(backgrounded) { cleanups += 1 })
    let next = try started(lifecycle, id: "77777777777777777777777777777777")
    XCTAssertFalse(lifecycle.settle(backgrounded) { cleanups += 1 })
    XCTAssertTrue(lifecycle.isCurrent(next))
    XCTAssertEqual(cleanups, 1)
  }

  private func started(
    _ lifecycle: BiometricOperationLifecycle, id: String
  ) throws -> BiometricOperationToken {
    switch lifecycle.begin(requestID: id) {
    case .started(let token): return token
    case .conflict: throw TestFailure.conflict
    case .exhausted: throw TestFailure.exhausted
    case .invalidated: throw TestFailure.invalidated
    }
  }

  private enum TestFailure: Error { case conflict, exhausted, invalidated }
}

private final class SynchronousFakeBiometricDriver {
  func evaluate(_ completion: (Bool, BiometricFailureReason?) -> Void) {
    completion(true, nil)
  }
}
