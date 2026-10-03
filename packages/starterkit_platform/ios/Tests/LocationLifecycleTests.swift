import Foundation
import XCTest
@testable import StarterkitPlatformPolicy

final class LocationLifecycleTests: XCTestCase {
  func testBeginExclusivityMonotonicDeadlineAndExactlyOnceCallbackSettlement() throws {
    let lifecycle = LocationOperationLifecycle()
    let operation = try started(lifecycle, id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", now: 100, timeout: 60_000)
    XCTAssertEqual(operation.deadline, 160)
    XCTAssertTrue(lifecycle.isCurrent(operation))
    guard case .conflict = lifecycle.begin(
      requestID: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", kind: .location,
      timeoutMillis: 1_000, now: 101
    ) else { return XCTFail("Concurrent permission/sample operation must conflict") }

    var cleanupCount = 0
    XCTAssertEqual(
      lifecycle.settle(operation, at: operation.deadline - 0.001) { cleanupCount += 1 }, .settled
    )
    XCTAssertEqual(cleanupCount, 1)
    XCTAssertFalse(lifecycle.isCurrent(operation))
    XCTAssertEqual(lifecycle.settle(operation, at: 159) { cleanupCount += 1 }, .stale)
    XCTAssertEqual(cleanupCount, 1, "Late/double callbacks must not repeat terminal cleanup")
  }

  func testDeadlineIsRecheckedAtCallbackAndTimeoutCleansOnce() throws {
    let lifecycle = LocationOperationLifecycle()
    let operation = try started(lifecycle, id: "11111111111111111111111111111111", now: 5, timeout: 1_000)
    var cleanups = 0
    XCTAssertFalse(lifecycle.expire(operation, at: operation.deadline - 0.001) { cleanups += 1 })
    XCTAssertTrue(lifecycle.isCurrent(operation))
    XCTAssertTrue(lifecycle.expire(operation, at: operation.deadline) { cleanups += 1 })
    XCTAssertEqual(cleanups, 1)
    XCTAssertEqual(lifecycle.settle(operation, at: operation.deadline + 1) { cleanups += 1 }, .stale)
    XCTAssertEqual(cleanups, 1)
  }

  func testCancelRequiresCurrentIDAndOldManagerCallbacksCannotAffectNextGeneration() throws {
    let lifecycle = LocationOperationLifecycle()
    let old = try started(lifecycle, id: "22222222222222222222222222222222", now: 10, timeout: 5_000)
    var cleanupCount = 0
    XCTAssertNil(lifecycle.cancel(requestID: "33333333333333333333333333333333") { _ in cleanupCount += 1 })
    XCTAssertTrue(lifecycle.isCurrent(old))

    let cancelled = lifecycle.cancel(requestID: old.requestID) { _ in cleanupCount += 1 }
    XCTAssertEqual(cancelled, old)
    XCTAssertEqual(cleanupCount, 1)
    let current = try started(lifecycle, id: "44444444444444444444444444444444", now: 20, timeout: 5_000)
    XCTAssertFalse(lifecycle.isCurrent(old))
    XCTAssertTrue(lifecycle.isCurrent(current))
    XCTAssertNil(lifecycle.cancel(requestID: old.requestID) { _ in cleanupCount += 1 })
    XCTAssertEqual(lifecycle.settle(old, at: 21) { cleanupCount += 1 }, .stale)
    XCTAssertTrue(lifecycle.isCurrent(current))
    XCTAssertEqual(cleanupCount, 1)
  }

  func testCancelCallbackAndProviderFailureUseSingleTerminalCleanup() throws {
    let lifecycle = LocationOperationLifecycle()
    let permission = try started(lifecycle, id: "55555555555555555555555555555555", now: 0, timeout: 5_000, kind: .permission)
    var cleanups = 0
    XCTAssertEqual(
      lifecycle.cancel(requestID: permission.requestID) { _ in cleanups += 1 }, permission
    )
    XCTAssertEqual(lifecycle.settle(permission, at: 1) { cleanups += 1 }, .stale)

    let location = try started(lifecycle, id: "66666666666666666666666666666666", now: 2, timeout: 5_000)
    XCTAssertEqual(lifecycle.settle(location, at: 3) { cleanups += 1 }, .settled)
    XCTAssertEqual(lifecycle.settle(location, at: 4) { cleanups += 1 }, .stale)
    XCTAssertEqual(cleanups, 2, "Cancel and provider/error terminals each teardown exactly once")
  }

  func testEngineInvalidationFencesCallbacksAndDisallowsNewOperations() throws {
    let lifecycle = LocationOperationLifecycle()
    let operation = try started(lifecycle, id: "77777777777777777777777777777777", now: 2, timeout: 5_000)
    var cleaned: [LocationOperation] = []
    XCTAssertEqual(lifecycle.invalidate { cleaned.append($0) }, operation)
    XCTAssertEqual(cleaned, [operation])
    XCTAssertEqual(lifecycle.settle(operation, at: 3) { XCTFail("Late delegate must not settle") }, .stale)
    guard case .invalidated = lifecycle.begin(
      requestID: "88888888888888888888888888888888", kind: .permission,
      timeoutMillis: 1_000, now: 4
    ) else { return XCTFail("Detached lifecycle must not accept new work") }
    XCTAssertEqual(cleaned, [operation])
  }

  func testSeparateOperationObjectsFenceSameIDLateCallbackByGeneration() throws {
    let lifecycle = LocationOperationLifecycle()
    let id = "99999999999999999999999999999999"
    let first = try started(lifecycle, id: id, now: 0, timeout: 1_000)
    _ = lifecycle.cancel(requestID: id) { _ in }
    let second = try started(lifecycle, id: id, now: 2, timeout: 1_000)
    XCTAssertNotEqual(first.generation, second.generation)
    XCTAssertNotEqual(first, second)
    XCTAssertEqual(lifecycle.settle(first, at: 2.1) { XCTFail("Old CLLocationManager callback") }, .stale)
    XCTAssertTrue(lifecycle.isCurrent(second))
  }

  private func started(
    _ lifecycle: LocationOperationLifecycle,
    id: String,
    now: TimeInterval,
    timeout: Int,
    kind: LocationOperationKind = .location
  ) throws -> LocationOperation {
    switch lifecycle.begin(requestID: id, kind: kind, timeoutMillis: timeout, now: now) {
    case .started(let operation): return operation
    case .conflict: throw TestFailure.unexpectedConflict
    case .exhausted: throw TestFailure.exhausted
    case .invalidated: throw TestFailure.invalidated
    }
  }

  private enum TestFailure: Error { case unexpectedConflict, exhausted, invalidated }
}
