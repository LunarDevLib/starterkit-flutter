import Foundation
import XCTest
@testable import StarterkitPreferencesNative

final class PreferencesHandlerTests: XCTestCase {
  private final class Harness {
    var queued: [() -> Void] = []
    var factoryCalls = 0
    var completions: [Result<Any?, PreferencesFailure>] = []
    let defaults: UserDefaults
    let suiteName: String
    lazy var handler = PreferencesHandler(defaultsProvider: { [unowned self] in
      self.factoryCalls += 1
      return self.defaults
    }, schedule: { [unowned self] in self.queued.append($0) })

    init() {
      suiteName = "PreferencesHandlerTests.\(UUID().uuidString)"
      defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit { defaults.removePersistentDomain(forName: suiteName) }

    func invoke(_ method: String, _ arguments: Any?) {
      handler.handle(method: method, arguments: arguments) { [unowned self] in self.completions.append($0) }
    }

    func runNext() { queued.removeFirst()() }

    func assertError(_ code: String, file: StaticString = #filePath, line: UInt = #line) {
      guard case .failure(let failure)? = completions.last else {
        XCTFail("Expected \(code) failure", file: file, line: line)
        return
      }
      XCTAssertEqual(failure.code, code, file: file, line: line)
    }
  }

  func testRegistrationEquivalentAndInvalidCallsDoNotOpenDefaults() {
    let h = Harness()
    XCTAssertTrue(h.handler.isAttached)
    XCTAssertEqual(h.factoryCalls, 0)
    h.invoke("unknown", ["key": "okay"])
    h.assertError("preference.invalid_arguments")
    h.invoke("read", ["key": "okay", "extra": true])
    h.assertError("preference.invalid_arguments")
    h.invoke("write", ["key": "okay"])
    h.assertError("preference.invalid_arguments")
    h.invoke("read", ["key": 42])
    h.assertError("preference.invalid_key")
    h.invoke("write", ["key": "okay", "value": 42])
    h.assertError("preference.invalid_value")
    XCTAssertEqual(h.factoryCalls, 0)
    XCTAssertTrue(h.queued.isEmpty)
  }

  func testStrictASCIIKeyRuleRejectsRegexFinalNewlineVariantsBeforeAccess() {
    let h = Harness()
    for suffix in ["\n", "\r", "\r\n", "\u{2028}", "\u{2029}"] {
      h.invoke("read", ["key": "allowed" + suffix])
      h.assertError("preference.invalid_key")
    }
    for key in ["", String(repeating: "a", count: 129), "é", "key/part", "access.key"] {
      h.invoke("read", ["key": key])
      h.assertError("preference.invalid_key")
    }
    XCTAssertEqual(h.factoryCalls, 0)
    XCTAssertTrue(h.queued.isEmpty)
  }

  func testValidOperationsAreDeferredAndUseFixedPrefixInOrder() {
    let h = Harness()
    h.invoke("write", ["key": "first_key-2", "value": "value"])
    h.invoke("read", ["key": "first_key-2"])
    h.invoke("remove", ["key": "first_key-2"])
    XCTAssertEqual(h.factoryCalls, 0)
    XCTAssertEqual(h.completions.count, 0)
    XCTAssertEqual(h.queued.count, 3)
    h.runNext()
    XCTAssertEqual(h.defaults.string(forKey: "starterkit.preferences.v1.first_key-2"), "value")
    h.runNext()
    if case .success(let value)? = h.completions.last { XCTAssertEqual(value as? String, "value") }
    else { XCTFail("Expected read result") }
    h.runNext()
    XCTAssertNil(h.defaults.object(forKey: "starterkit.preferences.v1.first_key-2"))
    XCTAssertEqual(h.factoryCalls, 3)
    XCTAssertEqual(h.completions.count, 3)
  }

