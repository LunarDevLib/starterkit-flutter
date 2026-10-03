import Foundation
import XCTest
@testable import StarterkitPlatformPolicy

final class MediaOperationLifecycleTests: XCTestCase {
  func testQueuedInvalidationPreventsWorkerAndDelivery() {
    var cleanups = 0
    let operation = MediaOperationLifecycle { _ in cleanups += 1 }
    XCTAssertTrue(operation.queueWork())
    XCTAssertFalse(operation.queueWork())
    operation.invalidate()
    operation.invalidate()
    XCTAssertFalse(operation.startWork())
    XCTAssertFalse(operation.settle())
    XCTAssertEqual(cleanups, 0)
  }

  func testRunningInvalidationCleansOnlyAfterWorkerStopsExactlyOnce() throws {
    let output = temporaryOutput()
    defer { try? FileManager.default.removeItem(at: output) }
    try Data([1]).write(to: output)
    var cleanups = 0
    let operation = MediaOperationLifecycle { url in
      cleanups += 1
      try? FileManager.default.removeItem(at: url)
    }
    XCTAssertTrue(operation.queueWork())
    XCTAssertTrue(operation.startWork())
    XCTAssertFalse(operation.startWork())
    operation.invalidate()
    XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    XCTAssertEqual(cleanups, 0)
    // The worker may still finish writing after detach; cleanup belongs to completion.
    try Data([1, 2]).write(to: output)
    XCTAssertFalse(operation.completeWork(output: output))
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    XCTAssertFalse(operation.completeWork(output: output))
    operation.invalidate()
    XCTAssertFalse(operation.settle())
    XCTAssertEqual(cleanups, 1)
  }

  func testCompletedBeforeMainDeliveryInvalidationCleansExactlyOnce() throws {
    let output = temporaryOutput()
    defer { try? FileManager.default.removeItem(at: output) }
    try Data([1]).write(to: output)
    var cleanups = 0
    let operation = MediaOperationLifecycle { url in
      cleanups += 1
      try? FileManager.default.removeItem(at: url)
    }
    XCTAssertTrue(operation.queueWork())
    XCTAssertTrue(operation.startWork())
    XCTAssertTrue(operation.completeWork(output: output))
    XCTAssertFalse(operation.settle())
    XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    operation.invalidate()
    operation.invalidate()
    XCTAssertFalse(operation.settle())
    XCTAssertFalse(operation.settle(fromWorker: true))
    XCTAssertFalse(operation.completeWork(output: output))
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    XCTAssertEqual(cleanups, 1)
  }

  func testSuccessfulDeliveryTransfersOutputAndRejectsDuplicates() throws {
    let output = temporaryOutput()
    defer { try? FileManager.default.removeItem(at: output) }
    try Data([1]).write(to: output)
    var cleanups = 0
    let operation = MediaOperationLifecycle { _ in cleanups += 1 }
    XCTAssertTrue(operation.queueWork())
    XCTAssertTrue(operation.startWork())
    XCTAssertFalse(operation.settle())
    XCTAssertFalse(operation.settle(fromWorker: true))
    XCTAssertTrue(operation.completeWork(output: output))
    XCTAssertFalse(operation.settle())
    XCTAssertTrue(operation.settle(fromWorker: true))
    XCTAssertFalse(operation.settle())
    XCTAssertFalse(operation.settle(fromWorker: true))
    XCTAssertFalse(operation.completeWork(output: output))
    operation.invalidate()
    XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    XCTAssertEqual(cleanups, 0)
  }

  func testLateOldWorkerCannotSettleNewOperation() {
    var abandoned = [URL]()
    let old = MediaOperationLifecycle { abandoned.append($0) }
    let current = MediaOperationLifecycle { _ in XCTFail("New operation must retain its output") }
    XCTAssertTrue(old.queueWork())
    XCTAssertTrue(old.startWork())
    old.invalidate()
    XCTAssertTrue(current.queueWork())
    let oldOutput = temporaryOutput()
    XCTAssertFalse(old.completeWork(output: oldOutput))
    XCTAssertFalse(old.settle())
    XCTAssertFalse(old.settle(fromWorker: true))
    XCTAssertFalse(current.settle())
    XCTAssertTrue(current.startWork())
    XCTAssertTrue(current.completeWork(output: temporaryOutput()))
    XCTAssertTrue(current.settle(fromWorker: true))
    XCTAssertEqual(abandoned, [oldOutput])
  }

  func testSelectionFailureSettlesOnlyOnceWithoutWorker() {
    let operation = MediaOperationLifecycle { _ in XCTFail("No output exists") }
    XCTAssertFalse(operation.settle(fromWorker: true))
    XCTAssertTrue(operation.settle())
    XCTAssertFalse(operation.settle())
    XCTAssertFalse(operation.queueWork())
    operation.invalidate()
  }

  func testBackgroundCompletionAfterMainInvalidationCleansOutput() throws {
    let output = temporaryOutput()
    defer { try? FileManager.default.removeItem(at: output) }
    let workerStarted = DispatchSemaphore(value: 0)
    let finishWorker = DispatchSemaphore(value: 0)
    let finished = expectation(description: "Invalidated worker completes and cleans")
    let operation = MediaOperationLifecycle { url in
      try? FileManager.default.removeItem(at: url)
    }
    XCTAssertTrue(operation.queueWork())
    DispatchQueue.global().async {
      XCTAssertTrue(operation.startWork())
      workerStarted.signal()
      guard finishWorker.wait(timeout: .now() + 5) == .success else {
        XCTFail("Worker was not released")
        finished.fulfill()
        return
      }
      do {
        try Data([1]).write(to: output)
        XCTAssertFalse(operation.completeWork(output: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
      } catch {
        XCTFail("Fixture write failed")
      }
      finished.fulfill()
    }
    XCTAssertEqual(workerStarted.wait(timeout: .now() + 5), .success)
    operation.invalidate()
    finishWorker.signal()
    wait(for: [finished], timeout: 10)
    XCTAssertFalse(operation.settle())
  }

  private func temporaryOutput() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }
}
