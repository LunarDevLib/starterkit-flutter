import Foundation
import XCTest
import zlib
@testable import StarterkitPlatformPolicy

final class PNGIntegrityTests: XCTestCase {
  func testValidRGBRGBAGrayscaleAndIndexedStreams() throws {
    for colorType in [UInt8(0), 2, 3, 6] {
      let png = try makePNG(width: 3, height: 2, colorType: colorType)
      try assertValid(png, maxPixels: 6)
    }
  }

  func testValidSplitIDATHandlesHeaderTokenTrailerAndEmptyChunks() throws {
    let png = try makePNG(
      width: 7, height: 5, colorType: 2, splitAfterZlibHeader: true, emptyIDATAfterFirst: true
    )
    try assertValid(png, maxPixels: 35)
  }

  func testValidAdam7UsesExactSevenPassRows() throws {
    try assertValid(try makePNG(width: 11, height: 10, colorType: 6, interlace: 1), maxPixels: 110)
  }

  func testValidOutputAtAndAcross64KiBBoundaries() throws {
    try assertValid(try makePNG(width: 32_767, height: 2, colorType: 0), maxPixels: 65_534)
    try assertValid(try makePNG(width: 32_768, height: 2, colorType: 0), maxPixels: 65_536)
  }

  func testRejectsCRCTruncationChunkOrderInvalidZlibAndTrailingCompressedData() throws {
    let valid = try makePNG(width: 2, height: 2, colorType: 2)
    var badCRC = valid
    let idatCRCOffset = try chunkCRCOffset(in: badCRC, type: "IDAT")
    badCRC[idatCRCOffset] ^= 0x01
    assertInvalid(badCRC)

    assertInvalid(Data(valid.dropLast(12)))
    assertInvalid(try makePNG(width: 1, height: 1, colorType: 3, paletteAfterIDAT: true))
    assertInvalid(try makePNG(width: 1, height: 1, colorType: 2, compressedOverride: Data([0, 1, 2])))

    let compressed = try compress(filteredRows(width: 2, height: 2, colorType: 2, interlace: 0))
    assertInvalid(try makePNG(width: 2, height: 2, colorType: 2, compressedOverride: Data(compressed.dropLast())))
    assertInvalid(try makePNG(width: 2, height: 2, colorType: 2, compressedOverride: compressed + Data([0x7f])))
  }

  func testRejectsExcessShortRowsInvalidFilterAndPixelLimit() throws {
    let expected = try filteredRows(width: 2, height: 1, colorType: 2, interlace: 0)
    assertInvalid(try makePNG(width: 2, height: 1, colorType: 2, rawOverride: expected + Data([0])))
    assertInvalid(try makePNG(width: 2, height: 1, colorType: 2, rawOverride: Data([0, 0, 0])))
    assertInvalid(try makePNG(width: 1, height: 1, colorType: 2, rawOverride: Data([5, 0, 0, 0])))
    let twoPixels = try makePNG(width: 2, height: 1, colorType: 2)
    XCTAssertThrowsError(
      try PNGIntegrity.validate(twoPixels, maxBytes: twoPixels.count, maxPixels: 1, isCancelled: { false })
    ) { XCTAssertEqual($0 as? MediaFileError, .invalidDimensions) }
    XCTAssertThrowsError(
      try PNGIntegrity.validate(
        twoPixels, maxBytes: twoPixels.count - 1, maxPixels: 2, isCancelled: { false }
      )
    ) { XCTAssertEqual($0 as? MediaFileError, .tooLarge) }
  }

  func testCancellationStopsProductionValidator() throws {
    let png = try makePNG(width: 1, height: 1, colorType: 2)
    XCTAssertThrowsError(
      try PNGIntegrity.validate(png, maxBytes: png.count, maxPixels: 1, isCancelled: { true })
    ) { XCTAssertEqual($0 as? MediaFileError, .cancelled) }

    let largePNG = try makePNG(width: 32_767, height: 3, colorType: 0)
    var checks = 0
    XCTAssertThrowsError(
      try PNGIntegrity.validate(
        largePNG, maxBytes: largePNG.count, maxPixels: 100_000,
        isCancelled: { checks += 1; return checks >= 7 }
      )
    ) { XCTAssertEqual($0 as? MediaFileError, .cancelled) }
  }

  private func assertValid(_ png: Data, maxPixels: Int) throws {
    XCTAssertNoThrow(
      try PNGIntegrity.validate(png, maxBytes: png.count, maxPixels: maxPixels, isCancelled: { false })
    )
  }

