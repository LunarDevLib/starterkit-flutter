import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:starterkit_preferences/starterkit_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channelName = 'starterkit/preferences';
  const channel = MethodChannel(channelName);

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  test('construction is inert and methods use exact wire contract', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'read') return 'value';
          return null;
        });

    final preferences = StarterkitPreferences();
    expect(calls, isEmpty);
    expect(await preferences.read('display.name'), 'value');
    await preferences.write('display.name', 'hello');
    await preferences.remove('display.name');
    expect(calls.map((call) => call.method), ['read', 'write', 'remove']);
    expect(calls.map((call) => call.arguments), [
      {'key': 'display.name'},
      {'key': 'display.name', 'value': 'hello'},
      {'key': 'display.name'},
    ]);
  });

  test('rejects invalid keys and values before channel invocation', () async {
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls++;
          return null;
        });
    final preferences = StarterkitPreferences();
    for (final key in [
      '',
      'has space',
      'a' * 129,
      'my_access_value',
      'authz',
    ]) {
      await expectLater(
        preferences.read(key),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'preference.invalid_key',
          ),
        ),
      );
    }
    await expectLater(
      preferences.write('valid', 'x' * 4097),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'preference.invalid_value',
        ),
      ),
    );
    await expectLater(
      preferences.write('valid', 'no\u0000nul'),
      throwsA(isA<PlatformException>()),
    );
    expect(calls, 0);
  });

  test(
    'preserves absent reads and rejects a wrong native return type',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => null);
      expect(await StarterkitPreferences().read('valid'), isNull);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => 42);
      await expectLater(
        StarterkitPreferences().read('valid'),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'preference.operation_failed',
          ),
        ),
      );
    },
  );

  test('validates returned strings before exposing them to callers', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => 'é' * 2048);
    expect(await StarterkitPreferences().read('valid'), 'é' * 2048);

    for (final invalidValue in ['é' * 2049, 'has\u0000nul']) {
      messenger.setMockMethodCallHandler(channel, (_) async => invalidValue);
      await expectLater(
        StarterkitPreferences().read('valid'),
        throwsA(
          isA<PlatformException>()
              .having(
                (error) => error.code,
                'code',
                'preference.operation_failed',
              )
              .having((error) => error.message, 'message', isNull)
              .having((error) => error.details, 'details', isNull),
        ),
      );
    }
  });

  test('propagates native platform failures without exposing values', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          throw PlatformException(code: 'preference.unavailable');
        });
    await expectLater(
      StarterkitPreferences().remove('valid'),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'preference.unavailable',
        ),
      ),
    );
  });
}
