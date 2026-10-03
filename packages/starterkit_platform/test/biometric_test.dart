import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:starterkit_platform/biometric.dart';
import 'package:starterkit_platform/starterkit_platform.dart';

const _channel = MethodChannel('starterkit/platform/biometric');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  test('disabled capability makes zero calls in every API mode', () async {
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls++;
          return null;
        });
    const disabled = StarterBiometricCapability();
    expect((await disabled.availability()).code, 'biometric.disabled');
    final invalid = disabled.authenticate(reason: '  \u0000 ');
    expect((await invalid.result).code, 'biometric.disabled');
    expect(await invalid.cancel(), isFalse);
    final normal = disabled.authenticate(reason: 'unlock');
    expect((await normal.result).code, 'biometric.disabled');
    expect(await normal.cancel(), isFalse);
    expect(calls, 0);
  });

  test(
    'availability strictly decodes all state/code pairs, separate from auth',
    () async {
      const pairs = <(String, String)>[
        ('ready', 'biometric.ready'),
        ('permissionRequired', 'biometric.permission_required'),
        ('noHardware', 'biometric.no_hardware'),
        ('notEnrolled', 'biometric.not_enrolled'),
        ('lockedOut', 'biometric.locked_out'),
        ('unavailable', 'biometric.unavailable'),
        ('unavailable', 'biometric.disabled'),
        ('unavailable', 'biometric.platform_unavailable'),
        ('unavailable', 'biometric.invalid_request'),
        ('unavailable', 'biometric.face_id_not_configured'),
        ('unavailable', 'biometric.platform_failure'),
      ];
      for (final (state, code) in pairs) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_channel, (call) async {
              expect(call.method, 'biometricAvailability');
              expect(call.arguments, isNull);
              return {'state': state, 'code': code};
            });
        final result = await const StarterBiometricCapability(enabled: true)
            .availability();
        expect(result.state.name, state);
        expect(result.code, code);
      }
      final pending = Completer<Object?>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            if (call.method == 'biometricAvailability') {
              return {'state': 'ready', 'code': 'biometric.ready'};
            }
            if (call.method == 'cancelBiometric') return true;
            return pending.future;
          });
      const capability = StarterBiometricCapability(enabled: true);
      expect(
        (await capability.availability()).state,
        BiometricAvailabilityState.ready,
      );
      final operation = capability.authenticate(reason: 'Confirm transfer');
      final cancelling = operation.cancel();
      expect((await operation.result).authenticated, isFalse);
      expect(await cancelling, isTrue);
      pending.complete(
        _response('cancelled', 'biometric.cancelled', operation.requestId),
      );
    },
  );

  test(
    'authentication IDs and exact reason payload are generated per request',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            calls.add(call);
            expect(call.method, 'authenticateBiometric');
            final args = Map<Object?, Object?>.from(call.arguments as Map);
            expect(args.keys.toSet(), {'requestId', 'reason'});
            expect(args['requestId'], matches(RegExp(r'^[0-9a-f]{32}$')));
            expect(args['reason'], 'Confirm transfer');
            return _response(
              'authenticated',
              'biometric.authenticated',
              args['requestId']! as String,
            );
          });
      const capability = StarterBiometricCapability(enabled: true);
      final first = capability.authenticate(reason: 'Confirm transfer');
      final second = capability.authenticate(reason: 'Confirm transfer');
      expect(first.requestId, isNot(second.requestId));
      expect((await first.result).authenticated, isTrue);
      expect((await second.result).authenticated, isTrue);
      expect(calls, hasLength(2));
      expect(await first.cancel(), isFalse);
      expect(calls, hasLength(2));
    },
  );

  test(
    'all authentication kind/code pairs are accepted only as exact pairs',
    () async {
      const pairs = <(String, String)>[
        ('authenticated', 'biometric.authenticated'),
        ('cancelled', 'biometric.cancelled'),
        ('cancelled', 'biometric.backgrounded'),
        ('cancelled', 'biometric.activity_detached'),
        ('cancelled', 'biometric.engine_detached'),
        ('denied', 'biometric.denied'),
        ('denied', 'biometric.permission_required'),
        ('denied', 'biometric.invalid_reason'),
        ('lockedOut', 'biometric.locked_out'),
        ('unavailable', 'biometric.unavailable'),
        ('unavailable', 'biometric.disabled'),
        ('unavailable', 'biometric.platform_unavailable'),
        ('unavailable', 'biometric.no_hardware'),
        ('unavailable', 'biometric.not_enrolled'),
        ('unavailable', 'biometric.face_id_not_configured'),
        ('unavailable', 'biometric.foreground_required'),
        ('unavailable', 'biometric.activity_unavailable'),
        ('invalid', 'biometric.invalid_request'),
        ('invalid', 'biometric.invalid_native_response'),
        ('conflict', 'biometric.operation_in_progress'),
        ('failure', 'biometric.platform_failure'),
        ('failure', 'biometric.prompt_failed'),
      ];
      for (final (kind, code) in pairs) {
        final result = await _responseOperation(kind, code);
        expect(result.kind.name, kind, reason: '$kind/$code');
        expect(result.code, code, reason: '$kind/$code');
        expect(result.authenticated, kind == 'authenticated');
      }
    },
  );

  test(
    'wrong/missing/extra keys, types, IDs and mismatched pairs fail closed',
    () async {
      final wrongId = 'f' * 32;
      final malformed = <Object?>[
        null,
        3,
        {'kind': 'authenticated', 'code': 'biometric.authenticated'},
        {
          'kind': 'authenticated',
          'code': 'biometric.authenticated',
          'requestId': 'wrong',
        },
        {
          'kind': 'authenticated',
          'code': 'biometric.authenticated',
          'requestId': wrongId,
        },
        {
          'kind': 'authenticated',
          'code': 'biometric.denied',
          'requestId': 'echo',
        },
        {
          'kind': 'denied',
          'code': 'biometric.authenticated',
          'requestId': 'echo',
        },
        {
          'kind': 'unknown',
          'code': 'biometric.authenticated',
          'requestId': 'echo',
        },
        {'kind': true, 'code': 'biometric.authenticated', 'requestId': 'echo'},
        {'kind': 'authenticated', 'code': 1, 'requestId': 'echo'},
        {
          'kind': 'authenticated',
          'code': 'biometric.authenticated',
          'requestId': 'echo',
          'extra': 1,
        },
        {1: 'bad', 'code': 'biometric.authenticated', 'requestId': 'echo'},
        {
          'kind': 'authenticated',
          'code': 'biometric.authenticated',
          'requestId': 2.5,
        },
      ];
      for (final response in malformed) {
        final result = await _responseOperationRaw(response);
        expect(result.kind, BiometricResultKind.invalid, reason: '$response');
        expect(result.code, 'biometric.invalid_native_response');
        expect(result.authenticated, isFalse);
      }
      final malformedAvailability = <Object?>[
        null,
        {'state': 'ready'},
        {'state': 'ready', 'code': 'biometric.denied'},
        {'state': 1, 'code': 'biometric.ready'},
        {'state': 'ready', 'code': 'biometric.ready', 'extra': true},
        {false: 'bad', 'code': 'biometric.ready'},
      ];
      for (final response in malformedAvailability) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_channel, (call) async => response);
        final result = await const StarterBiometricCapability(enabled: true)
            .availability();
        expect(result.code, 'biometric.platform_failure', reason: '$response');
      }
    },
  );

  test(
    'reason validates original UTF-8 bytes and invalid reason never prompts',
    () async {
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            calls++;
            final args = call.arguments as Map;
            return _response(
              'denied',
              'biometric.invalid_reason',
              args['requestId'] as String,
            );
          });
      const capability = StarterBiometricCapability(enabled: true);
      for (final reason in <String>['', ' \t ', 'a\u0000b', 'é' * 129]) {
        final op = capability.authenticate(reason: reason);
        expect(
          (await op.result).code,
          'biometric.invalid_reason',
          reason: reason,
        );
        expect(await op.cancel(), isFalse);
      }
      final maxBytes = 'é' * 128;
      final exact = capability.authenticate(reason: maxBytes);
      expect((await exact.result).kind, BiometricResultKind.denied);
      expect(calls, 1);
    },
  );

  test(
    'invalid reasons are denied without including user text in result',
    () async {
      const reason = 'private user reason\u0000';
      final op = const StarterBiometricCapability(enabled: true)
          .authenticate(reason: reason);
      final result = await op.result;
      expect(result.code, 'biometric.invalid_reason');
      expect(result.toString(), isNot(contains('private user reason')));
    },
  );

  test(
    'cancellation settles first, memoizes ack, scopes ID, ignores late reply',
    () async {
      final pending = <String, Completer<Object?>>{};
      final ack = Completer<Object?>();
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            calls.add(call);
            if (call.method == 'authenticateBiometric') {
              final id = (call.arguments as Map)['requestId']! as String;
              return (pending[id] ??= Completer<Object?>()).future;
            }
            return ack.future;
          });
      const capability = StarterBiometricCapability(enabled: true);
      final old = capability.authenticate(reason: 'Confirm');
      final firstCancel = old.cancel();
      final secondCancel = old.cancel();
      expect(identical(firstCancel, secondCancel), isTrue);
      expect((await old.result).kind, BiometricResultKind.cancelled);
      expect(
        calls.where((call) => call.method == 'cancelBiometric'),
        hasLength(1),
      );
      expect(calls.last.arguments, {'requestId': old.requestId});
      final newer = capability.authenticate(reason: 'Confirm');
      expect(newer.requestId, isNot(old.requestId));
      expect(identical(old.cancel(), firstCancel), isTrue);
      expect(
        calls.where((call) => call.method == 'cancelBiometric'),
        hasLength(1),
      );
      pending[old.requestId]!.complete(
        _response('authenticated', 'biometric.authenticated', old.requestId),
      );
      expect((await old.result).authenticated, isFalse);
      final newerCancel = newer.cancel();
      final cancelCalls = calls
          .where((call) => call.method == 'cancelBiometric')
          .toList();
      expect(cancelCalls, hasLength(2));
      expect(cancelCalls[1].arguments, {'requestId': newer.requestId});
      ack.complete(true);
      expect(await firstCancel, isTrue);
      expect(await newerCancel, isTrue);
    },
  );

  testWidgets(
    'cancel acknowledgement false, error and hang are safe and bounded',
    (tester) async {
      final pending = Completer<Object?>();
      var ackCount = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            if (call.method == 'authenticateBiometric') return pending.future;
            ackCount++;
            if (ackCount == 1) return false;
            if (ackCount == 2) throw StateError('private native secret');
            return Completer<Object?>().future;
          });
      const capability = StarterBiometricCapability(enabled: true);
      for (var i = 0; i < 2; i++) {
        final op = capability.authenticate(reason: 'Confirm');
        expect(await op.cancel(), isFalse);
        expect((await op.result).kind, BiometricResultKind.cancelled);
      }
      final hanging = capability.authenticate(reason: 'Confirm');
      final cancel = hanging.cancel();
      await tester.pump(const Duration(milliseconds: 999));
      expect(ackCount, 3);
      await tester.pump(const Duration(milliseconds: 2));
      expect(await cancel, isFalse);
      expect((await hanging.result).kind, BiometricResultKind.cancelled);
      expect((await hanging.result).code, isNot(contains('secret')));
      pending.complete(null);
    },
  );

  testWidgets('authentication remains pending beyond 60 seconds until cancel', (
    tester,
  ) async {
    final pending = Completer<Object?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'authenticateBiometric') return pending.future;
          return true;
        });
    final op = const StarterBiometricCapability(enabled: true)
        .authenticate(reason: 'Confirm');
    var completed = false;
    op.result.then((_) => completed = true);
    await tester.pump(const Duration(seconds: 61));
    expect(completed, isFalse);
    expect(await op.cancel(), isTrue);
    expect((await op.result).kind, BiometricResultKind.cancelled);
    pending.complete(null);
  });

  test(
    'native OS denial, lockout and failure never report authenticated',
    () async {
      for (final (kind, code) in const <(String, String)>[
        ('denied', 'biometric.denied'),
        ('lockedOut', 'biometric.locked_out'),
        ('failure', 'biometric.platform_failure'),
      ]) {
        final result = await _responseOperation(kind, code);
        expect(result.authenticated, isFalse);
      }
    },
  );

  test('missing plugin and platform errors map to fixed safe codes', () async {
    final unavailable = await const StarterBiometricCapability(enabled: true)
        .availability();
    expect(unavailable.code, 'biometric.platform_unavailable');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          throw PlatformException(code: 'private OS lockout detail');
        });
    final availability = await const StarterBiometricCapability(enabled: true)
        .availability();
    expect(availability.code, 'biometric.platform_failure');
    final result = await const StarterBiometricCapability(enabled: true)
        .authenticate(reason: 'Confirm')
        .result;
    expect(result.kind, BiometricResultKind.failure);
    expect(result.code, 'biometric.platform_failure');
    expect(result.toString(), isNot(contains('private')));
  });
}

Map<String, Object?> _response(String kind, String code, String id) => {
  'kind': kind,
  'code': code,
  'requestId': id,
};

Future<BiometricResult> _responseOperation(String kind, String code) async {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
        final id = (call.arguments as Map)['requestId']! as String;
        return _response(kind, code, id);
      });
  return const StarterBiometricCapability(enabled: true)
      .authenticate(reason: 'Test protected action')
      .result;
}

Future<BiometricResult> _responseOperationRaw(Object? response) async {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
        if (response is Map && response['requestId'] == 'echo') {
          return {
            ...response,
            'requestId': (call.arguments as Map)['requestId'],
          };
        }
        return response;
      });
  return const StarterBiometricCapability(enabled: true)
      .authenticate(reason: 'Test protected action')
      .result;
}
