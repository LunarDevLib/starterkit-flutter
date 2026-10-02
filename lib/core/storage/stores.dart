import 'dart:convert';
import 'dart:typed_data';

/// Non-sensitive string persistence. Missing keys return null; failures throw.
/// Implementations must enforce [copyPreferenceValue] on writes.
abstract interface class PreferenceStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> remove(String key);
}

/// Secret byte persistence. Reads and writes must defensively copy values and
/// enforce [copySecureValue]; missing keys return null and failures throw.
abstract interface class SecureStore {
  Future<Uint8List?> read(String key);
  Future<void> write(String key, Uint8List value);
  Future<void> remove(String key);
}

/// Durable logout marker boundary. Missing marker means false; store failures
/// must be surfaced rather than interpreted as absence.
abstract interface class LogoutIntentStore {
  Future<bool> readPending();
  Future<void> markPending();
  Future<void> clear();
}

final class StoreValueLimits {
  StoreValueLimits._();

  static const int maxPreferenceValueBytes = 4 * 1024;
  static const int maxSecureValueBytes = 64 * 1024;
}

String? copyPreferenceValue(String? value) {
  if (value != null &&
      utf8.encode(value).length > StoreValueLimits.maxPreferenceValueBytes) {
    throw ArgumentError(
      'Preference value exceeds the allowed UTF-8 byte limit.',
    );
  }
  return value;
}

Uint8List copySecureValue(Uint8List value) {
  if (value.length > StoreValueLimits.maxSecureValueBytes) {
    throw ArgumentError.value(
      value.length,
      'value',
      'exceeds secure value limit',
    );
  }
  return Uint8List.fromList(value);
}
