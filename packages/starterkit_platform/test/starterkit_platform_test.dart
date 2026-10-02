import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:starterkit_platform/starterkit_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('starterkit/platform/media'),
          null,
        );
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
    expect(
      () => StarterCameraCapability(
        androidFileProviderAuthority: 'com.example.app.fileprovider',
      ),
      returnsNormally,
    );
    expect(
      () => StarterCameraCapability(
        androidFileProviderAuthority: 'content://provider',
      ),
      throwsArgumentError,
    );
  });

  test('camera capture passes only bounded config and parses success', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('starterkit/platform/media'),
      (call) async {
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
      },
    );

    final result = await StarterCameraCapability(
      androidFileProviderAuthority: 'com.example.app.fileprovider',
    ).capture(limits: const MediaLimits(maxBytes: 1024, maxPixels: 2000));

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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('starterkit/platform/media'),
          (call) => throw PlatformException(code: 'boom'),
        );

    final result = await const StarterGalleryCapability().pickImage();
    expect(result.kind, MediaResultKind.failure);
    expect(result.code, 'gallery.platform_failure');
  });
}
