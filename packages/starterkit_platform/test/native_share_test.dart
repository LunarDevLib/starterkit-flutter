import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:starterkit_platform/native_share.dart';
import 'package:starterkit_platform/starterkit_platform.dart';

const _channel = MethodChannel('starterkit/platform/share');
const _enabled = StarterNativeShareCapability(enabled: true);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => _mock(null));

  test(
    'const default disabled returns before validation, native calls or IO',
    () async {
      var calls = 0;
      var fileAccesses = 0;
      _mock((call) async {
        calls++;
        return null;
      });
      await IOOverrides.runZoned(
        () async {
          const capability = StarterNativeShareCapability();
          final result = await capability.share(
            text: String.fromCharCode(0xd800),
            httpsUrl: 'https://user:secret@example.com/?token=secret',
            fileUri: 'file:///missing/product-image.png',
            anchor: const NativeShareAnchor(
              x: double.nan,
              y: -1,
              width: 0,
              height: 0,
            ),
          );
          expect(result.kind, NativeShareResultKind.unavailable);
          expect(result.code, 'share.disabled');
          expect((await capability.share()).code, 'share.disabled');
        },
        createFile: (_) {
          fileAccesses++;
          throw StateError('Dart must not open or acquire files');
        },
      );
      expect(calls, 0);
      expect(fileAccesses, 0);
    },
  );

  test(
    'exact supplied wire values and immutable anchor are snapshotted',
    () async {
      const original = NativeShareAnchor(x: 1, y: 2, width: 3, height: 4);
      var anchor = original;
      _mock((call) async {
        expect(call.method, 'share');
        expect(call.arguments, {
          'text': '  Exact é 😀  ',
          'httpsUrl': 'https://EXAMPLE.com:443/path?tag=hello%20world',
          'fileUri': 'content://product.images/selected/1',
          'anchor': {'x': 1.0, 'y': 2.0, 'width': 3.0, 'height': 4.0},
        });
        return {'kind': 'presented', 'code': 'share.presented'};
      });
      final pending = _enabled.share(
        text: '  Exact é 😀  ',
        httpsUrl: 'https://EXAMPLE.com:443/path?tag=hello%20world',
        fileUri: 'content://product.images/selected/1',
        anchor: anchor,
      );
      anchor = const NativeShareAnchor(x: 9, y: 9, width: 9, height: 9);
      expect(() => (original as dynamic).x = 7, throwsNoSuchMethodError);
      expect(anchor.x, 9);
      final result = await pending;
      expect(result.kind, NativeShareResultKind.presented);
      expect(result.code, 'share.presented');
    },
  );

  test(
    'missing or empty payload and empty URI fields make zero calls',
    () async {
      var calls = 0;
      _mock((call) async {
        calls++;
        return null;
      });
      for (final pending in [
        _enabled.share(),
        _enabled.share(text: ''),
        _enabled.share(text: 'message', httpsUrl: ''),
        _enabled.share(text: 'message', fileUri: ''),
      ]) {
        expect((await pending).code, 'share.invalid_payload');
      }
      expect(calls, 0);
    },
  );

  test('text preserves spaces, accepts 4000 code points, rejects overflow and invalid Unicode', () async {
    var calls = 0;
    _mock((call) async {
      calls++;
      expect((call.arguments as Map).keys.toSet(), {'text'});
      return {'kind': 'presented', 'code': 'share.presented'};
    });
    for (final text in [' ' * 4000, '😀' * 4000]) {
      expect(
        (await _enabled.share(text: text)).kind,
        NativeShareResultKind.presented,
      );
    }
    for (final text in [
      'a' * 4001,
      '😀' * 4001,
      'é' * 8193,
      'before\u0000after',
      'line\nbreak',
      'tab\ttext',
      'a\u007fb',
      'a\u009fb',
      String.fromCharCode(0xd800),
      String.fromCharCode(0xdc00),
      '${String.fromCharCode(0xd800)}x',
    ]) {
      expect((await _enabled.share(text: text)).code, 'share.invalid_payload');
    }
    expect(calls, 2);
  });

  test(
    'HTTPS exact byte bound and optional empty text use only supplied keys',
    () async {
      final exact =
          'https://example.com/${'a' * (2048 - 'https://example.com/'.length)}';
      var calls = 0;
      _mock((call) async {
        calls++;
        expect(call.arguments, {'text': '', 'httpsUrl': exact});
        return {'kind': 'presented', 'code': 'share.presented'};
      });
      expect(
        (await _enabled.share(text: '', httpsUrl: exact)).code,
        'share.presented',
      );
      expect(
        (await _enabled.share(httpsUrl: '${exact}a')).code,
        'share.invalid_payload',
      );
      expect(
        (await _enabled.share(httpsUrl: 'https://example.com/${'é' * 1024}'))
            .code,
        'share.invalid_payload',
      );
      expect(calls, 1);
    },
  );

  test(
    'HTTPS refuses unsafe schemes, authorities, fragments and malformed URIs',
    () async {
      var calls = 0;
      _mock((call) async {
        calls++;
        return null;
      });
      for (final url in [
        'http://example.com',
        'javascript:alert(1)',
        'https:example.com',
        'https://user:password@example.com',
        'https://@example.com',
        'https://example.com#fragment',
        'https://example.com#',
        'https://example.com:444',
        'https://example.com:0443',
        'https://example.com.',
        'https://example..com',
        'https://-example.com',
        'https://bad_host.example',
        'https://éxample.com',
        'https://[::1]',
        'https://%65xample.com',
        'https://example.com\\evil',
        'https://example.com/a b',
        'https://example.com/\u0000',
        'https://example.com/%zz',
        'https://example.com/?%ff=value',
      ]) {
        expect(
          (await _enabled.share(httpsUrl: url)).code,
          'share.invalid_payload',
          reason: url,
        );
      }
      expect(calls, 0);
    },
  );

  test('frozen sensitive query keys and encoded keys are refused without native calls', () async {
    var calls = 0;
    _mock((call) async {
      calls++;
      return null;
    });
    for (final key in [
      'token',
      'access_token',
      'authorization',
      'auth',
      'api_key',
      'key',
      'password',
      'secret',
      'session',
      'code',
      'prefixTOKENsuffix',
      'to%6ben',
      '%61ccess_token',
      'api%5fkey',
      'se%73sion',
    ]) {
      final result = await _enabled.share(
        httpsUrl: 'https://example.com/?$key=private',
      );
      expect(result.code, 'share.invalid_payload');
      expect(result.toString(), isNot(contains('private')));
    }
    expect(calls, 0);
  });

  test('file transport forwards URIs without Dart file access and leaves availability native', () async {
    var fileAccesses = 0;
    final files = [
      'content://product.images/selected/1',
      'file:///product/image%20one.png',
    ];
    final sent = <String>[];
    _mock((call) async {
      expect((call.arguments as Map).keys.toSet(), {'fileUri'});
      sent.add((call.arguments as Map)['fileUri'] as String);
      return {'kind': 'unavailable', 'code': 'share.file_unavailable'};
    });
    await IOOverrides.runZoned(
      () async {
        for (final file in files) {
          expect(
            (await _enabled.share(fileUri: file)).code,
            'share.file_unavailable',
          );
        }
      },
      createFile: (_) {
        fileAccesses++;
        throw StateError('file existence/access belongs to native');
      },
    );
    expect(sent, files);
    expect(fileAccesses, 0);
  });

  test(
    'file URI byte limits, authority and query/fragment syntax fail closed',
    () async {
      var calls = 0;
      _mock((call) async {
        calls++;
        return {'kind': 'presented', 'code': 'share.presented'};
      });
      final exact = 'file:///${'a' * (2048 - 'file:///'.length)}';
      expect((await _enabled.share(fileUri: exact)).code, 'share.presented');
      for (final uri in [
        '${exact}a',
        'file:///${'é' * 1024}',
        '/product/image.png',
        'https://example.com/image.png',
        'data:image/png;base64,a',
        'content:///image.png',
        'file:relative.png',
        'content://user@product.images/image',
        'content://product.images:443/image',
        'content://product.images/image?query',
        'file:///image.png?',
        'file:///image.png#fragment',
        'file:///image.png#',
        'file:///bad\u0080.png',
        'file:///bad%z.png',
      ]) {
        expect(
          (await _enabled.share(fileUri: uri)).code,
          'share.invalid_payload',
        );
      }
      expect(calls, 1);
    },
  );

  test(
    'anchor requires finite nonnegative origin and positive dimensions',
    () async {
      var calls = 0;
      _mock((call) async {
        calls++;
        return null;
      });
      for (final anchor in [
        const NativeShareAnchor(x: -1, y: 0, width: 1, height: 1),
        const NativeShareAnchor(x: 0, y: -1, width: 1, height: 1),
        const NativeShareAnchor(x: 0, y: 0, width: 0, height: 1),
        const NativeShareAnchor(x: 0, y: 0, width: 1, height: -1),
        const NativeShareAnchor(x: double.nan, y: 0, width: 1, height: 1),
        const NativeShareAnchor(x: 0, y: double.infinity, width: 1, height: 1),
        const NativeShareAnchor(x: 0, y: 0, width: double.infinity, height: 1),
        const NativeShareAnchor(x: 1e308, y: 0, width: 1e308, height: 1),
        const NativeShareAnchor(x: 0, y: 1e308, width: 1, height: 1e308),
      ]) {
        expect(
          (await _enabled.share(text: 'share', anchor: anchor)).code,
          'share.invalid_payload',
        );
      }
      expect(calls, 0);
    },
  );

  test(
    'all exact native outcome pairs are preserved without delivery claims',
    () async {
      for (final (kind, code) in const [
        ('presented', 'share.presented'),
        ('completed', 'share.completed'),
        ('cancelled', 'share.cancelled'),
        ('invalid', 'share.invalid_payload'),
        ('unavailable', 'share.platform_unavailable'),
        ('unavailable', 'share.host_unavailable'),
        ('unavailable', 'share.file_unavailable'),
        ('conflict', 'share.operation_in_progress'),
        ('cancelled', 'share.engine_detached'),
        ('failure', 'share.platform_failure'),
      ]) {
        _mock((call) async => {'kind': kind, 'code': code});
        final result = await _enabled.share(text: 'message');
        expect(result.kind.name, kind);
        expect(result.code, code);
      }
    },
  );

  test(
    'unknown schema, keys, kinds and mismatched pairs reject raw details',
    () async {
      for (final raw in <Object?>[
        null,
        1,
        {'kind': 'presented'},
        {'code': 'share.presented'},
        {'kind': 'presented', 'code': 1},
        {'kind': 1, 'code': 'share.presented'},
        {'kind': 'delivered', 'code': 'share.delivered'},
        {'kind': 'completed', 'code': 'share.presented'},
        {'kind': 'presented', 'code': 'private raw detail'},
        {'kind': 'presented', 'code': 'share.presented', 'detail': 'private'},
        {'kind': 'presented', 'code': 'share.presented', 'requestId': 'extra'},
        {1: 'presented', 'code': 'share.presented'},
        {'kind': 'unavailable', 'code': 'share.disabled'},
        {'kind': 'invalid', 'code': 'share.invalid_native_response'},
      ]) {
        _mock((call) async => raw);
        final result = await _enabled.share(text: 'message');
        expect(result.kind, NativeShareResultKind.invalid);
        expect(result.code, 'share.invalid_native_response');
        expect(result.toString(), isNot(contains('private')));
      }
    },
  );

  test(
    'missing plugin and platform failures map to fixed codes only',
    () async {
      expect(
        (await _enabled.share(text: 'message')).code,
        'share.platform_unavailable',
      );
      _mock(
        (call) async => throw PlatformException(
          code: 'private',
          message: 'secret',
          details: {'token': 'secret'},
        ),
      );
      final result = await _enabled.share(text: 'message');
      expect(result.kind, NativeShareResultKind.failure);
      expect(result.code, 'share.platform_failure');
      expect(result.toString(), isNot(contains('secret')));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler(_channel.name, (_) async => ByteData(0));
      final malformedTransport = await _enabled.share(text: 'message');
      expect(malformedTransport.kind, NativeShareResultKind.failure);
      expect(malformedTransport.code, 'share.platform_failure');
    },
  );
}

void _mock(Future<Object?> Function(MethodCall)? handler) =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, handler);
