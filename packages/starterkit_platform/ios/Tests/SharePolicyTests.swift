import Foundation
import XCTest
@testable import StarterkitPlatformPolicy

final class SharePolicyTests: XCTestCase {
  private let rect: [String: Any] = ["x": 0.0, "y": 1.0, "width": 20.0, "height": 10.0]

  private func request(_ values: [String: Any]) -> [String: Any] {
    var arguments = values
    arguments["anchor"] = rect
    return arguments
  }

  func testPayloadPreservesExactTextAndCombinesOnlyScopedValues() throws {
    let value = "  Product share: π / 😀  "
    let payload = try XCTUnwrap(SharePolicy.parse(request([
      "text": value, "httpsUrl": "https://example.test/item?lang=en",
      "fileUri": "file:///product-selected/image.png",
    ])))
    XCTAssertEqual(payload.text, value)
    XCTAssertEqual(payload.httpsURL?.absoluteString, "https://example.test/item?lang=en")
    XCTAssertEqual(payload.fileURL?.path, "/product-selected/image.png")
    XCTAssertEqual(payload.anchor, CGRect(x: 0, y: 1, width: 20, height: 10))
  }

  func testEmptyMalformedAndUnknownTransportIsRejectedWithoutFileAccess() {
    XCTAssertNil(SharePolicy.parse(nil))
    let malformed: [[String: Any]] = [[:], ["text": ""], ["text": NSNull()],
      ["text": 1], ["text": true], ["text": "ok", "items": []],
      ["httpsUrl": ""], ["fileUri": ""], ["text": "ok", "fileUri": 1]]
    for values in malformed {
      XCTAssertNil(SharePolicy.parse(request(values)))
    }
    // Syntax parsing must not stat/open an unavailable product path.
    XCTAssertNotNil(SharePolicy.parse(request(["fileUri": "file:///nonexistent/share-image.png"])))
    XCTAssertNotNil(SharePolicy.parse(request(["text": "", "httpsUrl": "https://example.test"])))
  }

  func testTextScalarUTF8BoundsAndNoTrimming() throws {
    let astral = String(repeating: "😀", count: 4000)
    XCTAssertEqual(astral.utf8.count, 16000)
    XCTAssertNotNil(SharePolicy.parse(request(["text": astral])))
    XCTAssertNil(SharePolicy.parse(request(["text": astral + "x"])))
    XCTAssertNotNil(SharePolicy.parse(request(["text": String(repeating: "a", count: 4000)])))
    XCTAssertNil(SharePolicy.parse(request(["text": String(repeating: "a", count: 4001)])))
    // A combining sequence is two code points, not one grapheme.
    XCTAssertNil(SharePolicy.parse(request(["text": String(repeating: "e\u{301}", count: 2001)])))
    XCTAssertEqual(try XCTUnwrap(SharePolicy.parse(request(["text": "   "]))).text, "   ")
  }

  func testTextRejectsEveryC0C1ControlAndMalformedUTF16() {
    for scalar in Array(0...31) + Array(127...159) {
      let value = "a" + String(UnicodeScalar(scalar)!) + "b"
      XCTAssertNil(SharePolicy.parse(request(["text": value])))
    }
    let malformed: [[unichar]] = [[0xD800], [0xDC00], [0xD800, 0x61]]
    for units in malformed {
      let raw = units.withUnsafeBufferPointer {
        NSString(characters: $0.baseAddress!, length: $0.count)
      }
      XCTAssertNil(SharePolicy.parse(request(["text": raw])))
    }
  }

  func testHTTPSLengthASCIIAndPercentEncodingBoundaries() {
    let prefix = "https://example.test/"
    let exactly = prefix + String(repeating: "a", count: 2048 - prefix.utf8.count)
    XCTAssertNotNil(SharePolicy.httpsURL(exactly))
    XCTAssertNil(SharePolicy.httpsURL(exactly + "a"))
    XCTAssertNotNil(SharePolicy.httpsURL("HTTPS://Example.Test:443/path?q=public"))
    XCTAssertNotNil(SharePolicy.httpsURL("https://example.test/path%2Fitem"))
    for value in ["https://example.test/π", "https://example.test/a b",
      "https://example.test/\n", "https://example.test/%", "https://example.test/%GG"] {
      XCTAssertNil(SharePolicy.httpsURL(value))
    }
  }

  func testHTTPSRejectsUnsafeSchemesAuthorityFragmentsAndPorts() {
    for value in ["http://example.test", "file:///tmp/image.png", "https:example.test",
      "https://user@example.test", "https://user:pass@example.test",
      "https://example.test/#", "https://example.test/#section", "https://example.test:80",
      "https://example.test:0443", "https://example.test:", "https://example.test.",
      "https://example..test", "https://-example.test", "https://example-.test",
      "https://exam_ple.test", "https://%65xample.test", "https://[::1]",
      "https://example.test\\@other.test/"] {
      XCTAssertNil(SharePolicy.httpsURL(value), value)
    }
  }

