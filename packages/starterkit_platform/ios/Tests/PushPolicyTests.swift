import Foundation
import XCTest
@testable import StarterkitPlatformPolicy

final class PushPolicyTests: XCTestCase {
  func testPermissionWireVocabularyHasOnlyExactFixedPairs() {
    XCTAssertEqual(PushPermissionOutcome.allCases.map(\.wire), [
      ["kind": "granted", "code": "push.permission_granted"],
      ["kind": "denied", "code": "push.permission_denied"],
      ["kind": "notDetermined", "code": "push.permission_not_determined"],
      ["kind": "restricted", "code": "push.permission_restricted"],
      ["kind": "invalid", "code": "push.invalid_arguments"],
      ["kind": "failure", "code": "push.permission_failed"],
      ["kind": "conflict", "code": "push.operation_in_progress"],
      ["kind": "failure", "code": "push.engine_detached"],
    ])
    for outcome in PushPermissionOutcome.allCases {
      XCTAssertEqual(Set(outcome.wire.keys), ["kind", "code"])
    }
  }

  func testOnlyPermissionMethodsAndNullArgumentsAreAccepted() {
    XCTAssertTrue(PushPolicy.supports("permissionStatus"))
    XCTAssertTrue(PushPolicy.supports("requestPermission"))
    for method in ["", "register", "requestpermission", "activateMessages", "permissionStatus "] {
      XCTAssertFalse(PushPolicy.supports(method))
    }
    XCTAssertTrue(PushPolicy.validArguments(nil))
    XCTAssertTrue(PushPolicy.validArguments(NSNull()))
    let invalid: [Any] = [
      [String: Any](), [Any](), "", 0, false, ["requestId": "x"], ["permission": NSNull()],
    ]
    for value in invalid { XCTAssertFalse(PushPolicy.validArguments(value)) }
  }

  func testEveryAuthorizationStateUsesTheBoundedStatusMapping() {
    XCTAssertEqual(PushAuthorizationState.allCases.map(PushPolicy.status), [
      .granted, .granted, .granted, .denied, .notDetermined, .restricted,
    ])
  }

  func testRequestCompletionUsesFixedFailureWithoutExposingSystemErrors() {
    XCTAssertEqual(PushPolicy.requestOutcome(granted: true, failed: false), .granted)
    XCTAssertEqual(PushPolicy.requestOutcome(granted: false, failed: false), .denied)
    XCTAssertEqual(PushPolicy.requestOutcome(granted: true, failed: true), .permissionFailed)
    XCTAssertEqual(PushPolicy.requestOutcome(granted: false, failed: true), .permissionFailed)
  }

  func testConstructionAndIdleDetachAreInert() {
    let state = PushPendingPermission()
    XCTAssertNil(state.pending)
    state.detach()
    state.detach()
    XCTAssertNil(state.pending)
    var replies: [[String: String]] = []
    XCTAssertNil(state.begin { replies.append($0) })
    XCTAssertEqual(replies, [PushPermissionOutcome.engineDetached.wire])
  }

  func testSingleFlightConflictPreservesTheIncumbent() throws {
    let state = PushPendingPermission()
    var firstReplies: [[String: String]] = []
    var secondReplies: [[String: String]] = []
    let first = try XCTUnwrap(state.begin { firstReplies.append($0) })
    XCTAssertNil(state.begin { secondReplies.append($0) })
    XCTAssertTrue(state.pending === first)
    XCTAssertTrue(firstReplies.isEmpty)
    XCTAssertEqual(secondReplies, [PushPermissionOutcome.conflict.wire])
    state.finish(first, outcome: .granted)
    XCTAssertEqual(firstReplies, [PushPermissionOutcome.granted.wire])
    XCTAssertNil(state.pending)
  }

  func testCompletionClearsPendingBeforeReplyAndIgnoresDuplicateCallbacks() throws {
    let state = PushPendingPermission()
    var calls = 0
    var replacement: PushPermissionOperation?
    let first = try XCTUnwrap(state.begin { _ in
      calls += 1
      XCTAssertNil(state.pending)
      replacement = state.begin { _ in }
    })
    state.finish(first, outcome: .denied)
    XCTAssertEqual(calls, 1)
    let next = try XCTUnwrap(replacement)
    XCTAssertTrue(state.pending === next)
    state.finish(first, outcome: .granted)
    XCTAssertEqual(calls, 1)
    XCTAssertTrue(state.pending === next)
    state.finish(next, outcome: .notDetermined)
    XCTAssertNil(state.pending)
  }

  func testDetachSettlesOnceAndFencesLateCompletionAndQueuedBegin() throws {
    let state = PushPendingPermission()
    var replies: [[String: String]] = []
    let operation = try XCTUnwrap(state.begin { response in
      XCTAssertNil(state.pending)
      replies.append(response)
    })
    state.detach()
    state.detach()
    state.finish(operation, outcome: .granted)
    XCTAssertEqual(replies, [PushPermissionOutcome.engineDetached.wire])
    var queued: [[String: String]] = []
    XCTAssertNil(state.begin { queued.append($0) })
    XCTAssertEqual(queued, [PushPermissionOutcome.engineDetached.wire])
  }

  func testOperationReentrantSettlementClearsCallbackBeforeReply() {
    var replies: [[String: String]] = []
    var operation: PushPermissionOperation?
    operation = PushPermissionOperation { response in
      replies.append(response)
      operation?.settle(.permissionFailed)
    }
    operation?.settle(.engineDetached)
    operation?.settle(.granted)
    XCTAssertEqual(replies, [PushPermissionOutcome.engineDetached.wire])
    operation = nil
  }

  func testWrongOperationCannotCompleteOrClearTheCurrentPermissionAction() throws {
    let state = PushPendingPermission()
    var replies: [[String: String]] = []
    let current = try XCTUnwrap(state.begin { replies.append($0) })
    let unrelated = PushPermissionOperation { _ in XCTFail("Unrelated operation cannot settle") }
    state.finish(unrelated, outcome: .granted)
    XCTAssertTrue(state.pending === current)
    XCTAssertTrue(replies.isEmpty)
    state.finish(current, outcome: .restricted)
    XCTAssertEqual(replies, [PushPermissionOutcome.restricted.wire])
  }
}
