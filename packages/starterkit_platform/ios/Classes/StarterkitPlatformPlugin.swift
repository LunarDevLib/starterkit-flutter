import AVFoundation
import Flutter
import ImageIO
import PhotosUI
import UIKit

public final class StarterkitPlatformPlugin: NSObject, FlutterPlugin,
  UIImagePickerControllerDelegate, UINavigationControllerDelegate
{
  private var channel: FlutterMethodChannel?
  private var locationChannel: FlutterMethodChannel?
  private var locationAdapter: IOSLocationAdapter?
  private var biometricChannel: FlutterMethodChannel?
  private var biometricAdapter: IOSBiometricAdapter?
  private var shareChannel: FlutterMethodChannel?
  private var shareAdapter: IOSNativeShareAdapter?
  private var pending: PendingOperation?
  private var galleryDelegate: AnyObject?
  private var engineAttached = true

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = StarterkitPlatformPlugin()
    let channel = FlutterMethodChannel(
      name: "starterkit/platform/media",
      binaryMessenger: registrar.messenger()
    )
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)
    let locationChannel = FlutterMethodChannel(
      name: "starterkit/platform/location",
      binaryMessenger: registrar.messenger()
    )
    instance.locationChannel = locationChannel
    instance.locationAdapter = IOSLocationAdapter()
    locationChannel.setMethodCallHandler { [weak instance] call, result in
      guard let instance, instance.engineAttached, let adapter = instance.locationAdapter else {
        result(
          LocationPolicy.detachedResponse(
            method: call.method, arguments: call.arguments as? [String: Any]
          ) ?? FlutterMethodNotImplemented
        )
        return
      }
      adapter.handle(call, result: result)
    }
    let biometricChannel = FlutterMethodChannel(
      name: "starterkit/platform/biometric",
      binaryMessenger: registrar.messenger()
    )
    instance.biometricChannel = biometricChannel
    instance.biometricAdapter = IOSBiometricAdapter()
    biometricChannel.setMethodCallHandler { [weak instance] call, result in
      guard let instance, instance.engineAttached, let adapter = instance.biometricAdapter else {
        result(
          BiometricPolicy.detachedResponse(
            method: call.method, arguments: call.arguments as? [String: Any]
          ) ?? FlutterMethodNotImplemented
        )
        return
      }
      adapter.handle(call, result: result)
    }
    let shareChannel = FlutterMethodChannel(
      name: "starterkit/platform/share",
      binaryMessenger: registrar.messenger()
    )
    instance.shareChannel = shareChannel
    instance.shareAdapter = IOSNativeShareAdapter(host: registrar.viewController)
    shareChannel.setMethodCallHandler { [weak instance] call, result in
      guard let instance, instance.engineAttached, let adapter = instance.shareAdapter else {
        if call.method == "share" {
          result(ShareOutcome.engineDetached.wire)
        } else {
          result(FlutterMethodNotImplemented)
        }
        return
      }
      adapter.handle(call, result: result)
    }
    // Flutter only sends detachFromEngine to published plugin instances.
    registrar.publish(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { self.handle(call, result: result) }
      return
    }
    guard engineAttached else {
      result(mediaOutcome("failure", "media.engine_detached"))
      return
    }
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

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { self.detachFromEngine(for: registrar) }
      return
    }
    engineAttached = false
    locationChannel?.setMethodCallHandler(nil)
    locationChannel = nil
    let detachedLocationAdapter = locationAdapter
    locationAdapter = nil
    detachedLocationAdapter?.detach()
    biometricChannel?.setMethodCallHandler(nil)
    biometricChannel = nil
    let detachedBiometricAdapter = biometricAdapter
    biometricAdapter = nil
    detachedBiometricAdapter?.detach()
    shareChannel?.setMethodCallHandler(nil)
    shareChannel = nil
    let detachedShareAdapter = shareAdapter
    shareAdapter = nil
    detachedShareAdapter?.detach()
    let operation = pending
    pending = nil
    galleryDelegate = nil
    channel?.setMethodCallHandler(nil)
    channel = nil
    operation?.lifecycle.invalidate()
    operation?.picker?.dismiss(animated: false)
    operation?.result(mediaOutcome("failure", "media.engine_detached"))
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
    pending = PendingOperation(kind: .camera, result: result, limits: limits, picker: picker)
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
    let operation = PendingOperation(kind: .gallery, result: result, limits: limits, picker: picker)
    let delegate = GalleryPickerDelegate { [weak self] selected in
      self?.handleGallerySelection(selected, operation: operation)
    }
    galleryDelegate = delegate
    picker.delegate = delegate
    pending = operation
    host.present(picker, animated: true)
  }

  public func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { self.imagePickerControllerDidCancel(picker) }
      return
    }
    guard let operation = pending, operation.kind == .camera, operation.picker === picker else {
      return
    }
    picker.dismiss(animated: true)
    finishPending(operation, mediaOutcome("cancelled", "camera.cancelled"))
  }

  public func imagePickerController(
    _ picker: UIImagePickerController,
    didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
  ) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async {
        self.imagePickerController(picker, didFinishPickingMediaWithInfo: info)
      }
      return
    }
    guard let operation = pending, operation.kind == .camera, operation.picker === picker else {
      return
    }
    picker.dismiss(animated: true)
    guard let image = info[.originalImage] as? UIImage else {
      finishPending(operation, mediaOutcome("invalid", "camera.image_missing"))
      return
    }
    let width = image.cgImage?.width ?? Int(image.size.width * image.scale)
    let height = image.cgImage?.height ?? Int(image.size.height * image.scale)
    guard MediaPolicy.validDimensions(width: width, height: height, limits: operation.limits) else {
      finishPending(operation, mediaOutcome("invalid", "media.invalid_dimensions"))
      return
    }

    guard operation.lifecycle.queueWork() else { return }
    let destination = newTempURL(prefix: "camera", extension: "jpg")
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      guard operation.lifecycle.startWork() else { return }
      guard let data = image.jpegData(compressionQuality: 0.95) else {
        self.completeWork(operation, mediaOutcome("failure", "camera.encode_failed"))
        return
      }
      guard !data.isEmpty, data.count <= operation.limits.maxBytes else {
        self.completeWork(operation, mediaOutcome("invalid", "media.too_large"))
        return
      }
      guard !operation.lifecycle.isInvalidated else {
        self.completeWork(operation, mediaOutcome("failure", "media.engine_detached"))
        return
      }
      do {
        try data.write(to: destination, options: .atomic)
        let metadata = MediaMetadata(
          path: destination.path,
          byteLength: data.count,
          width: width,
          height: height,
          mimeType: "image/jpeg"
        )
        self.completeWork(
          operation, mediaOutcome("success", "media.success", image: metadata), output: destination
        )
      } catch {
        try? FileManager.default.removeItem(at: destination)
        self.completeWork(operation, mediaOutcome("failure", "camera.write_failed"))
      }
    }
  }

  @available(iOS 14.0, *)
  private func handleGallerySelection(_ selected: PHPickerResult?, operation: PendingOperation) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard pending === operation, operation.kind == .gallery else { return }
    guard let selected else {
      finishPending(operation, mediaOutcome("cancelled", "gallery.cancelled"))
      return
    }
    let provider = selected.itemProvider
    guard provider.hasItemConformingToTypeIdentifier("public.image") else {
      finishPending(operation, mediaOutcome("invalid", "gallery.invalid_type"))
      return
    }
    guard operation.lifecycle.queueWork() else { return }
    galleryDelegate = nil
    let destination = newTempURL(prefix: "gallery", extension: "img")
    provider.loadFileRepresentation(forTypeIdentifier: "public.image") {
      [self] source, error in
      guard operation.lifecycle.startWork() else { return }
      guard error == nil, let source else {
        self.completeWork(operation, mediaOutcome("failure", "gallery.read_failed"))
        return
      }
      let completed = self.copyAndValidateGallery(
        source, destination: destination, operation: operation
      )
      self.completeWork(operation, completed.outcome, output: completed.output)
    }
  }

  @available(iOS 14.0, *)
  private func copyAndValidateGallery(
    _ source: URL, destination: URL, operation: PendingOperation
  ) -> (outcome: [String: Any], output: URL?) {
    guard source.isFileURL else { return (mediaOutcome("invalid", "gallery.invalid_file"), nil) }
    let limits = operation.limits
    do {
      let verified = try MediaFilePolicy.copyAndValidate(
        source: source,
        destination: destination,
        maxBytes: limits.maxBytes,
        maxPixels: limits.maxPixels,
        isCancelled: { operation.lifecycle.isInvalidated }
      )
      guard MediaPolicy.validDimensions(
        width: verified.width,
        height: verified.height,
        limits: limits
      ) else {
        try? FileManager.default.removeItem(at: destination)
        return (mediaOutcome("invalid", "media.invalid_dimensions"), nil)
      }
      guard let mime = Self.mimeType(for: verified.mimeType), mime.utf8.count <= 128 else {
        try? FileManager.default.removeItem(at: destination)
        return (mediaOutcome("invalid", "media.invalid_type"), nil)
      }
      return (
        mediaOutcome(
          "success",
          "media.success",
          image: MediaMetadata(
            path: destination.path,
            byteLength: verified.byteLength,
            width: verified.width,
            height: verified.height,
            mimeType: mime
          )
        ), destination
      )
    } catch MediaFileError.tooLarge {
      return (mediaOutcome("invalid", "media.too_large"), nil)
    } catch MediaFileError.invalidImage {
      return (mediaOutcome("invalid", "media.invalid_image"), nil)
    } catch MediaFileError.invalidDimensions {
      return (mediaOutcome("invalid", "media.invalid_dimensions"), nil)
    } catch MediaFileError.invalidSource {
      return (mediaOutcome("invalid", "gallery.invalid_file"), nil)
    } catch MediaFileError.empty {
      return (mediaOutcome("invalid", "gallery.empty_file"), nil)
    } catch MediaFileError.cancelled {
      return (mediaOutcome("failure", "media.engine_detached"), nil)
    } catch {
      return (mediaOutcome("failure", "gallery.copy_failed"), nil)
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

  private func completeWork(
    _ operation: PendingOperation, _ outcome: [String: Any], output: URL? = nil
  ) {
    guard operation.lifecycle.completeWork(output: output) else { return }
    DispatchQueue.main.async { self.finishPending(operation, outcome, fromWorker: true) }
  }

  private func finishPending(
    _ operation: PendingOperation, _ outcome: [String: Any], fromWorker: Bool = false
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard pending === operation else {
      operation.lifecycle.invalidate()
      return
    }
    guard operation.lifecycle.settle(fromWorker: fromWorker) else { return }
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

  private final class PendingOperation {
    let kind: PendingKind
    let result: FlutterResult
    let limits: MediaLimits
    // Picker references are read only on main; workers must not retain UI objects.
    weak var picker: UIViewController?
    let lifecycle = MediaOperationLifecycle { output in
      try? FileManager.default.removeItem(at: output)
    }

    init(
      kind: PendingKind, result: @escaping FlutterResult, limits: MediaLimits, picker: UIViewController
    ) {
      self.kind = kind
      self.result = result
      self.limits = limits
      self.picker = picker
    }
  }
}

@available(iOS 14.0, *)
private final class GalleryPickerDelegate: NSObject, PHPickerViewControllerDelegate {
  private let completion: (PHPickerResult?) -> Void

  init(completion: @escaping (PHPickerResult?) -> Void) {
    self.completion = completion
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { self.picker(picker, didFinishPicking: results) }
      return
    }
    picker.dismiss(animated: true)
    completion(results.first)
  }
}
