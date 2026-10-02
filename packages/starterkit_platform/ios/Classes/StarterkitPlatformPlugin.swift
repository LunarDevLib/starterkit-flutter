import AVFoundation
import Flutter
import ImageIO
import PhotosUI
import UIKit

public final class StarterkitPlatformPlugin: NSObject, FlutterPlugin,
  UIImagePickerControllerDelegate, UINavigationControllerDelegate
{
  private var channel: FlutterMethodChannel?
  private var pending: PendingOperation?
  private var galleryDelegate: AnyObject?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = StarterkitPlatformPlugin()
    let channel = FlutterMethodChannel(
      name: "starterkit/platform/media",
      binaryMessenger: registrar.messenger()
    )
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "cameraAvailability":
      result(UIImagePickerController.isSourceTypeAvailable(.camera))
    case "cameraPermissionStatus":
      result(cameraPermissionStatus())
    case "requestCameraPermission":
      requestCameraPermission(result)
    case "galleryAvailability":
      if #available(iOS 14.0, *) {
        result(true)
      } else {
        result(false)
      }
    case "captureCamera":
      captureCamera(call.arguments as? [String: Any], result: result)
    case "pickGalleryImage":
      pickGallery(call.arguments as? [String: Any], result: result)
    case "cleanupMedia":
      let path = (call.arguments as? [String: Any])?["path"] as? String
      result(path.map(cleanupOwned) ?? false)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func cameraPermissionStatus() -> String {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: return "granted"
    case .notDetermined: return "notDetermined"
    case .denied: return "denied"
    case .restricted: return "restricted"
    @unknown default: return "unavailable"
    }
  }

  private func requestCameraPermission(_ result: @escaping FlutterResult) {
    guard hasCameraUsageDescription else {
      result("unavailable")
      return
    }
    let status = AVCaptureDevice.authorizationStatus(for: .video)
    guard status == .notDetermined else {
      result(cameraPermissionStatus())
      return
    }
    AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
      DispatchQueue.main.async {
        result(self?.cameraPermissionStatus() ?? "unavailable")
      }
    }
  }

  private func captureCamera(
    _ arguments: [String: Any]?,
    result: @escaping FlutterResult
  ) {
    guard pending == nil else {
      result(mediaOutcome("failure", "media.operation_in_progress"))
      return
    }
    guard let limits = MediaLimits.parse(arguments) else {
      result(mediaOutcome("invalid", "media.invalid_limits"))
      return
    }
    guard hasCameraUsageDescription else {
      result(mediaOutcome("unavailable", "camera.usage_description_missing"))
      return
    }
    guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
      result(mediaOutcome("unavailable", "camera.unavailable"))
      return
    }
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      break
    case .denied, .restricted:
      result(mediaOutcome("denied", "camera.permission_denied"))
      return
    case .notDetermined:
      result(mediaOutcome("denied", "camera.permission_not_requested"))
      return
    @unknown default:
      result(mediaOutcome("unavailable", "camera.permission_unavailable"))
      return
    }
    guard let host = topViewController(), host.presentedViewController == nil else {
      result(mediaOutcome("unavailable", "camera.presentation_unavailable"))
      return
    }

    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.mediaTypes = ["public.image"]
    picker.cameraCaptureMode = .photo
    picker.delegate = self
    pending = PendingOperation(kind: .camera, result: result, limits: limits)
    host.present(picker, animated: true)
  }

  private func pickGallery(
    _ arguments: [String: Any]?,
    result: @escaping FlutterResult
  ) {
    guard pending == nil else {
      result(mediaOutcome("failure", "media.operation_in_progress"))
      return
    }
    guard let limits = MediaLimits.parse(arguments) else {
      result(mediaOutcome("invalid", "media.invalid_limits"))
      return
    }
    guard #available(iOS 14.0, *) else {
      result(mediaOutcome("unavailable", "gallery.requires_ios14"))
      return
    }
    guard let host = topViewController(), host.presentedViewController == nil else {
      result(mediaOutcome("unavailable", "gallery.presentation_unavailable"))
      return
    }

    var configuration = PHPickerConfiguration(photoLibrary: .shared())
    configuration.filter = .images
    configuration.selectionLimit = 1
    let picker = PHPickerViewController(configuration: configuration)
    let delegate = GalleryPickerDelegate { [weak self] selected in
      self?.handleGallerySelection(selected)
    }
    galleryDelegate = delegate
    picker.delegate = delegate
    pending = PendingOperation(kind: .gallery, result: result, limits: limits)
    host.present(picker, animated: true)
  }

  public func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true)
    finishPending(mediaOutcome("cancelled", "camera.cancelled"))
  }

  public func imagePickerController(
    _ picker: UIImagePickerController,
    didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
  ) {
    picker.dismiss(animated: true)
    guard let operation = pending, operation.kind == .camera else { return }
    pending = nil
    guard let image = info[.originalImage] as? UIImage else {
      operation.result(mediaOutcome("invalid", "camera.image_missing"))
      return
    }
    let width = image.cgImage?.width ?? Int(image.size.width * image.scale)
    let height = image.cgImage?.height ?? Int(image.size.height * image.scale)
    guard MediaPolicy.validDimensions(width: width, height: height, limits: operation.limits) else {
      operation.result(mediaOutcome("invalid", "media.invalid_dimensions"))
      return
    }

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      guard let data = image.jpegData(compressionQuality: 0.95) else {
        DispatchQueue.main.async {
          operation.result(mediaOutcome("failure", "camera.encode_failed"))
        }
        return
      }
      guard !data.isEmpty, data.count <= operation.limits.maxBytes else {
        DispatchQueue.main.async {
          operation.result(mediaOutcome("invalid", "media.too_large"))
        }
        return
      }
      let destination = self.newTempURL(prefix: "camera", extension: "jpg")
      do {
        try data.write(to: destination, options: .atomic)
        let metadata = MediaMetadata(
          path: destination.path,
          byteLength: data.count,
          width: width,
          height: height,
          mimeType: "image/jpeg"
        )
        DispatchQueue.main.async {
          operation.result(mediaOutcome("success", "media.success", image: metadata))
        }
      } catch {
        try? FileManager.default.removeItem(at: destination)
        DispatchQueue.main.async {
          operation.result(mediaOutcome("failure", "camera.write_failed"))
        }
      }
    }
  }

  @available(iOS 14.0, *)
  private func handleGallerySelection(_ selected: PHPickerResult?) {
    guard let operation = pending, operation.kind == .gallery else { return }
    pending = nil
    galleryDelegate = nil
    guard let selected else {
      operation.result(mediaOutcome("cancelled", "gallery.cancelled"))
      return
    }
    let provider = selected.itemProvider
    guard provider.hasItemConformingToTypeIdentifier("public.image") else {
      operation.result(mediaOutcome("invalid", "gallery.invalid_type"))
      return
    }
    provider.loadFileRepresentation(forTypeIdentifier: "public.image") {
      [weak self] source, error in
      guard let self else { return }
      guard error == nil, let source else {
        DispatchQueue.main.async {
          operation.result(mediaOutcome("failure", "gallery.read_failed"))
        }
        return
      }
      let outcome = self.copyAndValidateGallery(source, limits: operation.limits)
      DispatchQueue.main.async { operation.result(outcome) }
    }
  }

  @available(iOS 14.0, *)
  private func copyAndValidateGallery(_ source: URL, limits: MediaLimits) -> [String: Any] {
    guard source.isFileURL else {
      return mediaOutcome("invalid", "gallery.invalid_file")
    }
    let attributes = try? FileManager.default.attributesOfItem(atPath: source.path)
    guard let size = (attributes?[.size] as? NSNumber)?.intValue, size > 0 else {
      return mediaOutcome("invalid", "gallery.empty_file")
    }
    guard size <= limits.maxBytes else {
      return mediaOutcome("invalid", "media.too_large")
    }
    guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)
        as? [CFString: Any],
      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
      MediaPolicy.validDimensions(width: width, height: height, limits: limits)
    else {
      return mediaOutcome("invalid", "media.invalid_dimensions")
    }

    guard let typeIdentifier = CGImageSourceGetType(imageSource) as String?,
      let mime = Self.mimeType(for: typeIdentifier),
      mime.utf8.count <= 128
    else {
      return mediaOutcome("invalid", "media.invalid_type")
    }

    let fileExtension = source.pathExtension.isEmpty ? "image" : source.pathExtension
    let destination = newTempURL(prefix: "gallery", extension: fileExtension)
    do {
      try FileManager.default.copyItem(at: source, to: destination)
      return mediaOutcome(
        "success",
        "media.success",
        image: MediaMetadata(
          path: destination.path,
          byteLength: size,
          width: width,
          height: height,
          mimeType: mime
        )
      )
    } catch {
      try? FileManager.default.removeItem(at: destination)
      return mediaOutcome("failure", "gallery.copy_failed")
    }
  }

  private static func mimeType(for typeIdentifier: String) -> String? {
    switch typeIdentifier {
    case "public.jpeg": return "image/jpeg"
    case "public.png": return "image/png"
    case "public.heic", "public.heif": return "image/heic"
    case "com.compuserve.gif": return "image/gif"
    case "public.tiff": return "image/tiff"
    case "com.microsoft.bmp": return "image/bmp"
    default: return nil
    }
  }

  private var hasCameraUsageDescription: Bool {
    guard let text = Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String
    else { return false }
    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func mediaRoot() -> URL {
    let root =
      FileManager.default.temporaryDirectory
      .appendingPathComponent("starterkit_media", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    return root
  }

  private func newTempURL(prefix: String, extension fileExtension: String) -> URL {
    mediaRoot().appendingPathComponent(
      prefix + "-" + UUID().uuidString + "." + fileExtension
    )
  }

  private func cleanupOwned(_ path: String) -> Bool {
    let candidate = URL(fileURLWithPath: path)
    guard MediaPolicy.owns(root: mediaRoot(), candidate: candidate) else { return false }
    guard FileManager.default.fileExists(atPath: candidate.path) else { return true }
    do {
      try FileManager.default.removeItem(at: candidate)
      return true
    } catch {
      return false
    }
  }

  private func finishPending(_ outcome: [String: Any]) {
    guard let operation = pending else { return }
    pending = nil
    galleryDelegate = nil
    operation.result(outcome)
  }

  private func topViewController() -> UIViewController? {
    let window =
      UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
      .flatMap(\.windows)
      .first(where: \.isKeyWindow)
    return topViewController(from: window?.rootViewController)
  }

  private func topViewController(from base: UIViewController?) -> UIViewController? {
    if let presented = base?.presentedViewController {
      return topViewController(from: presented)
    }
    if let navigation = base as? UINavigationController {
      return topViewController(from: navigation.visibleViewController)
    }
    if let tabs = base as? UITabBarController {
      return topViewController(from: tabs.selectedViewController)
    }
    return base
  }

  private enum PendingKind {
    case camera
    case gallery
  }

  private struct PendingOperation {
    let kind: PendingKind
    let result: FlutterResult
    let limits: MediaLimits
  }
}

@available(iOS 14.0, *)
private final class GalleryPickerDelegate: NSObject, PHPickerViewControllerDelegate {
  private let completion: (PHPickerResult?) -> Void

  init(completion: @escaping (PHPickerResult?) -> Void) {
    self.completion = completion
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    completion(results.first)
  }
}
