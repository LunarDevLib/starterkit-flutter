import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:starterkit_preferences/starterkit_preferences.dart';

import '../failure/app_failure.dart';
import 'stores.dart';

/// Inert adapter for non-sensitive string preferences.
final class SharedPreferencesPreferenceStore implements PreferenceStore {
  SharedPreferencesPreferenceStore({StarterkitPreferences? preferences})
    : _preferences = preferences ?? StarterkitPreferences();

  static const int maxKeyBytes = 128;
  static const List<String> _sensitiveKeyFragments = [
    'token',
    'access',
    'refresh',
    'password',
    'secret',
    'cookie',
    'auth',
    'apikey',
    'credential',
  ];
  static final RegExp _keyPattern = RegExp(r'^[A-Za-z0-9_.-]+$');

  final StarterkitPreferences _preferences;

  @override
  Future<String?> read(String key) async {
    _validatePreferenceKey(key);
    String? value;
    try {
      value = await _preferences.read(key);
    } on AppFailure {
      rethrow;
    } on Object catch (error) {
      throw _mapPreferenceError(error);
    }
    _validatePreferenceValue(value ?? '');
    return value;
  }

  @override
  Future<void> write(String key, String value) async {
    _validatePreferenceKey(key);
    _validatePreferenceValue(value);
    try {
      await _preferences.write(key, value);
    } on AppFailure {
      rethrow;
    } on Object catch (error) {
      throw _mapPreferenceError(error);
    }
  }

  @override
  Future<void> remove(String key) async {
    _validatePreferenceKey(key);
    try {
      await _preferences.remove(key);
    } on AppFailure {
      rethrow;
    } on Object catch (error) {
      throw _mapPreferenceError(error);
    }
  }

  static void _validatePreferenceKey(String key) {
    if (key.isEmpty ||
        utf8.encode(key).length > maxKeyBytes ||
        !_keyPattern.hasMatch(key)) {
      throw _storageFailure(
        FailureKind.validation,
        'storage.invalid_key',
        'failure.validation',
      );
    }
    final normalized = key.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
    if (_sensitiveKeyFragments.any(normalized.contains)) {
      throw _storageFailure(
        FailureKind.validation,
        'storage.sensitive_preference_key',
        'failure.validation',
      );
    }
  }

  static void _validatePreferenceValue(String value) {
    if (value.contains('\u0000') ||
        utf8.encode(value).length > StoreValueLimits.maxPreferenceValueBytes) {
      throw _storageFailure(
        FailureKind.validation,
        'storage.invalid_value',
        'failure.validation',
      );
    }
  }
}

AppFailure _mapPreferenceError(Object error) {
  if (error is AppFailure) return error;
  if (error is PlatformException) {
    return switch (error.code) {
      'preference.invalid_key' => _storageFailure(
        FailureKind.validation,
        'storage.invalid_key',
        'failure.validation',
      ),
      'preference.invalid_value' => _storageFailure(
        FailureKind.validation,
        'storage.invalid_value',
        'failure.validation',
      ),
      'preference.invalid_arguments' => _storageFailure(
        FailureKind.validation,
        'storage.invalid_arguments',
        'failure.validation',
      ),
      'preference.missing_plugin' ||
      'preference.detached' ||
      'preference.unavailable' ||
      'preference.operation_failed' => _storageFailure(
        FailureKind.unavailable,
        'storage.preference_unavailable',
        'failure.unavailable',
      ),
      _ => _storageFailure(
        FailureKind.unavailable,
        'storage.preference_operation_failed',
        'failure.unavailable',
      ),
    };
  }
  if (error is MissingPluginException) {
    return _storageFailure(
      FailureKind.unavailable,
      'storage.preference_plugin_unavailable',
      'failure.unavailable',
    );
  }
  return _storageFailure(
    FailureKind.unavailable,
    'storage.preference_operation_failed',
    'failure.unavailable',
  );
}

/// Lazy secure byte adapter. Android uses the package's standard RSA-OAEP /
/// AES-GCM options; iOS uses a ThisDeviceOnly Keychain accessibility class.
final class FlutterSecureByteStore implements SecureStore {
  FlutterSecureByteStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions.defaultOptions,
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          );

  static const int maxKeyBytes = 128;
  static const int maxEncodedValueLength =
      ((StoreValueLimits.maxSecureValueBytes + 2) ~/ 3) * 4;
  static final RegExp _keyPattern = RegExp(r'^[A-Za-z0-9_.-]+$');

  final FlutterSecureStorage _storage;

  @override
  Future<Uint8List?> read(String key) async {
    _validateSecureKey(key);
    try {
      final encoded = await _storage.read(key: key);
      if (encoded == null) return null;
      if (encoded.length > maxEncodedValueLength) {
        throw _storageFailure(
          FailureKind.validation,
          'storage.invalid_value',
          'failure.validation',
        );
      }
      late final Uint8List decoded;
      try {
        decoded = base64.decode(encoded);
      } on FormatException {
        throw _storageFailure(
          FailureKind.validation,
          'storage.invalid_secure_encoding',
          'failure.validation',
        );
      }
      if (decoded.length > StoreValueLimits.maxSecureValueBytes) {
        throw _storageFailure(
          FailureKind.validation,
          'storage.invalid_value',
          'failure.validation',
        );
      }
      return Uint8List.fromList(decoded);
    } on AppFailure {
      rethrow;
    } on Object catch (error) {
      throw _mapStoreError(error);
    }
  }

  @override
  Future<void> write(String key, Uint8List value) async {
    _validateSecureKey(key);
    if (value.length > StoreValueLimits.maxSecureValueBytes) {
      throw _storageFailure(
        FailureKind.validation,
        'storage.invalid_value',
        'failure.validation',
      );
    }
    final copy = Uint8List.fromList(value);
    final encoded = base64.encode(copy);
    try {
      await _storage.write(key: key, value: encoded);
    } on AppFailure {
      rethrow;
    } on Object catch (error) {
      throw _mapStoreError(error);
    }
  }

  @override
  Future<void> remove(String key) async {
    _validateSecureKey(key);
    try {
      await _storage.delete(key: key);
    } on AppFailure {
      rethrow;
    } on Object catch (error) {
      throw _mapStoreError(error);
    }
  }

  static void _validateSecureKey(String key) {
    if (key.isEmpty ||
        utf8.encode(key).length > maxKeyBytes ||
        !_keyPattern.hasMatch(key)) {
      throw _storageFailure(
        FailureKind.validation,
        'storage.invalid_key',
        'failure.validation',
      );
    }
  }
}

AppFailure _mapStoreError(Object error) {
  if (error is AppFailure) return error;
  if (error is MissingPluginException) {
    return _storageFailure(
      FailureKind.unavailable,
      'storage.plugin_unavailable',
      'failure.unavailable',
    );
  }
  if (error is PlatformException) {
    final code = error.code.toLowerCase();
    if (code.contains('permission') ||
        code.contains('denied') ||
        code.contains('locked') ||
        code.contains('auth')) {
      return _storageFailure(
        FailureKind.forbidden,
        'storage.access_denied',
        'failure.forbidden',
      );
    }
  }
  return _storageFailure(
    FailureKind.unavailable,
    'storage.operation_failed',
    'failure.unavailable',
  );
}

AppFailure _storageFailure(
  FailureKind kind,
  String code,
  String localizationKey,
) => AppFailure(kind, code: code, localizationKey: localizationKey);
