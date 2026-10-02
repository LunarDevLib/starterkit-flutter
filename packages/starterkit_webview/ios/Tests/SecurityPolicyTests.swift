import XCTest
@testable import StarterkitWebViewNativePolicy

final class SecurityPolicyTests: XCTestCase {
  func testTrustedOriginRejectsAmbiguousInput() {
    XCTAssertNil(TrustedOrigin(configured: "http://example.com"))
    XCTAssertNil(TrustedOrigin(configured: "https://example.com/path"))
    XCTAssertNil(TrustedOrigin(configured: "https://example.com:"))
    XCTAssertNil(TrustedOrigin(configured: "https://user@example.com"))
  }

  func testExactPortAndNavigationPolicy() throws {
    let origin = try XCTUnwrap(TrustedOrigin(configured: "https://example.com:8443"))
    XCTAssertTrue(origin.matches(try XCTUnwrap(URL(string: "https://example.com:8443/a"))))
    XCTAssertFalse(origin.matches(try XCTUnwrap(URL(string: "https://example.com/a"))))

    let policy = NavigationPolicy(
      trustedOrigin: origin,
      externalSchemes: Set(["mailto"])
    )
    XCTAssertEqual(
      policy.decide(
        try XCTUnwrap(URL(string: "https://outside.example")),
        isMainFrame: true,
        linkActivated: true
      ),
      .externalBrowser
    )
    XCTAssertEqual(
      policy.decide(
        try XCTUnwrap(URL(string: "http://example.com")),
        isMainFrame: true,
        linkActivated: true
      ),
      .blocked
    )
  }

  func testBridgeValidatorIsBounded() {
    XCTAssertNotNil(
      BridgeRequestValidator.validate([
        "version": 1,
        "id": "one",
        "method": "app.getVersion",
        "params": [:] as [String: Any],
      ])
    )
    XCTAssertNil(
      BridgeRequestValidator.validate([
        "version": true,
        "id": "one",
        "method": "app.getVersion",
        "params": [:] as [String: Any],
      ])
    )
  }
}
