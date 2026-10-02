import 'package:flutter/services.dart';

const MethodChannel _mediaChannel = MethodChannel('starterkit/platform/media');

enum MediaPermissionStatus {
  notRequired,
  notDetermined,
  granted,
  denied,
  restricted,
  unavailable,
}

enum MediaResultKind {
  success,
  cancelled,
  denied,
  unavailable,
  invalid,
  failure,
}

final class MediaLimits {
  const MediaLimits({
    this.maxBytes = 10 * 1024 * 1024,
    this.maxPixels = 40 * 1000 * 1000,
  }) : assert(maxBytes > 0 && maxBytes <= maximumBytes),
       assert(maxPixels > 0 && maxPixels <= maximumPixels);

  static const int maximumBytes = 20 * 1024 * 1024;
  static const int maximumPixels = 50 * 1000 * 1000;

  final int maxBytes;
  final int maxPixels;

  Map<String, Object> toMap() => {
    'maxBytes': maxBytes,
    'maxPixels': maxPixels,
  };
}

final class MediaImage {
  MediaImage({
    required this.path,
    required this.byteLength,
    required this.width,
    required this.height,
    required this.mimeType,
  }) {
    if (path.isEmpty ||
        path.length > 4096 ||
        byteLength <= 0 ||
        width <= 0 ||
        height <= 0 ||
        mimeType.isEmpty ||
        mimeType.length > 128 ||
        !mimeType.startsWith('image/')) {
      throw ArgumentError('Invalid native media image metadata.');
    }
  }

  final String path;
  final int byteLength;
  final int width;
  final int height;
  final String mimeType;
}

final class MediaResult {
  const MediaResult._(this.kind, this.code, this.image);

  factory MediaResult.success(MediaImage image) =>
      MediaResult._(MediaResultKind.success, 'media.success', image);

  factory MediaResult.outcome(MediaResultKind kind, String code) {
    if (kind == MediaResultKind.success) {
      throw ArgumentError('success requires image metadata');
    }
    return MediaResult._(kind, _safeCode(code), null);
  }

  final MediaResultKind kind;
  final String code;
  final MediaImage? image;

  bool get isSuccess => kind == MediaResultKind.success;

  static MediaResult fromNative(Object? raw) {
    if (raw is! Map) {
      return MediaResult.outcome(
        MediaResultKind.failure,
        'media.invalid_native_response',
      );
    }
    final kindName = raw['kind'];
    final code = raw['code'];
    if (kindName is! String || code is! String) {
      return MediaResult.outcome(
        MediaResultKind.failure,
        'media.invalid_native_response',
      );
    }
    final kind = MediaResultKind.values.cast<MediaResultKind?>().firstWhere(
      (value) => value?.name == kindName,
      orElse: () => null,
    );
    if (kind == null) {
      return MediaResult.outcome(
        MediaResultKind.failure,
        'media.invalid_native_response',
      );
    }
    if (kind != MediaResultKind.success) {
      return MediaResult.outcome(kind, code);
    }
    final image = raw['image'];
    if (image is! Map) {
      return MediaResult.outcome(
        MediaResultKind.failure,
        'media.invalid_native_response',
      );
    }
    try {
      return MediaResult.success(
        MediaImage(
          path: image['path'] as String,
          byteLength: image['byteLength'] as int,
          width: image['width'] as int,
          height: image['height'] as int,
          mimeType: image['mimeType'] as String,
        ),
      );
    } on Object {
      return MediaResult.outcome(
        MediaResultKind.failure,
        'media.invalid_native_response',
      );
    }
  }
}

String _safeCode(String raw) {
  if (RegExp(r'^[a-z0-9_.-]{1,64}$').hasMatch(raw)) return raw;
  return 'media.failure';
}

final class StarterCameraCapability {
  StarterCameraCapability({this.androidFileProviderAuthority}) {
    final authority = androidFileProviderAuthority;
    if (authority != null &&
        !RegExp(
          r'^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+\.fileprovider$',
        ).hasMatch(authority)) {
      throw ArgumentError.value(
        authority,
        'androidFileProviderAuthority',
        'must be an application-scoped .fileprovider authority',
      );
    }
  }

  final String? androidFileProviderAuthority;

  Future<bool> isAvailable() async {
    try {
      return await _mediaChannel.invokeMethod<bool>('cameraAvailability') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  Future<MediaPermissionStatus> permissionStatus() async {
    try {
      final raw = await _mediaChannel.invokeMethod<String>(
        'cameraPermissionStatus',
      );
      return _permission(raw);
    } on PlatformException {
      return MediaPermissionStatus.unavailable;
    }
  }

  Future<MediaPermissionStatus> requestPermission() async {
    try {
      final raw = await _mediaChannel.invokeMethod<String>(
        'requestCameraPermission',
      );
      return _permission(raw);
    } on PlatformException {
      return MediaPermissionStatus.unavailable;
    }
  }

  Future<MediaResult> capture({
    MediaLimits limits = const MediaLimits(),
  }) async {
    try {
      final raw = await _mediaChannel.invokeMethod<Object?>('captureCamera', {
        ...limits.toMap(),
        'fileProviderAuthority': androidFileProviderAuthority,
      });
      return MediaResult.fromNative(raw);
    } on PlatformException {
      return MediaResult.outcome(
        MediaResultKind.failure,
        'camera.platform_failure',
      );
    }
  }

  Future<bool> cleanup(MediaImage image) => _cleanup(image.path);
}

final class StarterGalleryCapability {
  const StarterGalleryCapability();

  Future<bool> isAvailable() async {
    try {
      return await _mediaChannel.invokeMethod<bool>('galleryAvailability') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  Future<MediaResult> pickImage({
    MediaLimits limits = const MediaLimits(),
  }) async {
    try {
      final raw = await _mediaChannel.invokeMethod<Object?>(
        'pickGalleryImage',
        limits.toMap(),
      );
      return MediaResult.fromNative(raw);
    } on PlatformException {
      return MediaResult.outcome(
        MediaResultKind.failure,
        'gallery.platform_failure',
      );
    }
  }

  Future<bool> cleanup(MediaImage image) => _cleanup(image.path);
}

Future<bool> _cleanup(String path) async {
  try {
    return await _mediaChannel.invokeMethod<bool>('cleanupMedia', {
          'path': path,
        }) ??
        false;
  } on PlatformException {
    return false;
  }
}

MediaPermissionStatus _permission(String? raw) =>
    MediaPermissionStatus.values.firstWhere(
      (value) => value.name == raw,
      orElse: () => MediaPermissionStatus.unavailable,
    );