  func testSensitiveQueryKeysAreRejectedIncludingEncodedAndNestedKeys() {
    for key in ["token", "access_token", "authorization", "auth", "api_key", "key",
      "password", "secret", "session", "code", "ACCESS_TOKEN", "my_secret_value",
      "%74oken", "%2574oken", "%61%75%74%68", "pass%77ord"] {
      XCTAssertNil(SharePolicy.httpsURL("https://example.test/?" + key + "=private"))
    }
    XCTAssertNil(SharePolicy.httpsURL("https://example.test/?%FF=bad"))
    XCTAssertNotNil(SharePolicy.httpsURL("https://example.test/?lang=en&item=42"))
  }

  func testFileURIBoundsAndLocalSyntaxOnly() {
    let prefix = "file:///"
    let exactly = prefix + String(repeating: "a", count: 2048 - prefix.utf8.count)
    XCTAssertNotNil(SharePolicy.fileURL(exactly))
    XCTAssertNil(SharePolicy.fileURL(exactly + "a"))
    XCTAssertNotNil(SharePolicy.fileURL("file:///product/image%20one.png"))
    for value in ["content://product/image", "https://example.test/image", "file:relative",
      "file://remote.test/image.png", "file://user@localhost/image.png",
      "file://localhost:443/image.png", "file:///tmp/image?", "file:///tmp/image#",
      "file:///tmp/\u{0}image", "file:///tmp/%00image", "file:///tmp/%GG"] {
      XCTAssertNil(SharePolicy.fileURL(value))
    }
  }

  func testFileAvailabilityRequiresReadableRegularFileWithinTenMiB() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("product-image.png")
    XCTAssertFalse(SharePolicy.fileIsAvailable(file))
    XCTAssertFalse(SharePolicy.fileIsAvailable(root))
    XCTAssertFalse(SharePolicy.fileIsAvailable(URL(string: "https://example.test/image")!))
    try Data(repeating: 1, count: SharePolicy.maximumFileBytes).write(to: file)
    XCTAssertTrue(SharePolicy.fileIsAvailable(file))
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
    XCTAssertFalse(SharePolicy.fileIsAvailable(file))
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    try Data(repeating: 1, count: SharePolicy.maximumFileBytes + 1).write(to: file)
    XCTAssertFalse(SharePolicy.fileIsAvailable(file))
    let link = root.appendingPathComponent("link.png")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    XCTAssertFalse(SharePolicy.fileIsAvailable(link))
  }

  func testAnchorRequiresExactFinitePositiveValuesAndHostContainment() throws {
    XCTAssertNil(SharePolicy.parse(["text": "hello"]))
    let invalid: [[String: Any]] = [[:], ["x": 0, "y": 0, "width": 1],
      ["x": -1, "y": 0, "width": 1, "height": 1],
      ["x": 0, "y": 0, "width": 0, "height": 1],
      ["x": 0, "y": 0, "width": 1, "height": -1],
      ["x": true, "y": 0, "width": 1, "height": 1],
      ["x": Double.nan, "y": 0, "width": 1, "height": 1],
      ["x": 0, "y": 0, "width": Double.infinity, "height": 1],
      ["x": Double.greatestFiniteMagnitude, "y": 0,
        "width": Double.greatestFiniteMagnitude, "height": 1],
      ["x": 0, "y": 0, "width": 1, "height": 1, "extra": 0]]
    for bad in invalid {
      XCTAssertNil(SharePolicy.anchor(bad))
    }
    let anchor = try XCTUnwrap(SharePolicy.anchor(rect))
    XCTAssertTrue(SharePolicy.anchorFits(anchor, bounds: CGRect(x: 0, y: 0, width: 20, height: 11)))
    XCTAssertFalse(SharePolicy.anchorFits(anchor, bounds: CGRect(x: 0, y: 0, width: 19, height: 11)))
    XCTAssertFalse(SharePolicy.anchorFits(anchor, bounds: .zero))
  }

  func testOutcomeWireIsFixedAndCompletionDoesNotImplyDelivery() {
    let expected = [
      ["kind": "completed", "code": "share.completed"],
      ["kind": "cancelled", "code": "share.cancelled"],
      ["kind": "invalid", "code": "share.invalid_payload"],
      ["kind": "unavailable", "code": "share.host_unavailable"],
      ["kind": "unavailable", "code": "share.file_unavailable"],
      ["kind": "conflict", "code": "share.operation_in_progress"],
      ["kind": "cancelled", "code": "share.engine_detached"],
      ["kind": "failure", "code": "share.platform_failure"],
    ]
    XCTAssertEqual(ShareOutcome.allCases.map(\.wire), expected)
    XCTAssertEqual(SharePolicy.completion(completed: true, failed: false), .completed)
    XCTAssertEqual(SharePolicy.completion(completed: false, failed: false), .cancelled)
    XCTAssertEqual(SharePolicy.completion(completed: true, failed: true), .platformFailure)
    XCTAssertEqual(SharePolicy.completion(completed: false, failed: true), .platformFailure)
  }

  func testSettlementIsAtMostOnceAndClearsCallbackBeforeReentrancy() {
    var calls: [[String: String]] = []
    var operation: ShareOperation?
    operation = ShareOperation { response in
      calls.append(response)
      operation?.settle(.platformFailure)
    }
    operation?.settle(.engineDetached)
    operation?.settle(.completed)
    XCTAssertEqual(calls, [ShareOutcome.engineDetached.wire])
    operation = nil
  }
}
