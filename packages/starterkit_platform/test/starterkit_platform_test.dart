import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:starterkit_platform/starterkit_platform.dart';

const _channel = MethodChannel('starterkit/platform/media');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_channel, null);
  });

  test('MediaLimits enforce bounded caller-controlled limits', () {
    expect(
      () => MediaLimits(maxBytes: MediaLimits.maximumBytes + 1),
      throwsAssertionError,
    );
    expect(
      () => MediaLimits(maxPixels: MediaLimits.maximumPixels + 1),
      throwsAssertionError,
    );
  });

  test('camera authority must be application-scoped', () {
    final camera = StarterCameraCapability(
      androidFileProviderAuthority: 'com.example.app.fileprovider',
    );
    expect(camera.androidFileProviderAuthority, 'com.example.app.fileprovider');

    expect(
      () => StarterCameraCapability(
        androidFileProviderAuthority: 'content://provider',
      ),
      throwsArgumentError,
    );
  });

  test('camera capture passes bounded config and parses success', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      expect(call.method, 'captureCamera');
      final arguments = call.arguments! as Map;
      expect(arguments['maxBytes'], 1024);
      expect(arguments['maxPixels'], 2000);
      expect(
        arguments['fileProviderAuthority'],
        'com.example.app.fileprovider',
      );
      return {
        'kind': 'success',
        'code': 'media.success',
        'image': {
          'path': '/private/image.jpg',
          'byteLength': 512,
          'width': 20,
          'height': 20,
          'mimeType': 'image/jpeg',
        },
      };
    });

    final camera = StarterCameraCapability(
      androidFileProviderAuthority: 'com.example.app.fileprovider',
    );
    const limits = MediaLimits(maxBytes: 1024, maxPixels: 2000);
    final result = await camera.capture(limits: limits);

    expect(result.kind, MediaResultKind.success);
    expect(result.image?.width, 20);
  });

  test('malformed native response fails closed', () {
    final result = MediaResult.fromNative({
      'kind': 'success',
      'code': 'media.success',
      'image': {
        'path': '',
        'byteLength': -1,
        'width': 0,
        'height': 0,
        'mimeType': 'text/plain',
      },
    });
    expect(result.kind, MediaResultKind.failure);
    expect(result.code, 'media.invalid_native_response');
  });

  test('platform failures do not leak as product exceptions', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_channel, _throwPlatformFailure);

    final result = await const StarterGalleryCapability().pickImage();
    expect(result.kind, MediaResultKind.failure);
    expect(result.code, 'gallery.platform_failure');
  });
}

Future<Object?> _throwPlatformFailure(MethodCall call) async {
  throw PlatformException(code: 'boom');
}
