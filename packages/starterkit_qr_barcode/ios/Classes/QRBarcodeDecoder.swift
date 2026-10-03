import CoreGraphics
import Foundation
import ImageIO
import Vision

enum QRBarcodeFailure: Error, Equatable {
  case invalidImage
  case tooLarge
  case dimensions
  case invalidPayload
  case unavailable
  case decode
}

struct QRBarcodeObservation: Equatable {
  let value: String
  let format: String
}

enum QRBarcodePolicy {
  static let maximumBytes = 10 * 1024 * 1024
  static let maximumDimension = 4096
  static let maximumPayloadBytes = 2048
  static let maximumObservations = 16
  static let maximumAggregateBytes = 32768
  static let requiredSymbologies: Set<VNBarcodeSymbology> = [
    .qr, .ean13, .code128,
  ]

  static func validateEncodedBytes(_ data: Data) throws {
    guard !data.isEmpty else { throw QRBarcodeFailure.invalidImage }
    guard data.count <= maximumBytes else { throw QRBarcodeFailure.tooLarge }
  }

  static func validateDimensions(width: Int, height: Int) throws {
    guard (1...maximumDimension).contains(width),
      (1...maximumDimension).contains(height)
    else { throw QRBarcodeFailure.dimensions }
  }

  static func supportedHost(_ symbologies: [VNBarcodeSymbology]) -> Bool {
    requiredSymbologies.isSubset(of: Set(symbologies))
  }

  static func revisionOneWorkaround(isSimulator: Bool) -> Bool { isSimulator }

  static func normalize(_ observations: [QRBarcodeObservation]) throws -> [QRBarcodeObservation] {
    var aggregateBytes = 0
    var accepted: [QRBarcodeObservation] = []
    accepted.reserveCapacity(min(observations.count, maximumObservations))
    for observation in observations {
      // Vision's missing/empty payloads are not codes; nonempty invalid payloads
      // still fail closed. Unknown formats are filtered by the Vision adapter,
      // but unexpected formats reaching this safety boundary are rejected.
      guard !observation.value.isEmpty else { continue }
      guard let format = canonicalFormat(observation.format),
        let data = observation.value.data(using: .utf8),
        let roundTrip = String(data: data, encoding: .utf8), roundTrip == observation.value,
        data.count <= maximumPayloadBytes,
        !observation.value.unicodeScalars.contains(where: isForbiddenControl)
      else { throw QRBarcodeFailure.invalidPayload }
      guard accepted.count < maximumObservations,
        data.count <= maximumAggregateBytes - aggregateBytes
      else {
        throw QRBarcodeFailure.invalidPayload
      }
      aggregateBytes += data.count
      accepted.append(QRBarcodeObservation(value: observation.value, format: format))
    }
    return accepted
  }

  private static func canonicalFormat(_ value: String) -> String? {
    switch value {
    case "qr", "QR": return "QR"
    case "ean13", "EAN13": return "EAN13"
    case "code128", "Code128": return "Code128"
    default: return nil
    }
  }

  private static func isForbiddenControl(_ scalar: Unicode.Scalar) -> Bool {
    (scalar.value <= 0x1f) || (0x7f...0x9f).contains(scalar.value)
  }
}

/// Flutter-independent production decoder shared verbatim with macOS SwiftPM tests.
struct QRBarcodeDecoder {
  func decode(_ data: Data) throws -> [QRBarcodeObservation] {
    try QRBarcodePolicy.validateEncodedBytes(data)
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) == 1,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
    else { throw QRBarcodeFailure.invalidImage }
    try QRBarcodePolicy.validateDimensions(width: width, height: height)
    guard CGImageSourceGetStatus(source) == .statusComplete,
      CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
      let image = CGImageSourceCreateImageAtIndex(
        source, 0, [kCGImageSourceShouldCache: false] as CFDictionary
      )
    else { throw QRBarcodeFailure.invalidImage }

    let request = try Self.makeBarcodeRequest()
    do {
      let handler = VNImageRequestHandler(cgImage: image, options: [:])
      try handler.perform([request])
    } catch {
      throw QRBarcodeFailure.decode
    }
    let observations = (request.results ?? []).compactMap { result -> QRBarcodeObservation? in
      guard let value = result.payloadStringValue else { return nil }
      let format: String
      switch result.symbology {
      case .qr: format = "QR"
      case .ean13: format = "EAN13"
      case .code128: format = "Code128"
      default: return nil
      }
      return QRBarcodeObservation(value: value, format: format)
    }
    guard !observations.isEmpty else { return [] }
    return try QRBarcodePolicy.normalize(observations)
  }

  private static func makeBarcodeRequest() throws -> VNDetectBarcodesRequest {
    let request = VNDetectBarcodesRequest()
    if QRBarcodePolicy.revisionOneWorkaround(isSimulator: isSimulator) {
      request.revision = VNDetectBarcodesRequestRevision1
      request.usesCPUOnly = true
    }
    let supported: [VNBarcodeSymbology]
    if #available(iOS 15.0, macOS 12.0, *) {
      do {
        supported = try request.supportedSymbologies()
      } catch {
        throw QRBarcodeFailure.unavailable
      }
    } else {
      // The instance API starts at iOS 15; keep the pod's iOS 13 floor using
      // Vision's documented class property on earlier systems.
      supported = VNDetectBarcodesRequest.supportedSymbologies
    }
    guard QRBarcodePolicy.supportedHost(supported) else { throw QRBarcodeFailure.unavailable }
    request.symbologies = [.qr, .ean13, .code128]
    return request
  }

  private static var isSimulator: Bool {
    #if targetEnvironment(simulator)
      true
    #else
      false
    #endif
  }
}
