// The async platform interface is used here only as the package's official
// in-memory test seam; the application depends directly on shared_preferences.
// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_starterkit/core/failure/app_failure.dart';
import 'package:flutter_starterkit/core/storage/platform_stores.dart';
import 'package:flutter_starterkit/core/storage/stores.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  group('SharedPreferencesPreferenceStore', () {
    late SharedPreferencesAsyncPlatform? oldPlatform;

    setUp(() {
      oldPlatform = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
    });

    tearDown(() {
      SharedPreferencesAsyncPlatform.instance = oldPlatform;
    });

    test(
      'is lazy, stores strings, reads missing as null, and removes',
      () async {
        var factoryCalls = 0;
        final store = SharedPreferencesPreferenceStore(
          createPreferences: () {
            factoryCalls++;
            return SharedPreferencesAsync();
          },
        );
        expect(factoryCalls, 0);
        expect(await store.read('settings.theme'), isNull);
        expect(factoryCalls, 1);
        await store.write('settings.theme', 'dark');
        expect(await store.read('settings.theme'), 'dark');
        await store.remove('settings.theme');
        expect(await store.read('settings.theme'), isNull);
      },
    );

    test(
      'rejects sensitive normalized key variants and oversized values',
      () async {
        final store = SharedPreferencesPreferenceStore();
        for (final key in [
          'access-token',
          'refresh_token_cache',
          'userPasswordHint',
          'oauthSecret',
          'cookieJar',
          'auth-header-mode',
          'api.key.value',
          'credentialHint',
        ]) {
          await expectLater(
            store.write(key, 'value'),
            throwsA(
              isA<AppFailure>().having(
                (failure) => failure.code,
                'code',
                'storage.sensitive_preference_key',
              ),
            ),
          );
        }
        await store.write('safe.preference', 'é' * 2048);
        await expectLater(
          store.write('safe.preference', 'é' * 2049),
          throwsA(isA<AppFailure>()),
        );
      },
    );

    test(
      'maps platform and missing-plugin failures without raw details',
      () async {
        SharedPreferencesAsyncPlatform.instance = _FailingPreferences(
          PlatformException(
            code: 'permission_denied',
            message: 'secret detail',
          ),
        );
        await expectLater(
          SharedPreferencesPreferenceStore().read('safe.key'),
          throwsA(
            isA<AppFailure>()
                .having(
                  (failure) => failure.kind,
                  'kind',
                  FailureKind.forbidden,
                )
                .having(
                  (failure) => failure.toString(),
                  'safe error text',
                  isNot(contains('secret detail')),
                ),
          ),
        );
        final missing = SharedPreferencesPreferenceStore(
          createPreferences: () =>
              throw MissingPluginException('private detail'),
        );
        await expectLater(
          missing.read('safe.key'),
          throwsA(
            isA<AppFailure>().having(
              (failure) => failure.kind,
              'kind',
              FailureKind.unavailable,
            ),
          ),
        );
      },
    );
  });

  group('FlutterSecureByteStore', () {
    test('copies bytes across await and base64 storage boundaries', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final store = FlutterSecureByteStore();
      final source = Uint8List.fromList([1, 2, 3, 4]);
      final write = store.write('session_credential', source);
      source[0] = 9;
      await write;
      final read = await store.read('session_credential');
      expect(read, [1, 2, 3, 4]);
      read![1] = 9;
      expect(await store.read('session_credential'), [1, 2, 3, 4]);
      await store.remove('session_credential');
      expect(await store.read('session_credential'), isNull);
      await store.write(
        'max_payload',
        Uint8List(StoreValueLimits.maxSecureValueBytes),
      );
      expect(
        (await store.read('max_payload'))!.length,
        StoreValueLimits.maxSecureValueBytes,
      );
    });

    test(
      'rejects invalid and oversized encoded values before decoding',
      () async {
        FlutterSecureStorage.setMockInitialValues({
          'bad': '%%%not-base64%%%',
          'large': 'A' * (FlutterSecureByteStore.maxEncodedValueLength + 1),
          'decoded-large': base64.encode(
            Uint8List(StoreValueLimits.maxSecureValueBytes + 1),
          ),
        });
        final store = FlutterSecureByteStore();
        await expectLater(store.read('bad'), throwsA(isA<AppFailure>()));
        await expectLater(store.read('large'), throwsA(isA<AppFailure>()));
        await expectLater(
          store.read('decoded-large'),
          throwsA(isA<AppFailure>()),
        );
        await expectLater(
          store.write(
            'large',
            Uint8List(StoreValueLimits.maxSecureValueBytes + 1),
          ),
          throwsA(isA<AppFailure>()),
        );
      },
    );

    test('maps plugin errors to safe AppFailure values', () async {
      final store = FlutterSecureByteStore(
        storage: _FailingFlutterSecureStorage(
          PlatformException(code: 'user_locked', message: 'private text'),
        ),
      );
      await expectLater(
        store.read('session_credential'),
        throwsA(
          isA<AppFailure>()
              .having((failure) => failure.kind, 'kind', FailureKind.forbidden)
              .having(
                (failure) => failure.toString(),
                'safe error text',
                isNot(contains('private text')),
              ),
        ),
      );
    });
  });
}

final class _FailingPreferences extends InMemorySharedPreferencesAsync {
  _FailingPreferences(this.error) : super.empty();

  final Object error;

  @override
  Future<String?> getString(String key, SharedPreferencesOptions options) =>
      Future<String?>.error(error);
}

final class _FailingFlutterSecureStorage extends FlutterSecureStorage {
  _FailingFlutterSecureStorage(this.error);

  final Object error;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => Future<String?>.error(error);
}