  private func assertInvalid(_ png: Data, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(
      try PNGIntegrity.validate(png, maxBytes: png.count, maxPixels: 100_000, isCancelled: { false }),
      file: file, line: line
    )
  }

  private func makePNG(
    width: Int,
    height: Int,
    colorType: UInt8,
    interlace: UInt8 = 0,
    splitAfterZlibHeader: Bool = false,
    emptyIDATAfterFirst: Bool = false,
    paletteAfterIDAT: Bool = false,
    rawOverride: Data? = nil,
    compressedOverride: Data? = nil
  ) throws -> Data {
    let raw = rawOverride ?? filteredRows(width: width, height: height, colorType: colorType, interlace: interlace)
    let compressed = try compressedOverride ?? compress(raw)
    var ihdr = Data()
    ihdr.append(be32(UInt32(width)))
    ihdr.append(be32(UInt32(height)))
    ihdr.append(contentsOf: [8, colorType, 0, 0, interlace])

    var png = Data([137, 80, 78, 71, 13, 10, 26, 10])
    png.append(chunk("IHDR", ihdr))
    let palette: Data? = colorType == 3 ? Data([0, 0, 0]) : nil
    if let palette, !paletteAfterIDAT { png.append(chunk("PLTE", palette)) }

    var parts: [Data] = []
    if splitAfterZlibHeader, compressed.count > 2 {
      parts.append(Data(compressed.prefix(2)))
      parts.append(contentsOf: compressed.dropFirst(2).map { Data([$0]) })
    } else {
      parts = [compressed]
    }
    for (index, part) in parts.enumerated() {
      png.append(chunk("IDAT", part))
      if index == 0, emptyIDATAfterFirst { png.append(chunk("IDAT", Data())) }
    }
    if let palette, paletteAfterIDAT { png.append(chunk("PLTE", palette)) }
    png.append(chunk("IEND", Data()))
    return png
  }

  private func filteredRows(width: Int, height: Int, colorType: UInt8, interlace: UInt8) -> Data {
    let channels: Int
    switch colorType { case 0, 3: channels = 1; case 2: channels = 3; case 4: channels = 2; default: channels = 4 }
    let passes: [(Int, Int, Int, Int)] = interlace == 0
      ? [(0, 0, 1, 1)]
      : [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
    var result = Data()
    for (x0, y0, dx, dy) in passes where x0 < width && y0 < height {
      let passWidth = (width - x0 + dx - 1) / dx
      let passHeight = (height - y0 + dy - 1) / dy
      // All fixtures use bit depth 8, so each channel sample occupies one byte.
      let rowBytes = passWidth * channels
      for _ in 0..<passHeight {
        result.append(0)
        result.append(contentsOf: repeatElement(UInt8(0), count: rowBytes))
      }
    }
    return result
  }

  private func compress(_ source: Data) throws -> Data {
    var outputLength = uLongf(compressBound(uLong(source.count)))
    var output = [UInt8](repeating: 0, count: Int(outputLength))
    let status = source.withUnsafeBytes { sourceBytes in
      output.withUnsafeMutableBufferPointer { destination in
        compress2(
          destination.baseAddress!, &outputLength,
          sourceBytes.bindMemory(to: Bytef.self).baseAddress!, uLong(source.count), Z_DEFAULT_COMPRESSION
        )
      }
    }
    guard status == Z_OK else { throw MediaFileError.invalidImage }
    return Data(output.prefix(Int(outputLength)))
  }

  private func chunk(_ type: String, _ payload: Data) -> Data {
    let typeAndPayload = Data(type.utf8) + payload
    var result = be32(UInt32(payload.count))
    result.append(typeAndPayload)
    var crc = zlib.crc32(0, nil, 0)
    typeAndPayload.withUnsafeBytes { bytes in
      crc = zlib.crc32(crc, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count))
    }
    result.append(be32(UInt32(truncatingIfNeeded: crc)))
    return result
  }

  private func chunkCRCOffset(in png: Data, type wanted: String) throws -> Int {
    var offset = 8
    while offset + 12 <= png.count {
      let length = Int(png[offset]) << 24 | Int(png[offset + 1]) << 16
        | Int(png[offset + 2]) << 8 | Int(png[offset + 3])
      let type = String(data: png[(offset + 4)..<(offset + 8)], encoding: .ascii)
      if type == wanted { return offset + 8 + length }
      offset += 12 + length
    }
    throw MediaFileError.invalidImage
  }

  private func be32(_ value: UInt32) -> Data {
    Data([UInt8(value >> 24), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)])
  }
}
