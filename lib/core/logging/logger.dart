enum LogLevel { debug, info, warning, error }

typedef LogSink = void Function(
  LogLevel level,
  String event,
  Map<String, Object?> fields,
);

abstract interface class Logger {
  void debug(String event, {Map<String, Object?> fields = const {}});
  void info(String event, {Map<String, Object?> fields = const {}});
  void warning(String event, {Map<String, Object?> fields = const {}});
  void error(String event, {Map<String, Object?> fields = const {}});
}

/// A vendor-neutral logger boundary which emits only bounded safe primitives.
final class SafeLogger implements Logger {
  SafeLogger(this._sink);

  static const int maxEventLength = 64;
  static const int maxFields = 16;
  static const int maxDepth = 3;
  static const int maxCollectionItems = 16;
  static const int maxPayloadBytes = 4096;
  static const int maxStringLength = 64;

  static final RegExp _safeEvent = RegExp(r'^[a-zA-Z0-9_.:-]{1,64}$');
  static final RegExp _safeString = RegExp(r'^[a-zA-Z0-9_.:-]{1,64}$');
  static const Set<String> _allowedKeys = {
    'module',
    'operation',
    'status',
    'durationms',
    'attempt',
    'result',
    'reason',
    'count',
    'bytes',
    'method',
    'failurekind',
    'code',
    'feature',
    'enabled',
    'environment',
    'level',
    'state',
    'httpstatus',
  };
  static const List<String> _sensitiveFragments = [
    'token',
    'auth',
    'authorization',
    'cookie',
    'password',
    'secret',
    'apikey',
    'credential',
  ];

  final LogSink _sink;

  @override
  void debug(String event, {Map<String, Object?> fields = const {}}) =>
      _write(LogLevel.debug, event, fields);

  @override
  void info(String event, {Map<String, Object?> fields = const {}}) =>
      _write(LogLevel.info, event, fields);

  @override
  void warning(String event, {Map<String, Object?> fields = const {}}) =>
      _write(LogLevel.warning, event, fields);

  @override
  void error(String event, {Map<String, Object?> fields = const {}}) =>
      _write(LogLevel.error, event, fields);

  void _write(LogLevel level, String event, Map<String, Object?> fields) {
    if (event.length > maxEventLength || !_safeEvent.hasMatch(event)) return;
    final sanitized = _sanitizeMap(fields, 0, _ByteBudget(maxPayloadBytes));
    try {
      _sink(level, event, Map<String, Object?>.unmodifiable(sanitized));
    } on Object {
      // Logging is best effort and must not affect application behavior.
    }
  }

  Map<String, Object?> _sanitizeMap(
    Map<Object?, Object?> input,
    int depth,
    _ByteBudget budget,
  ) {
    if (depth >= maxDepth ||
        budget.remaining <= 0 ||
        input.length > maxFields) {
      return const {};
    }
    if (!budget.consume(2)) return const {};
    final result = <String, Object?>{};
    final candidates = <String, List<(String, Object?)>>{};
    for (final entry in input.entries) {
      if (entry.key is! String) continue;
      final originalKey = entry.key as String;
      final normalized = _normalizeKey(originalKey);
      if (!_allowedKeys.contains(normalized) || _isSensitive(normalized)) {
        continue;
      }
      candidates.putIfAbsent(normalized, () => []).add((
        originalKey,
        entry.value,
      ));
    }

    var accepted = 0;
    for (final entry in candidates.entries) {
      if (accepted >= maxFields || entry.value.length != 1) continue;
      final key = entry.key;
      final keyBytes = key.length + 3 + (accepted == 0 ? 0 : 1);
      if (!budget.consume(keyBytes)) continue;
      final value = _sanitizeValue(entry.value.single.$2, depth + 1, budget);
      if (identical(value, _discard)) continue;
      result[key] = value;
      accepted++;
    }
    return result;
  }

  Object? _sanitizeValue(Object? value, int depth, _ByteBudget budget) {
    if (budget.remaining <= 0) return _discard;
    if (value is bool) {
      final bytes = value ? 4 : 5;
      return budget.consume(bytes) ? value : _discard;
    }
    if (value is int) {
      final bytes = value.toString().length;
      return budget.consume(bytes) ? value : _discard;
    }
    if (value is double && value.isFinite) {
      final bytes = value.toString().length;
      return budget.consume(bytes) ? value : _discard;
    }
    if (value is String &&
        value.length <= maxStringLength &&
        _safeString.hasMatch(value)) {
      return budget.consume(value.length + 2) ? value : _discard;
    }
    if (value is Map) {
      final sanitized = _sanitizeMap(value, depth, budget);
      return sanitized.isEmpty
          ? _discard
          : Map<String, Object?>.unmodifiable(sanitized);
    }
    if (value is List && depth < maxDepth) {
      if (!budget.consume(2)) return _discard;
      final result = <Object?>[];
      for (final item in value.take(maxCollectionItems)) {
        if (result.isNotEmpty && !budget.consume(1)) break;
        final safeItem = _sanitizeValue(item, depth + 1, budget);
        if (!identical(safeItem, _discard)) result.add(safeItem);
        if (budget.remaining <= 0) break;
      }
      return result.isEmpty ? _discard : List<Object?>.unmodifiable(result);
    }
    return _discard;
  }

  static String _normalizeKey(String key) =>
      key.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

  static bool _isSensitive(String normalizedKey) =>
      _sensitiveFragments.any(normalizedKey.contains);
}

const Object _discard = Object();

final class _ByteBudget {
  _ByteBudget(this.remaining);

  int remaining;

  bool consume(int count) {
    if (count < 0 || count > remaining) return false;
    remaining -= count;
    return true;
  }
}
