// Tests inject the package's non-final wrapper; no platform global is mutated.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_starterkit/core/failure/app_failure.dart';
import 'package:flutter_starterkit/core/storage/platform_stores.dart';
import 'package:flutter_starterkit/core/storage/stores.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:starterkit_preferences/starterkit_preferences.dart';

void main() {
  group('SharedPreferencesPreferenceStore', () {
    test(
      'constructor is inert and the injected wrapper stores strings',
      () async {
        final preferences = _MemoryStarterkitPreferences();
        final store = SharedPreferencesPreferenceStore(
          preferences: preferences,
        );
        expect(preferences.calls, isEmpty);
        expect(await store.read('settings.theme'), isNull);
        expect(preferences.calls, ['read:settings.theme']);
        await store.write('settings.theme', 'dark');
        expect(await store.read('settings.theme'), 'dark');
        await store.remove('settings.theme');
        expect(await store.read('settings.theme'), isNull);
        expect(preferences.calls, [
          'read:settings.theme',
          'write:settings.theme',
          'read:settings.theme',
          'remove:settings.theme',
          'read:settings.theme',
        ]);
      },
    );

    test(
      'rejects sensitive keys and invalid values before platform calls',
      () async {
        final preferences = _MemoryStarterkitPreferences();
        final store = SharedPreferencesPreferenceStore(
          preferences: preferences,
        );
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
          throwsA(
            isA<AppFailure>().having(
              (failure) => failure.code,
              'code',
              'storage.invalid_value',
            ),
          ),
        );
        preferences.values['oversized.read'] = 'é' * 2049;
        await expectLater(
          store.read('oversized.read'),
          throwsA(isA<AppFailure>()),
        );
        expect(preferences.calls, [
          'write:safe.preference',
          'read:oversized.read',
        ]);
      },
    );

    test('maps fixed platform codes without exposing native details', () async {
      final preferences = _MemoryStarterkitPreferences();
      final store = SharedPreferencesPreferenceStore(preferences: preferences);
      for (final entry in {
        'preference.invalid_key': (
          'storage.invalid_key',
          FailureKind.validation,
        ),
        'preference.invalid_value': (
          'storage.invalid_value',
          FailureKind.validation,
        ),
        'preference.invalid_arguments': (
          'storage.invalid_arguments',
          FailureKind.validation,
        ),
        'preference.missing_plugin': (
          'storage.preference_unavailable',
          FailureKind.unavailable,
        ),
        'preference.detached': (
          'storage.preference_unavailable',
          FailureKind.unavailable,
        ),
        'preference.unavailable': (
          'storage.preference_unavailable',
          FailureKind.unavailable,
        ),
        'preference.operation_failed': (
          'storage.preference_unavailable',
          FailureKind.unavailable,
        ),
      }.entries) {
        preferences.readError = PlatformException(
          code: entry.key,
          message: 'private detail',
        );
        await expectLater(
          store.read('safe.key'),
          throwsA(
            isA<AppFailure>()
                .having((failure) => failure.code, 'code', entry.value.$1)
                .having((failure) => failure.kind, 'kind', entry.value.$2)
                .having(
                  (failure) => failure.toString(),
                  'safe error text',
                  isNot(contains('private detail')),
                ),
          ),
        );
      }
      preferences.readError = MissingPluginException('private detail');
      await expectLater(
        store.read('safe.key'),
        throwsA(
          isA<AppFailure>().having(
            (failure) => failure.kind,
            'kind',
            FailureKind.unavailable,
          ),
        ),
      );
      preferences.readError = null;
      preferences.readValue = Object();
      await expectLater(store.read('safe.key'), throwsA(isA<AppFailure>()));
    });
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

final class _MemoryStarterkitPreferences extends StarterkitPreferences {
  _MemoryStarterkitPreferences();

  final Map<String, Object?> values = {};
  final List<String> calls = [];
  Object? readError;
  Object? writeError;
  Object? removeError;
  Object? readValue;

  @override
  Future<String?> read(String key) async {
    calls.add('read:$key');
    if (readError case final error?) throw error;
    if (readValue != null) return readValue as String?;
    return values[key] as String?;
  }

  @override
  Future<void> write(String key, String value) async {
    calls.add('write:$key');
    if (writeError case final error?) throw error;
    values[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    calls.add('remove:$key');
    if (removeError case final error?) throw error;
    values.remove(key);
  }
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
