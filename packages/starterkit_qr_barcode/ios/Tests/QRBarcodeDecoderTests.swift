import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import XCTest
@testable import StarterkitQrBarcodeNative

final class QRBarcodeDecoderTests: XCTestCase {
  func testProductionImageIOAndVisionDecodeGeneratedQRFixture() throws {
    let encoded = try qrPNG("  SwiftPM actual Vision round trip: π / QR  ")
    let results = try QRBarcodeDecoder().decode(encoded)
    XCTAssertEqual(
      results,
      [QRBarcodeObservation(value: "  SwiftPM actual Vision round trip: π / QR  ", format: "QR")]
    )
  }

  func testByteAndDimensionBounds() throws {
    XCTAssertThrowsError(try QRBarcodePolicy.validateEncodedBytes(Data())) {
      XCTAssertEqual($0 as? QRBarcodeFailure, .invalidImage)
    }
    XCTAssertNoThrow(try QRBarcodePolicy.validateEncodedBytes(Data([1])))
    XCTAssertNoThrow(
      try QRBarcodePolicy.validateEncodedBytes(Data(repeating: 0, count: 10 * 1024 * 1024))
    )
    XCTAssertThrowsError(
      try QRBarcodePolicy.validateEncodedBytes(Data(repeating: 0, count: 10 * 1024 * 1024 + 1))
    ) { XCTAssertEqual($0 as? QRBarcodeFailure, .tooLarge) }
    XCTAssertNoThrow(try QRBarcodePolicy.validateDimensions(width: 1, height: 4096))
    XCTAssertNoThrow(try QRBarcodePolicy.validateDimensions(width: 4096, height: 1))
    for (width, height) in [(0, 1), (4097, 1), (1, 4097)] {
      XCTAssertThrowsError(try QRBarcodePolicy.validateDimensions(width: width, height: height)) {
        XCTAssertEqual($0 as? QRBarcodeFailure, .dimensions)
      }
    }
  }

  func testSymbologyContainmentAndSimulatorWorkaroundPolicy() {
    XCTAssertTrue(QRBarcodePolicy.supportedHost([.qr, .ean13, .code128, .aztec]))
    XCTAssertFalse(QRBarcodePolicy.supportedHost([.qr, .ean13]))
    XCTAssertTrue(QRBarcodePolicy.revisionOneWorkaround(isSimulator: true))
    XCTAssertFalse(QRBarcodePolicy.revisionOneWorkaround(isSimulator: false))
    XCTAssertEqual(QRBarcodePolicy.requiredSymbologies, [.qr, .ean13, .code128])
  }

  func testNormalizationPreservesTextAndRejectsInvalidFormatsControlsAndLimits() throws {
    let text = "  exact text π  "
    XCTAssertEqual(
      try QRBarcodePolicy.normalize([QRBarcodeObservation(value: text, format: "qr")]),
      [QRBarcodeObservation(value: text, format: "QR")]
    )
    XCTAssertEqual(
      try QRBarcodePolicy.normalize([
        QRBarcodeObservation(value: "123456789012", format: "ean13"),
        QRBarcodeObservation(value: "CODE128", format: "code128"),
      ]),
      [
        QRBarcodeObservation(value: "123456789012", format: "EAN13"),
        QRBarcodeObservation(value: "CODE128", format: "Code128"),
      ]
    )
    for control in ["\u{0000}", "\u{001f}", "\u{007f}", "\u{009f}"] {
      XCTAssertThrowsError(
        try QRBarcodePolicy.normalize([QRBarcodeObservation(value: "a\(control)b", format: "QR")])
      ) { XCTAssertEqual($0 as? QRBarcodeFailure, .invalidPayload) }
    }
    XCTAssertThrowsError(
      try QRBarcodePolicy.normalize([QRBarcodeObservation(value: "x", format: "AZTEC")])
    ) { XCTAssertEqual($0 as? QRBarcodeFailure, .invalidPayload) }
    XCTAssertNoThrow(
      try QRBarcodePolicy.normalize([
        QRBarcodeObservation(value: String(repeating: "é", count: 1024), format: "QR")
      ])
    )
    XCTAssertThrowsError(
      try QRBarcodePolicy.normalize([
        QRBarcodeObservation(value: String(repeating: "é", count: 1025), format: "QR")
      ])
    ) { XCTAssertEqual($0 as? QRBarcodeFailure, .invalidPayload) }
    XCTAssertEqual(
      try QRBarcodePolicy.normalize(
        (0..<16).map { _ in QRBarcodeObservation(value: String(repeating: "x", count: 2048), format: "QR") }
      ).count,
      16
    )
    XCTAssertThrowsError(
      try QRBarcodePolicy.normalize(
        (0..<17).map { _ in QRBarcodeObservation(value: "x", format: "QR") }
      )
    ) { XCTAssertEqual($0 as? QRBarcodeFailure, .invalidPayload) }
    XCTAssertThrowsError(
      try QRBarcodePolicy.normalize(
        (0..<16).map { _ in QRBarcodeObservation(value: String(repeating: "x", count: 2048), format: "QR") }
          + [QRBarcodeObservation(value: "x", format: "QR")]
      )
    ) { XCTAssertEqual($0 as? QRBarcodeFailure, .invalidPayload) }
  }

