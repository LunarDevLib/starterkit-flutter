import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:starterkit_qr_barcode/starterkit_qr_barcode.dart';
import 'package:starterkit_qr_barcode/src/payload_validation.dart';

const _channel = MethodChannel('starterkit/qr_barcode');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  test(
    'disabled returns before validation, copy, or native invocation',
    () async {
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            calls++;
            return null;
          });
      final result = await const StarterQrBarcodeCapability().decode(
        Uint8List(0),
      );
      expect(result.kind, QrBarcodeResultKind.unavailable);
      expect(result.code, 'qr.disabled');
      expect(result.codes, isEmpty);
      expect(calls, 0);
    },
  );

  test(
    'enabled invalid byte lengths are rejected without a channel call',
    () async {
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            calls++;
            return null;
          });
      const capability = StarterQrBarcodeCapability(enabled: true);
      final empty = await capability.decode(Uint8List(0));
      final tooLarge = await capability.decode(Uint8List(10 * 1024 * 1024 + 1));
      expect(
        (empty.kind, empty.code),
        (QrBarcodeResultKind.invalid, 'qr.invalid_image'),
      );
      expect(
        (tooLarge.kind, tooLarge.code),
        (QrBarcodeResultKind.invalid, 'qr.image_too_large'),
      );
      expect(calls, 0);
    },
  );

  test(
    'exact request contract and synchronous defensive input snapshot',
    () async {
      final received = Completer<Uint8List>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            expect(call.method, 'decodeImage');
            expect(call.arguments, isA<Map>());
            final arguments = Map<Object?, Object?>.from(
              call.arguments! as Map,
            );
            expect(arguments.keys.toSet(), {'bytes'});
            expect(arguments['bytes'], isA<Uint8List>());
            received.complete(
              Uint8List.fromList(arguments['bytes']! as Uint8List),
            );
            return _success(const [('qr', 'QR')]);
          });
      final mutable = Uint8List.fromList([1, 2, 3]);
      final resultFuture = const StarterQrBarcodeCapability(enabled: true)
          .decode(mutable);
      mutable.fillRange(0, mutable.length, 9);
      final result = await resultFuture;
      expect(await received.future, [1, 2, 3]);
      expect(result.kind, QrBarcodeResultKind.success);
    },
  );

  test('accepts only every frozen kind/code pair', () async {
    const pairs = <(String, String, QrBarcodeResultKind)>[
      ('success', 'qr.success', QrBarcodeResultKind.success),
      ('noResult', 'qr.no_result', QrBarcodeResultKind.noResult),
      ('unsupported', 'qr.unsupported_format', QrBarcodeResultKind.unsupported),
      ('unavailable', 'qr.disabled', QrBarcodeResultKind.unavailable),
      (
        'unavailable',
        'qr.platform_unavailable',
        QrBarcodeResultKind.unavailable,
      ),
      ('unavailable', 'qr.unavailable', QrBarcodeResultKind.unavailable),
      ('cancelled', 'qr.engine_detached', QrBarcodeResultKind.cancelled),
      ('invalid', 'qr.invalid_request', QrBarcodeResultKind.invalid),
      ('invalid', 'qr.invalid_image', QrBarcodeResultKind.invalid),
      ('invalid', 'qr.image_too_large', QrBarcodeResultKind.invalid),
      ('invalid', 'qr.image_dimensions', QrBarcodeResultKind.invalid),
      ('invalid', 'qr.invalid_payload', QrBarcodeResultKind.invalid),
      ('invalid', 'qr.invalid_native_response', QrBarcodeResultKind.invalid),
      ('conflict', 'qr.operation_in_progress', QrBarcodeResultKind.conflict),
      ('failure', 'qr.decode_error', QrBarcodeResultKind.failure),
      ('failure', 'qr.platform_failure', QrBarcodeResultKind.failure),
    ];
    for (final (kind, code, expected) in pairs) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            if (kind == 'success') return _success(const [('qr', 'QR')]);
            return {'kind': kind, 'code': code};
          });
      final result = await _decode();
      expect(result.kind, expected, reason: '$kind/$code');
      expect(result.code, code, reason: '$kind/$code');
      expect(result.isSuccess, kind == 'success');
    }
  });

  test(
    'strict schema rejects malformed maps, types, keys, and outcome pairs',
    () async {
      final malformed = <Object?>[
        null,
        1,
        {'kind': 'noResult'},
        {'kind': true, 'code': 'qr.no_result'},
        {'kind': 'noResult', 'code': 1},
        {'kind': 'noResult', 'code': 'qr.no_result', 'extra': 1},
        {1: 'bad', 'code': 'qr.no_result'},
        {'kind': 'success', 'code': 'qr.no_result'},
        {'kind': 'notAResult', 'code': 'qr.success'},
        {'kind': 'noResult', 'code': 'qr.success'},
        {'kind': 'failure', 'code': 'private native detail'},
        {'kind': 'success', 'code': 'qr.success', 'codes': null},
        {'kind': 'success', 'code': 'qr.success', 'codes': []},
        {
          'kind': 'success',
          'code': 'qr.success',
          'codes': [
            {'value': 'x', 'format': 'QR', 'extra': true},
          ],
        },
        {
          'kind': 'success',
          'code': 'qr.success',
          'codes': [
            {1: 'x', 'format': 'QR'},
          ],
        },
        {
          'kind': 'success',
          'code': 'qr.success',
          'codes': [
            {'value': 2, 'format': 'QR'},
          ],
        },
        {
          'kind': 'success',
          'code': 'qr.success',
          'codes': [
            {'value': 'x', 'format': false},
          ],
        },
        {
          'kind': 'success',
          'code': 'qr.success',
          'codes': [
            {'value': 'x', 'format': 'Aztec'},
          ],
        },
      ];
      for (final response in malformed) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_channel, (call) async => response);
        final result = await _decode();
        expect(result.kind, QrBarcodeResultKind.invalid, reason: '$response');
        expect(result.code, 'qr.invalid_native_response');
        expect(result.codes, isEmpty);
      }
    },
  );

  test(
    'success format mappings, immutable list, and defensive result copy',
    () async {
      final nativeCodes = <Object?>[
        {'value': 'qr-value', 'format': 'QR'},
        {'value': ' leading and trailing ', 'format': 'QR'},
        {'value': '1234567890123', 'format': 'EAN13'},
        {'value': 'code128', 'format': 'Code128'},
      ];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            _channel,
            (call) async => {
              'kind': 'success',
              'code': 'qr.success',
              'codes': nativeCodes,
            },
          );
      final result = await _decode();
      nativeCodes.clear();
      expect(result.codes, hasLength(4));
      expect(result.codes.map((item) => (item.value, item.format)).toList(), [
        ('qr-value', QrBarcodeFormat.qr),
        (' leading and trailing ', QrBarcodeFormat.qr),
        ('1234567890123', QrBarcodeFormat.ean13),
        ('code128', QrBarcodeFormat.code128),
      ]);
      expect(
        () => result.codes.add(result.codes.first),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'payload Unicode, controls, byte limits, cardinality and aggregate bound',
    () async {
      for (final bad in <String>[
        '',
        'x\u0000y',
        'x\u001fy',
        'x\u007fy',
        'x\u009fy',
        'é' * 1025,
      ]) {
        final result = await _withCodes([(bad, 'QR')]);
        expect(
          result.kind,
          QrBarcodeResultKind.invalid,
          reason: bad.codeUnits.toString(),
        );
        expect(result.code, 'qr.invalid_native_response');
      }
      expect(validQrPayloadLength('\ud800'), isNull);
      expect(validQrPayloadLength('\udc00'), isNull);
      final exact = await _withCodes([('é' * 1024, 'QR')]);
      expect(exact.kind, QrBarcodeResultKind.success);
      expect(exact.codes.single.value, 'é' * 1024);
      expect(
        (await _withCodes([('ok', 'QR'), ('é' * 1024, 'QR')])).kind,
        QrBarcodeResultKind.success,
      );
      expect(
        (await _withCodes([('é' * 1024, 'QR'), ('a', 'QR')])).kind,
        QrBarcodeResultKind.success,
      );
      expect(
        (await _withCodes(List.generate(16, (_) => ('x' * 2048, 'QR')))).kind,
        QrBarcodeResultKind.success,
      );
      expect(
        (await _withCodes(List.generate(17, (_) => ('x', 'QR')))).kind,
        QrBarcodeResultKind.invalid,
      );
      expect(
        (await _withCodes(List.generate(16, (_) => ('x' * 2048, 'QR'))))
            .codes
            .length,
        16,
      );
      expect(
        (await _withCodes(List.generate(16, (_) => ('x' * 2048, 'QR')))).codes
            .fold<int>(0, (total, item) => total + item.value.length),
        32768,
      );
    },
  );

  test(
    'missing plugin and transport exceptions return fixed safe outcomes',
    () async {
      final absent = await _decode();
      expect(
        (absent.kind, absent.code),
        (QrBarcodeResultKind.unavailable, 'qr.platform_unavailable'),
      );
      for (final error in <Object>[
        PlatformException(code: 'secret private detail'),
        StateError('another private detail'),
      ]) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_channel, (call) async => throw error);
        final result = await _decode();
        expect(
          (result.kind, result.code),
          (QrBarcodeResultKind.failure, 'qr.platform_failure'),
        );
        expect(result.toString(), isNot(contains('private')));
      }
    },
  );

  test('no-result passes through without inventing a code', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          _channel,
          (call) async => {'kind': 'noResult', 'code': 'qr.no_result'},
        );
    final result = await _decode();
    expect(result.kind, QrBarcodeResultKind.noResult);
    expect(result.code, 'qr.no_result');
    expect(result.codes, isEmpty);
  });

  test(
    'simultaneous requests are independently correlated by MethodChannel',
    () async {
      final calls = <int>[];
      final pending = <int, Completer<Object?>>{};
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) {
            final bytes = (call.arguments as Map)['bytes']! as Uint8List;
            final marker = bytes.single;
            calls.add(marker);
            return (pending[marker] ??= Completer<Object?>()).future;
          });
      final first = const StarterQrBarcodeCapability(enabled: true)
          .decode(Uint8List.fromList([1]));
      final second = const StarterQrBarcodeCapability(enabled: true)
          .decode(Uint8List.fromList([2]));
      await Future<void>.delayed(Duration.zero);
      expect(calls.toSet(), {1, 2});
      pending[2]!.complete(_success(const [('second', 'QR')]));
      pending[1]!.complete(_success(const [('first', 'QR')]));
      expect((await first).codes.single.value, 'first');
      expect((await second).codes.single.value, 'second');
    },
  );
}

Future<QrBarcodeResult> _decode() =>
    const StarterQrBarcodeCapability(enabled: true)
        .decode(Uint8List.fromList([1]));

Future<QrBarcodeResult> _withCodes(List<(String, String)> values) async {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async => _success(values));
  return _decode();
}

Map<String, Object?> _success(List<(String, String)> values) => {
  'kind': 'success',
  'code': 'qr.success',
  'codes': values.map((item) => {'value': item.$1, 'format': item.$2}).toList(),
};