  func testInvalidValuesNeverScheduleAndValidBoundaryValuesDo() {
    let h = Harness()
    for value in [String(repeating: "a", count: 4097), "contains\0nul"] {
      h.invoke("write", ["key": "safe", "value": value])
      h.assertError("preference.invalid_value")
    }
    h.invoke("write", ["key": "safe", "value": String(repeating: "é", count: 2048)])
    XCTAssertEqual(h.queued.count, 1)
    h.runNext()
    XCTAssertEqual(h.defaults.string(forKey: "starterkit.preferences.v1.safe")?.utf8.count, 4096)
  }

  func testStoredInvalidTypeOversizeAndNulReturnRedactedFailure() {
    let h = Harness()
    let storageKey = "starterkit.preferences.v1.safe"
    for invalid: Any in [42, String(repeating: "x", count: 4097), "x\0y"] {
      h.defaults.set(invalid, forKey: storageKey)
      h.invoke("read", ["key": "safe"])
      h.runNext()
      h.assertError("preference.operation_failed")
    }
    XCTAssertEqual(h.completions.count, 3)
  }

  func testDetachFencesQueuedWorkAndReattachDoesNotReviveStaleWork() {
    let h = Harness()
    h.invoke("write", ["key": "safe", "value": "x"])
    h.handler.detach()
    h.runNext()
    h.assertError("preference.unavailable")
    XCTAssertEqual(h.factoryCalls, 0)
    h.handler.attach()
    h.invoke("read", ["key": "safe"])
    h.handler.detach()
    h.handler.attach()
    h.runNext()
    XCTAssertEqual(h.completions.count, 2)
    h.assertError("preference.unavailable")
    XCTAssertEqual(h.factoryCalls, 0)
  }

  func testRejectedWhileDetachedAndCompletionIsSingleForQueuedCallback() {
    let h = Harness()
    h.handler.detach()
    h.invoke("read", ["key": "safe"])
    h.assertError("preference.unavailable")
    XCTAssertTrue(h.queued.isEmpty)
    h.handler.attach()
    h.invoke("write", ["key": "safe", "value": "x"])
    h.runNext()
    XCTAssertEqual(h.completions.count, 2)
    XCTAssertEqual(h.factoryCalls, 1)
  }

  func testLateDuplicateScheduledCallbackCompletesAcceptedOperationOnlyOnce() {
    let h = Harness()
    h.invoke("read", ["key": "safe"])
    let operation = h.queued.removeFirst()
    h.handler.detach()
    h.handler.attach()
    operation()
    operation()
    XCTAssertEqual(h.completions.count, 1)
    h.assertError("preference.unavailable")
    XCTAssertEqual(h.factoryCalls, 0)
  }

  func testIsolatedUserDefaultsWriteFreshHandlerReadAndRemove() {
    let suiteName = "PreferencesHandlerRoundTrip.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }
    var writeQueue: [() -> Void] = []
    let writer = PreferencesHandler(defaultsProvider: { defaults }, schedule: { writeQueue.append($0) })
    var writeResult: Result<Any?, PreferencesFailure>?
    writer.handle(method: "write", arguments: ["key": "round_trip", "value": "persisted"]) { writeResult = $0 }
    writeQueue.removeFirst()()
    guard case .success(let writtenValue)? = writeResult else { return XCTFail("Expected write result") }
    XCTAssertNil(writtenValue)
    var readQueue: [() -> Void] = []
    let freshReader = PreferencesHandler(defaultsProvider: { defaults }, schedule: { readQueue.append($0) })
    var readResult: Result<Any?, PreferencesFailure>?
    freshReader.handle(method: "read", arguments: ["key": "round_trip"]) { readResult = $0 }
    readQueue.removeFirst()()
    guard case .success(let readValue)? = readResult else { return XCTFail("Expected read result") }
    XCTAssertEqual(readValue as? String, "persisted")
    var removeQueue: [() -> Void] = []
    let remover = PreferencesHandler(defaultsProvider: { defaults }, schedule: { removeQueue.append($0) })
    remover.handle(method: "remove", arguments: ["key": "round_trip"]) { _ in }
    removeQueue.removeFirst()()
    XCTAssertNil(defaults.object(forKey: "starterkit.preferences.v1.round_trip"))
  }
}
