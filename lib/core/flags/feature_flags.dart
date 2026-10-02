/// Immutable local configuration flags. Unknown keys are always disabled.
final class FeatureFlags {
  FeatureFlags([Map<String, bool> values = const <String, bool>{}])
    : _values = Map<String, bool>.unmodifiable(_validatedCopy(values));

  static final RegExp _keyPattern = RegExp(r'^[a-z][a-z0-9_.-]{0,63}$');
  final Map<String, bool> _values;

  Map<String, bool> get values => _values;

  static Map<String, bool> _validatedCopy(Map<String, bool> values) {
    final copy = <String, bool>{};
    for (final entry in values.entries) {
      if (!_keyPattern.hasMatch(entry.key)) {
        throw ArgumentError.value(entry.key, 'key', 'invalid feature flag key');
      }
      copy[entry.key] = entry.value;
    }
    return copy;
  }

  bool isEnabled(String key) =>
      _keyPattern.hasMatch(key) && (_values[key] ?? false);
}
