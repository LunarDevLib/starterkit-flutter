import 'dart:convert';

import 'package:flutter/services.dart';

/// Optional access to bounded, non-sensitive native string preferences.
///
/// Construction is inert. Native storage is touched only by a valid operation.
class StarterkitPreferences {
  StarterkitPreferences({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('starterkit/preferences');

  final MethodChannel _channel;

  Future<String?> read(String key) async {
    _validateKey(key);
    final result = await _channel.invokeMethod<Object?>(
      'read',
      <String, Object?>{'key': key},
    );
    if (result == null) return null;
    if (result is String) {
      try {
        _validateValue(result);
      } on PlatformException {
        throw PlatformException(code: 'preference.operation_failed');
      }
      return result;
    }
    throw PlatformException(code: 'preference.operation_failed');
  }

  Future<void> write(String key, String value) async {
    _validateKey(key);
    _validateValue(value);
    await _channel.invokeMethod<void>('write', <String, Object?>{
      'key': key,
      'value': value,
    });
  }

  Future<void> remove(String key) async {
    _validateKey(key);
    await _channel.invokeMethod<void>('remove', <String, Object?>{'key': key});
  }

  static final RegExp _keyPattern = RegExp(r'^[A-Za-z0-9_.-]+$');
  static const _sensitiveFragments = <String>[
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

  static void _validateKey(String key) {
    final normalized = key.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
    if (key.isEmpty ||
        utf8.encode(key).length > 128 ||
        !_keyPattern.hasMatch(key) ||
        _sensitiveFragments.any(normalized.contains)) {
      throw PlatformException(code: 'preference.invalid_key');
    }
  }

  static void _validateValue(String value) {
    if (value.contains('\u0000') || utf8.encode(value).length > 4096) {
      throw PlatformException(code: 'preference.invalid_value');
    }
  }
}
