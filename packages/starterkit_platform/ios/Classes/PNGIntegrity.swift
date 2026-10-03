import Darwin
import Foundation
import zlib

/// Strict, bounded validation of PNG framing and its single RFC 1950 image stream.
enum PNGIntegrity {
  private static let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
  private static let outputChunkSize = 64 * 1024

  static func validate(
    _ data: Data, maxBytes: Int, maxPixels: Int, isCancelled: () -> Bool
  ) throws {
    guard data.count > 0 else { throw MediaFileError.empty }
    guard data.count <= maxBytes else { throw MediaFileError.tooLarge }
    guard data.count >= signature.count, Array(data.prefix(8)) == signature else {
      throw MediaFileError.invalidImage
    }

    var offset = 8
    var sawHeader = false
    var sawPalette = false
    var sawData = false
    var endedData = false
    var sawEnd = false
    var width = 0
    var height = 0
    var bitDepth: UInt8 = 0
    var colorType: UInt8 = 0
    var interlace: UInt8 = 0
    var inflater = PNGInflater()
    var expectedOutput = 0

    while offset < data.count {
      if isCancelled() { throw MediaFileError.cancelled }
      guard data.count - offset >= 12 else { throw MediaFileError.invalidImage }
      let length = Int(readUInt32(data, offset))
      let typeOffset = offset + 4
      let payloadOffset = offset + 8
      guard length <= data.count - payloadOffset - 4 else { throw MediaFileError.invalidImage }
      let crcOffset = payloadOffset + length
      let type = Array(data[typeOffset..<(typeOffset + 4)])
      guard type.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) }),
        type[2] & 0x20 == 0
      else { throw MediaFileError.invalidImage }
      var crc = zlib.crc32(0, nil, 0)
      var crcOffsetInChunk = typeOffset
      while crcOffsetInChunk < crcOffset {
        if isCancelled() { throw MediaFileError.cancelled }
        let end = min(crcOffsetInChunk + outputChunkSize, crcOffset)
        data[crcOffsetInChunk..<end].withUnsafeBytes { bytes in
          crc = zlib.crc32(crc, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(end - crcOffsetInChunk))
        }
        crcOffsetInChunk = end
      }
      guard UInt32(truncatingIfNeeded: crc) == readUInt32(data, crcOffset) else {
        throw MediaFileError.invalidImage
      }

      let isIDAT = type == Array("IDAT".utf8)
      if sawData && !isIDAT { endedData = true }
      if endedData && isIDAT { throw MediaFileError.invalidImage }

      switch String(bytes: type, encoding: .ascii) ?? "" {
      case "IHDR":
        guard !sawHeader, offset == 8, length == 13 else { throw MediaFileError.invalidImage }
        width = Int(readUInt32(data, payloadOffset))
        height = Int(readUInt32(data, payloadOffset + 4))
        bitDepth = data[payloadOffset + 8]
        colorType = data[payloadOffset + 9]
        let compression = data[payloadOffset + 10]
        let filter = data[payloadOffset + 11]
        interlace = data[payloadOffset + 12]
        guard width > 0, height > 0,
          validDepth(bitDepth, colorType: colorType), compression == 0, filter == 0,
          interlace <= 1
        else { throw MediaFileError.invalidImage }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= maxPixels else { throw MediaFileError.invalidDimensions }
        expectedOutput = try filteredByteCount(
          width: width, height: height, bitDepth: bitDepth, colorType: colorType,
          interlace: interlace
        )
        inflater.configure(width: width, height: height, bitDepth: bitDepth, colorType: colorType, interlace: interlace)
        sawHeader = true
      case "PLTE":
        guard sawHeader, !sawPalette, !sawData, length > 0, length <= 768, length % 3 == 0,
          colorType != 0, colorType != 4
        else { throw MediaFileError.invalidImage }
        if colorType == 3 { guard length / 3 <= (1 << bitDepth) else { throw MediaFileError.invalidImage } }
        sawPalette = true
      case "IDAT":
        guard sawHeader, colorType != 3 || sawPalette else { throw MediaFileError.invalidImage }
        sawData = true
        var inputOffset = payloadOffset
        while inputOffset < crcOffset {
          if isCancelled() { throw MediaFileError.cancelled }
          let end = min(inputOffset + outputChunkSize, crcOffset)
          try inflater.feed(data.subdata(in: inputOffset..<end), expected: expectedOutput, isCancelled: isCancelled)
          inputOffset = end
        }
        if length == 0 {
          try inflater.feed(Data(), expected: expectedOutput, isCancelled: isCancelled)
        }
      case "IEND":
        guard sawHeader, sawData, length == 0, !sawEnd else { throw MediaFileError.invalidImage }
        try inflater.finish(expected: expectedOutput)
        sawEnd = true
        offset = crcOffset + 4
        guard offset == data.count else { throw MediaFileError.invalidImage }
      default:
        guard sawHeader else { throw MediaFileError.invalidImage }
        // Ancillary chunks (lowercase first byte) are allowed; unknown critical chunks are not.
        guard type[0] & 0x20 != 0 else { throw MediaFileError.invalidImage }
        if sawData { endedData = true }
      }
      offset = crcOffset + 4
      if sawEnd { break }
    }
    guard sawEnd else { throw MediaFileError.invalidImage }
  }

  private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
    (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16)
      | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
  }

  private static func validDepth(_ depth: UInt8, colorType: UInt8) -> Bool {
    switch colorType {
    case 0: return [1, 2, 4, 8, 16].contains(depth)
    case 2: return depth == 8 || depth == 16
    case 3: return [1, 2, 4, 8].contains(depth)
    case 4, 6: return depth == 8 || depth == 16
    default: return false
    }
  }

  private static func filteredByteCount(
    width: Int, height: Int, bitDepth: UInt8, colorType: UInt8, interlace: UInt8
  ) throws -> Int {
    let channels: Int
    switch colorType { case 0, 3: channels = 1; case 2: channels = 3; case 4: channels = 2; default: channels = 4 }
    let passes: [(Int, Int, Int, Int)] = interlace == 0
      ? [(0, 0, 1, 1)]
      : [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
    var total = 0
    for (x0, y0, dx, dy) in passes where x0 < width && y0 < height {
      let passWidth = (width - x0 + dx - 1) / dx
      let passHeight = (height - y0 + dy - 1) / dy
      let (samples, sampleOverflow) = passWidth.multipliedReportingOverflow(by: channels)
      let (bits, bitOverflow) = samples.multipliedReportingOverflow(by: Int(bitDepth))
      guard !sampleOverflow, !bitOverflow, bits <= Int.max - 7 else { throw MediaFileError.invalidImage }
      let rowBytes = (bits + 7) / 8
      let (rowLength, rowOverflow) = rowBytes.addingReportingOverflow(1)
      let (passBytes, passOverflow) = rowLength.multipliedReportingOverflow(by: passHeight)
      let (newTotal, totalOverflow) = total.addingReportingOverflow(passBytes)
      guard !rowOverflow, !passOverflow, !totalOverflow else { throw MediaFileError.invalidImage }
      total = newTotal
    }
    return total
  }

  private final class PNGInflater {
    private var stream = z_stream()
    private var initialized = false
    private var ended = false
    private var produced = 0
    private var rowRemaining = 0
    private var needsFilter = true
    private let outputSize = PNGIntegrity.outputChunkSize
    private var output = [UInt8](repeating: 0, count: PNGIntegrity.outputChunkSize)
    private var rows: [(rowBytes: Int, rowCount: Int)] = []
    private var rowIndex = 0
    private var rowInPass = 0

    deinit { if initialized { _ = inflateEnd(&stream) } }

    func configure(width: Int, height: Int, bitDepth: UInt8, colorType: UInt8, interlace: UInt8) {
      let channels: Int
      switch colorType { case 0, 3: channels = 1; case 2: channels = 3; case 4: channels = 2; default: channels = 4 }
      let passes: [(Int, Int, Int, Int)] = interlace == 0
        ? [(0, 0, 1, 1)]
        : [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
      for (x0, y0, dx, dy) in passes where x0 < width && y0 < height {
        let passWidth = (width - x0 + dx - 1) / dx
        let passHeight = (height - y0 + dy - 1) / dy
        rows.append(((passWidth * channels * Int(bitDepth) + 7) / 8, passHeight))
      }
    }

    func feed(_ input: Data, expected: Int, isCancelled: () -> Bool) throws {
      if !initialized {
        guard inflateInit_(&stream, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
          throw MediaFileError.invalidImage
        }
        initialized = true
      }
      if ended && !input.isEmpty { throw MediaFileError.invalidImage }
      try input.withUnsafeBytes { inputBytes in
        guard let base = inputBytes.bindMemory(to: Bytef.self).baseAddress else { return }
        stream.next_in = UnsafeMutablePointer(mutating: base)
        stream.avail_in = uInt(input.count)
        while true {
          if isCancelled() { throw MediaFileError.cancelled }
          let previousInput = stream.avail_in
          let status: Int32 = output.withUnsafeMutableBytes { outputBytes in
            stream.next_out = outputBytes.bindMemory(to: Bytef.self).baseAddress
            stream.avail_out = uInt(outputBytes.count)
            return inflate(&stream, Z_NO_FLUSH)
          }
          let count = outputSize - Int(stream.avail_out)
          let consumed = previousInput - stream.avail_in
          try consume(output, count: count, expected: expected)
          if status == Z_STREAM_END {
            ended = true
            guard stream.avail_in == 0 else { throw MediaFileError.invalidImage }
            break
          }
          if status == Z_BUF_ERROR {
            // zlib uses BUF_ERROR when this fragment is exhausted but more IDAT input may follow.
            if stream.avail_in == 0 { break }
            guard count > 0 || consumed > 0 else { throw MediaFileError.invalidImage }
            continue
          }
          guard status == Z_OK else { throw MediaFileError.invalidImage }
          if count == 0 && consumed == 0 {
            // No input and no output means the next IDAT fragment is needed; never spin here.
            guard stream.avail_in == 0 else { throw MediaFileError.invalidImage }
            break
          }
          if stream.avail_in == 0 && stream.avail_out > 0 { break }
        }
      }
    }

    func finish(expected: Int) throws {
      guard ended, produced == expected, needsFilter, rowIndex == rows.count else { throw MediaFileError.invalidImage }
    }

    private func consume(_ bytes: [UInt8], count: Int, expected: Int) throws {
      guard count <= expected - produced else { throw MediaFileError.invalidImage }
      for byte in bytes.prefix(count) {
        if needsFilter {
          guard byte <= 4 else { throw MediaFileError.invalidImage }
          needsFilter = false
          guard rowIndex < rows.count else { throw MediaFileError.invalidImage }
          rowRemaining = rows[rowIndex].rowBytes
          if rowRemaining == 0 { advanceRow() }
        } else {
          rowRemaining -= 1
          if rowRemaining == 0 { advanceRow() }
        }
        produced += 1
      }
    }

    private func advanceRow() {
      rowInPass += 1
      needsFilter = true
      if rowIndex < rows.count, rowInPass == rows[rowIndex].rowCount {
        rowIndex += 1
        rowInPass = 0
      }
    }
  }
}
