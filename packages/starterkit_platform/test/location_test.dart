import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:starterkit_platform/starterkit_platform.dart';

const _channel = MethodChannel('starterkit/platform/location');
const _validId = '0123456789abcdef0123456789abcdef';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  test('disabled capability makes zero platform calls', () async {
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls++;
          return null;
        });
    const location = StarterLocationCapability();
    expect((await location.permissionStatus()).code, 'location.disabled');
    expect(
      (await location.requestPermission().result).code,
      'location.disabled',
    );
    expect((await location.locate().result).code, 'location.disabled');
    expect(await location.requestPermission().cancel(), isFalse);
    expect(await location.locate().cancel(), isFalse);
    expect(calls, 0);
  });

  test('limits enforce hard bounds at runtime', () {
    expect(
      () => const LocationLimits(timeoutMillis: 0).validate(),
      throwsArgumentError,
    );
    expect(
      () => const LocationLimits(timeoutMillis: 60001).validate(),
      throwsArgumentError,
    );
    expect(
      () => const LocationLimits(maxAgeMillis: 0).validate(),
      throwsArgumentError,
    );
    expect(
      () => const LocationLimits(maxAgeMillis: 60001).validate(),
      throwsArgumentError,
    );
  });

  test('public sample constructor rejects invalid values at runtime', () {
    ForegroundLocation valid = ForegroundLocation(
      latitude: -90,
      longitude: 180,
      accuracyMeters: 0,
      approximate: false,
      ageMillis: LocationLimits.maximumAgeMillis,
    );
    expect(valid.latitude, -90);
    expect(
      () => ForegroundLocation(
        latitude: double.nan,
        longitude: 0,
        accuracyMeters: 0,
        approximate: false,
        ageMillis: 0,
      ),
      throwsArgumentError,
    );
    expect(
      () => ForegroundLocation(
        latitude: 0,
        longitude: -181,
        accuracyMeters: 0,
        approximate: false,
        ageMillis: 0,
      ),
      throwsArgumentError,
    );
    expect(
      () => ForegroundLocation(
        latitude: 0,
        longitude: 0,
        accuracyMeters: double.infinity,
        approximate: false,
        ageMillis: 0,
      ),
      throwsArgumentError,
    );
    expect(
      () => ForegroundLocation(
        latitude: 0,
        longitude: 0,
        accuracyMeters: -0.1,
        approximate: false,
        ageMillis: 0,
      ),
      throwsArgumentError,
    );
    expect(
      () => ForegroundLocation(
        latitude: 0,
        longitude: 0,
        accuracyMeters: 0,
        approximate: false,
        ageMillis: -1,
      ),
      throwsArgumentError,
    );
    expect(
      () => ForegroundLocation(
        latitude: 0,
        longitude: 0,
        accuracyMeters: 0,
        approximate: false,
        ageMillis: LocationLimits.maximumAgeMillis + 1,
      ),
      throwsArgumentError,
    );
  });

  test(
    'permission query and explicit request use separate exact payloads',
    () async {
      final seen = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            seen.add(call);
            if (call.method == 'locationPermissionStatus') {
              expect(call.arguments, isNull);
              return _permission(
                'success',
                'location.permission_status',
                'granted',
                true,
              );
            }
            expect(call.method, 'requestLocationPermission');
            final args = Map<String, Object?>.from(call.arguments as Map);
            expect(args.keys.toSet(), {'requestId', 'timeoutMillis'});
            expect(args['requestId'], matches(RegExp(r'^[0-9a-f]{32}$')));
            expect(args['timeoutMillis'], 60000);
            return _permission(
              'success',
              'location.permission_granted',
              'granted',
              false,
              requestId: args['requestId']! as String,
            );
          });
      const location = StarterLocationCapability(enabled: true);
      final status = await location.permissionStatus();
      expect(status.isGranted, isTrue);
      expect(status.approximate, isTrue);
      final requested = await location.requestPermission().result;
      expect(requested.isGranted, isTrue);
      expect(requested.approximate, isFalse);
      expect(seen.map((call) => call.method), [
        'locationPermissionStatus',
        'requestLocationPermission',
      ]);
    },
  );

  test(
    'permission status preserves every informational authorization state',
    () async {
      for (final status in LocationPermissionStatus.values) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_channel, (call) async {
              expect(call.arguments, isNull);
              return _permission(
                'success',
                'location.permission_status',
                status.name,
                status == LocationPermissionStatus.granted ? true : null,
              );
            });
        final result = await const StarterLocationCapability(enabled: true)
            .permissionStatus();
        expect(result.kind, LocationResultKind.success);
        expect(result.status, status);
      }
    },
  );

  test(
    'permission query preserves missing-config and safe native outcomes',
    () async {
      final responses = <Map<String, Object?>>[
        _permission(
          'unavailable',
          'location.permission_not_configured',
          'unavailable',
          null,
        ),
        _permission(
          'unavailable',
          'location.provider_disabled',
          'unavailable',
          null,
        ),
        _permission(
          'failure',
          'location.platform_failure',
          'unavailable',
          null,
        ),
      ];
      for (final response in responses) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_channel, (call) async => response);
        final result = await const StarterLocationCapability(enabled: true)
            .permissionStatus();
        expect(result.kind.name, response['kind']);
        expect(result.code, response['code']);
        expect(result.status, LocationPermissionStatus.unavailable);
      }
    },
  );

  test(
    'locate never prompts and decodes a bounded reduced-accuracy sample',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            expect(call.method, 'locate');
            final args = Map<String, Object?>.from(call.arguments as Map);
            expect(args.keys.toSet(), {
              'requestId',
              'timeoutMillis',
              'maxAgeMillis',
            });
            expect(args['requestId'], matches(RegExp(r'^[0-9a-f]{32}$')));
            expect(args['timeoutMillis'], 15000);
            expect(args['maxAgeMillis'], 5000);
            return _sample(args['requestId']! as String, approximate: true);
          });
      final result = await const StarterLocationCapability(enabled: true)
          .locate()
          .result;
      expect(result.isSuccess, isTrue);
      expect(result.location?.approximate, isTrue);
      expect(result.location?.latitude, 51.5);
    },
  );

  test(
    'denied, restricted, provider-disabled and conflict remain distinct',
    () async {
      var permissionKind = 'denied';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            final id = (call.arguments as Map)['requestId']! as String;
            return _permission(
              permissionKind,
              'location.$permissionKind',
              permissionKind,
              null,
              requestId: id,
            );
          });
      const location = StarterLocationCapability(enabled: true);
      expect(
        (await location.requestPermission().result).kind,
        LocationResultKind.denied,
      );
      permissionKind = 'restricted';
      expect(
        (await location.requestPermission().result).kind,
        LocationResultKind.restricted,
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            final id = (call.arguments as Map)['requestId'];
            if (call.method == 'requestLocationPermission') {
              return _permission(
                'conflict',
                'location.operation_in_progress',
                'unavailable',
                null,
                requestId: id! as String,
              );
            }
            return {
              'kind': 'unavailable',
              'code': 'location.provider_disabled',
              'requestId': id,
            };
          });
      final unavailable = await location.locate().result;
      expect(unavailable.kind, LocationResultKind.unavailable);
      expect(unavailable.code, 'location.provider_disabled');
      final conflict = await location.requestPermission().result;
      expect(conflict.kind, LocationResultKind.conflict);
    },
  );

  test(
    'malformed envelopes and non-double/nonfinite coordinates fail closed',
    () async {
      final base = _sample(_validId)['location']! as Map<String, Object?>;
      final invalidLocations = <Map<String, Object?>>[
        {...base, 'latitude': 91.0},
        {...base, 'latitude': -90.01},
        {...base, 'latitude': 1},
        {...base, 'latitude': double.nan},
        {...base, 'longitude': 180.01},
        {...base, 'longitude': -180.01},
        {...base, 'longitude': 181},
        {...base, 'accuracyMeters': -1.0},
        {...base, 'accuracyMeters': double.nan},
        {...base, 'accuracyMeters': double.infinity},
        {...base, 'accuracyMeters': 1},
        {...base, 'ageMillis': -1},
        {...base, 'ageMillis': 5001},
        {...base, 'ageMillis': 1.5},
        {...base, 'approximate': 'false'},
        {...base, 'unexpected': true},
        {'latitude': 1.0},
      ];
      for (final location in invalidLocations) {
        final result = await _locateResponse({
          'kind': 'success',
          'code': 'location.success',
          'requestId': _validId,
          'location': location,
        });
        expect(result.kind, LocationResultKind.invalid, reason: '$location');
        expect(result.code, 'location.invalid_native_response');
      }
      for (final location in <Map<String, Object?>>[
        {...base, 'latitude': -90.0},
        {...base, 'latitude': 90.0},
        {...base, 'longitude': -180.0},
        {...base, 'longitude': 180.0},
        {...base, 'ageMillis': 5000},
      ]) {
        final result = await _locateResponse({
          'kind': 'success',
          'code': 'location.success',
          'requestId': _validId,
          'location': location,
        });
        expect(result.kind, LocationResultKind.success, reason: '$location');
      }
      final maxAgeAllowed = await _locateResponse({
        'kind': 'success',
        'code': 'location.success',
        'requestId': _validId,
        'location': {...base, 'ageMillis': 60000},
      }, limits: const LocationLimits(maxAgeMillis: 60000));
      expect(maxAgeAllowed.kind, LocationResultKind.success);
    },
  );

  test(
    'wrong request ID, unknown and mismatched native outcomes fail as invalid',
    () async {
      final wrongId = await _locateResponse(
        _sample('f'.padLeft(32, 'f')),
        echoId: false,
      );
      expect(wrongId.kind, LocationResultKind.invalid);
      for (final response in <Map<String, Object?>>[
        {'kind': 'what', 'code': 'location.success', 'requestId': _validId},
        {
          'kind': 'success',
          'code': 'location.provider_disabled',
          'requestId': _validId,
          'location': (_sample(_validId)['location']! as Map),
        },
        {
          'kind': 'unavailable',
          'code': 'location.not_a_code',
          'requestId': _validId,
        },
        {
          'kind': 'success',
          'code': 'location.success',
          'requestId': _validId,
          'location': (_sample(_validId)['location']! as Map)
            ..remove('ageMillis'),
        },
      ]) {
        final result = await _locateResponse(response);
        expect(result.kind, LocationResultKind.invalid);
      }
    },
  );

  test('permission response IDs and envelope shape are strict', () async {
    for (final wrong in <Map<String, Object?>>[
      _permission(
        'success',
        'location.permission_granted',
        'granted',
        true,
        requestId: _validId,
      ),
      {
        ..._permission(
          'success',
          'location.permission_granted',
          'granted',
          true,
          requestId: _validId,
        ),
        'extra': true,
      },
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async => wrong);
      final result = await const StarterLocationCapability(enabled: true)
          .requestPermission()
          .result;
      expect(result.kind, LocationResultKind.invalid);
      expect(result.code, 'location.invalid_native_response');
    }

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          _channel,
          (call) async => {
            ..._permission(
              'success',
              'location.permission_status',
              'denied',
              null,
            ),
            'requestId': _validId,
          },
        );
    final query = await const StarterLocationCapability(enabled: true)
        .permissionStatus();
    expect(query.kind, LocationResultKind.invalid);
  });

  test('native outcome kind/code matrix remains distinct', () async {
    const pairs = <(String, String)>[
      ('cancelled', 'location.cancelled'),
      ('cancelled', 'location.backgrounded'),
      ('cancelled', 'location.activity_detached'),
      ('cancelled', 'location.engine_detached'),
      ('denied', 'location.denied'),
      ('restricted', 'location.restricted'),
      ('unavailable', 'location.disabled'),
      ('unavailable', 'location.platform_unavailable'),
      ('unavailable', 'location.permission_not_configured'),
      ('unavailable', 'location.permission_required'),
      ('unavailable', 'location.provider_disabled'),
      ('unavailable', 'location.provider_unavailable'),
      ('unavailable', 'location.foreground_required'),
      ('unavailable', 'location.activity_unavailable'),
      ('timeout', 'location.timeout'),
      ('invalid', 'location.invalid_request'),
      ('invalid', 'location.invalid_limits'),
      ('invalid', 'location.invalid_coordinate'),
      ('invalid', 'location.invalid_accuracy'),
      ('invalid', 'location.sample_stale'),
      ('invalid', 'location.invalid_sample_time'),
      ('invalid', 'location.invalid_native_response'),
      ('conflict', 'location.operation_in_progress'),
      ('failure', 'location.platform_failure'),
      ('failure', 'location.request_codes_exhausted'),
    ];
    for (final (kind, code) in pairs) {
      final result = await _locateResponse({
        'kind': kind,
        'code': code,
        'requestId': _validId,
      });
      expect(result.kind.name, kind);
      expect(result.code, code);
    }
  });

  test('request cancellation is scoped to generated request ID', () async {
    final pending = Completer<Object?>();
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          if (call.method == 'locate') return pending.future;
          return true;
        });
    const location = StarterLocationCapability(enabled: true);
    final first = location.locate();
    final firstResult = first.result;
    expect(await first.cancel(), isTrue);
    expect((await firstResult).kind, LocationResultKind.cancelled);
    final second = location.locate();
    final secondId =
        (calls.where((call) => call.method == 'locate').last.arguments
            as Map)['requestId'];
    expect(
      secondId,
      isNot(
        (calls.where((call) => call.method == 'locate').first.arguments
            as Map)['requestId'],
      ),
    );
    expect(
      calls.where((call) => call.method == 'cancelLocation').single.arguments,
      {
        'requestId':
            (calls.where((call) => call.method == 'locate').first.arguments
                as Map)['requestId'],
      },
    );
    await second.cancel();
    await second.result;
    final cancellationsBeforeOldCancel = calls
        .where((call) => call.method == 'cancelLocation')
        .length;
    expect(await first.cancel(), isFalse);
    expect(
      calls.where((call) => call.method == 'cancelLocation').length,
      cancellationsBeforeOldCancel,
    );
    pending.complete(
      null,
    ); // Late native completion cannot replace either terminal result.
    expect((await first.result).kind, LocationResultKind.cancelled);
  });

  testWidgets('permission request timeout settles exactly once', (
    tester,
  ) async {
    final pending = Completer<Object?>();
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          if (call.method == 'requestLocationPermission') return pending.future;
          return true;
        });
    final op = const StarterLocationCapability(enabled: true)
        .requestPermission(timeoutMillis: 1);
    await tester.pump(const Duration(milliseconds: 2));
    expect((await op.result).kind, LocationResultKind.timeout);
    expect(calls.where((call) => call.method == 'cancelLocation').length, 1);
    pending.complete(null);
    expect((await op.result).kind, LocationResultKind.timeout);
  });

  test(
    'permission response after monotonic deadline beats delayed watchdog',
    () async {
      final pending = Completer<Object?>();
      final dispatched = Completer<void>();
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            calls.add(call);
            if (call.method == 'requestLocationPermission') {
              dispatched.complete();
              return pending.future;
            }
            return true;
          });
      final operation = const StarterLocationCapability(enabled: true)
          .requestPermission(timeoutMillis: 25);
      await dispatched.future.timeout(const Duration(seconds: 2));
      final requestId = (calls.first.arguments as Map)['requestId']! as String;
      _blockEventLoopFor(const Duration(milliseconds: 40));
      pending.complete(
        _permission(
          'success',
          'location.permission_granted',
          'granted',
          true,
          requestId: requestId,
        ),
      );

      final result = await operation.result;
      await Future<void>.delayed(Duration.zero);
      expect(result.kind, LocationResultKind.timeout);
      expect(result.code, 'location.timeout');
      expect(result.requestId, requestId);
      final cancellations = calls
          .where((call) => call.method == 'cancelLocation')
          .toList();
      expect(cancellations, hasLength(1));
      expect(cancellations.single.arguments, {'requestId': requestId});
    },
  );

  test(
    'location response after monotonic deadline beats delayed watchdog',
    () async {
      final pending = Completer<Object?>();
      final dispatched = Completer<void>();
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            calls.add(call);
            if (call.method == 'locate') {
              dispatched.complete();
              return pending.future;
            }
            return true;
          });
      final operation = const StarterLocationCapability(enabled: true)
          .locate(limits: const LocationLimits(timeoutMillis: 25));
      await dispatched.future.timeout(const Duration(seconds: 2));
      final requestId = (calls.first.arguments as Map)['requestId']! as String;
      _blockEventLoopFor(const Duration(milliseconds: 40));
      pending.complete(_sample(requestId));

      final result = await operation.result;
      await Future<void>.delayed(Duration.zero);
      expect(result.kind, LocationResultKind.timeout);
      expect(result.code, 'location.timeout');
      expect(result.requestId, requestId);
      final cancellations = calls
          .where((call) => call.method == 'cancelLocation')
          .toList();
      expect(cancellations, hasLength(1));
      expect(cancellations.single.arguments, {'requestId': requestId});
    },
  );

  test(
    'late exception mappings cannot beat an expired monotonic deadline',
    () async {
      final lateErrors = <Object>[
        MissingPluginException('late missing plugin'),
        PlatformException(code: 'late platform error'),
        StateError('late decoding or transport error'),
      ];
      for (final error in lateErrors) {
        final pending = Completer<Object?>();
        final dispatched = Completer<void>();
        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_channel, (call) async {
              calls.add(call);
              if (call.method == 'locate') {
                dispatched.complete();
                return pending.future;
              }
              return true;
            });
        final operation = const StarterLocationCapability(enabled: true)
            .locate(limits: const LocationLimits(timeoutMillis: 25));
        await dispatched.future.timeout(const Duration(seconds: 2));
        final requestId =
            (calls.first.arguments as Map)['requestId']! as String;
        _blockEventLoopFor(const Duration(milliseconds: 40));
        pending.completeError(error);

        final result = await operation.result;
        await Future<void>.delayed(Duration.zero);
        expect(result.kind, LocationResultKind.timeout, reason: '$error');
        expect(result.code, 'location.timeout', reason: '$error');
        expect(result.requestId, requestId);
        final cancellations = calls
            .where((call) => call.method == 'cancelLocation')
            .toList();
        expect(cancellations, hasLength(1), reason: '$error');
        expect(cancellations.single.arguments, {'requestId': requestId});
      }
    },
  );

  test(
    'manual cancel after deadline settles timeout and cancels native once',
    () async {
      final pending = Completer<Object?>();
      final dispatched = Completer<void>();
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            calls.add(call);
            if (call.method == 'locate') {
              dispatched.complete();
              return pending.future;
            }
            return true;
          });
      final operation = const StarterLocationCapability(enabled: true)
          .locate(limits: const LocationLimits(timeoutMillis: 25));
      await dispatched.future.timeout(const Duration(seconds: 2));
      final requestId = (calls.first.arguments as Map)['requestId']! as String;
      _blockEventLoopFor(const Duration(milliseconds: 40));

      expect(await operation.cancel(), isFalse);
      final result = await operation.result;
      expect(result.kind, LocationResultKind.timeout);
      expect(result.code, 'location.timeout');
      expect(result.requestId, requestId);
      pending.complete(_sample(requestId));
      await Future<void>.delayed(Duration.zero);
      expect((await operation.result).kind, LocationResultKind.timeout);
      final cancellations = calls
          .where((call) => call.method == 'cancelLocation')
          .toList();
      expect(cancellations, hasLength(1));
      expect(cancellations.single.arguments, {'requestId': requestId});
    },
  );

  test(
    'permission request cancellation is scoped and settles caller',
    () async {
      final pending = Completer<Object?>();
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            calls.add(call);
            if (call.method == 'requestLocationPermission') {
              return pending.future;
            }
            return true;
          });
      final operation = const StarterLocationCapability(enabled: true)
          .requestPermission();
      await Future<void>.delayed(Duration.zero);
      final requestId = (calls.first.arguments as Map)['requestId'];
      expect(await operation.cancel(), isTrue);
      expect((await operation.result).kind, LocationResultKind.cancelled);
      expect(
        calls.where((call) => call.method == 'cancelLocation').single.arguments,
        {'requestId': requestId},
      );
      pending.complete(null);
      expect((await operation.result).kind, LocationResultKind.cancelled);
    },
  );

  testWidgets('cancellation acknowledgement false or hanging is bounded', (
    tester,
  ) async {
    final pending = Completer<Object?>();
    var cancelCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'locate') return pending.future;
          cancelCalls++;
          if (cancelCalls == 1) return false;
          return Completer<Object?>().future;
        });
    const location = StarterLocationCapability(enabled: true);
    final falseAck = location.locate();
    expect(await falseAck.cancel(), isFalse);
    expect((await falseAck.result).kind, LocationResultKind.cancelled);

    final hungAck = location.locate();
    final cancelFuture = hungAck.cancel();
    var cancelCompleted = false;
    cancelFuture.then((_) => cancelCompleted = true);
    await tester.pump(const Duration(milliseconds: 999));
    expect(cancelCalls, 2);
    expect(cancelCompleted, isFalse);
    await tester.pump(const Duration(milliseconds: 2));
    expect(await cancelFuture, isFalse);
    expect(cancelCompleted, isTrue);
    expect((await hungAck.result).kind, LocationResultKind.cancelled);
    pending.complete(null);
  });

  test('conflict leaves incumbent native operation untouched', () async {
    final incumbent = Completer<Object?>();
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          if (call.method == 'locate') return incumbent.future;
          if (call.method == 'requestLocationPermission') {
            final id = (call.arguments as Map)['requestId']! as String;
            return _permission(
              'conflict',
              'location.operation_in_progress',
              'unavailable',
              null,
              requestId: id,
            );
          }
          return false;
        });
    const location = StarterLocationCapability(enabled: true);
    final locate = location.locate();
    final permission = await location.requestPermission().result;
    expect(permission.kind, LocationResultKind.conflict);
    expect(calls.where((call) => call.method == 'cancelLocation'), isEmpty);
    final id = (calls.first.arguments as Map)['requestId']! as String;
    incumbent.complete(_sample(id));
    expect((await locate.result).kind, LocationResultKind.success);
    expect(calls.where((call) => call.method == 'cancelLocation'), isEmpty);
  });

  testWidgets('watchdog settles once, cancels its ID, and ignores late reply', (
    tester,
  ) async {
    final pending = Completer<Object?>();
    var cancelCount = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'locate') return pending.future;
          cancelCount++;
          return true;
        });
    final op = const StarterLocationCapability(enabled: true)
        .locate(limits: const LocationLimits(timeoutMillis: 1));
    await tester.pump(const Duration(milliseconds: 2));
    final result = await op.result;
    expect(result.kind, LocationResultKind.timeout);
    await tester.pump();
    expect(cancelCount, 1);
    pending.complete(_sample(result.requestId!));
    expect((await op.result).kind, LocationResultKind.timeout);
  });

  test('missing plugin and platform exceptions map to safe results', () async {
    final missing = await const StarterLocationCapability(enabled: true)
        .locate()
        .result;
    expect(missing.kind, LocationResultKind.unavailable);
    expect(missing.code, 'location.platform_unavailable');

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          throw PlatformException(code: 'private native detail');
        });
    final failure = await const StarterLocationCapability(enabled: true)
        .locate()
        .result;
    expect(failure.code, 'location.platform_failure');
    expect(failure.code, isNot(contains('private')));
  });
}

Map<String, Object?> _permission(
  String kind,
  String code,
  String status,
  Object? approximate, {
  String? requestId,
}) => {
  'kind': kind,
  'code': code,
  'status': status,
  'approximate': approximate,
  if (requestId != null) 'requestId': requestId,
};

Map<String, Object?> _sample(String id, {bool approximate = false}) => {
  'kind': 'success',
  'code': 'location.success',
  'requestId': id,
  'location': {
    'latitude': 51.5,
    'longitude': -0.12,
    'accuracyMeters': 42.0,
    'approximate': approximate,
    'ageMillis': 1200,
  },
};

Future<LocationResult> _locateResponse(
  Map<String, Object?> response, {
  LocationLimits limits = const LocationLimits(),
  bool echoId = true,
}) async {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
        final id = (call.arguments as Map)['requestId']! as String;
        return {...response, if (echoId) 'requestId': id};
      });
  return const StarterLocationCapability(enabled: true)
      .locate(limits: limits)
      .result;
}

void _blockEventLoopFor(Duration duration) {
  final stopwatch = Stopwatch()..start();
  while (stopwatch.elapsed < duration) {
    // Intentionally block only for a short duration to defer Timer servicing.
  }
}