  func testEmptyObservationsProduceNoResultWithoutHidingInvalidNonemptyPayloads() throws {
    let empty = QRBarcodeObservation(value: "", format: "QR")
    XCTAssertEqual(try QRBarcodePolicy.normalize([]), [])
    XCTAssertEqual(try QRBarcodePolicy.normalize([empty]), [])
    XCTAssertEqual(try QRBarcodePolicy.normalize(Array(repeating: empty, count: 17)), [])
    let valid = QRBarcodeObservation(value: " π ", format: "QR")
    XCTAssertEqual(try QRBarcodePolicy.normalize([empty, valid]), [valid])
    let outcome = QRBarcodeOutcome.decode { [empty] }
    XCTAssertEqual(outcome["kind"] as? String, "noResult")
    XCTAssertEqual(outcome["code"] as? String, "qr.no_result")
    XCTAssertEqual(Set(outcome.keys), ["kind", "code"])
    XCTAssertThrowsError(
      try QRBarcodePolicy.normalize([empty, QRBarcodeObservation(value: "bad\n", format: "QR")])
    ) { XCTAssertEqual($0 as? QRBarcodeFailure, .invalidPayload) }
  }

  func testNewlinePayloadIsExplicitlyRejectedIncludingProductionVisionFixture() throws {
    let invalid = QRBarcodeObservation(value: "  exact text\nπ  ", format: "QR")
    XCTAssertThrowsError(try QRBarcodePolicy.normalize([invalid])) {
      XCTAssertEqual($0 as? QRBarcodeFailure, .invalidPayload)
    }
    let encoded = try qrPNG(invalid.value)
    XCTAssertThrowsError(try QRBarcodeDecoder().decode(encoded)) {
      XCTAssertEqual($0 as? QRBarcodeFailure, .invalidPayload)
    }
    let outcome = QRBarcodeOutcome.decode { [invalid] }
    XCTAssertEqual(outcome["kind"] as? String, "invalid")
    XCTAssertEqual(outcome["code"] as? String, "qr.invalid_payload")
  }

  func testCorruptEncodedImageFailsClosed() {
    XCTAssertThrowsError(try QRBarcodeDecoder().decode(Data(repeating: 0x41, count: 64)))
  }

  private func qrPNG(_ text: String) throws -> Data {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let generated = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else {
      throw FixtureError.generation
    }
    // Four modules of white quiet zone make this a standards-shaped QR fixture,
    // not a detector-specific crop. Both positive and rejected payloads use it.
    let background = CIImage(color: CIColor.white).cropped(
      to: generated.extent.insetBy(dx: -40, dy: -40)
    )
    let image = generated.composited(over: background)
    let context = CIContext()
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let png = context.pngRepresentation(of: image, format: .RGBA8, colorSpace: colorSpace)
    else { throw FixtureError.encoding }
    return png
  }

  private enum FixtureError: Error { case generation, encoding }
}
