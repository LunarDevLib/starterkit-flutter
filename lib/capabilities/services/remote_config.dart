import 'dart:convert';

import '../../core/async/cancellation.dart';
import '../../core/network/api_client.dart';
import 'service_safety.dart';

sealed class RemoteValue {
  const RemoteValue();
}

final class RemoteBoolean extends RemoteValue {
  const RemoteBoolean(this.value);
  final bool value;

  @override
  bool operator ==(Object other) =>
      other is RemoteBoolean && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

final class RemoteInteger extends RemoteValue {
  const RemoteInteger(this.value);
  final int value;

  @override
  bool operator ==(Object other) =>
      other is RemoteInteger && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

final class RemoteText extends RemoteValue {
  const RemoteText(this.value);
  final String value;

  @override
  bool operator ==(Object other) => other is RemoteText && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

enum RemoteValueType { boolean, integer, text }

final class RemoteConfigSnapshot {
  RemoteConfigSnapshot({
    required this.version,
    required this.expiresAt,
    required Map<String, RemoteValue> values,
  }) : values = Map.unmodifiable(values);

  final int version;
  final DateTime expiresAt;
  final Map<String, RemoteValue> values;
}

abstract interface class FeatureFlagReading {
  RemoteValue? value(String key);
}

final class FeatureFlagStore implements FeatureFlagReading {
  FeatureFlagStore({
    required Map<String, RemoteValue> defaults,
    required DateTime Function() now,
  }) : _defaults = Map.unmodifiable(defaults),
       _now = now,
       _snapshot = RemoteConfigSnapshot(
         version: 0,
         expiresAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
         values: defaults,
       );

  final Map<String, RemoteValue> _defaults;
  final DateTime Function() _now;
  RemoteConfigSnapshot _snapshot;

  @override
  RemoteValue? value(String key) {
    final current = _snapshot;
    if (current.version == 0 || !current.expiresAt.isAfter(_now())) {
      return _defaults[key];
    }
    return current.values[key];
  }

  RemoteConfigSnapshot get snapshot => _snapshot;

  void apply(RemoteConfigSnapshot snapshot) {
    _snapshot = snapshot;
  }
}

/// Explicit, atomic remote configuration fetcher.
///
/// Construction performs no I/O. A successful fetch can update only the typed,
/// allowlisted keys supplied at construction. Invalid or stale fetches never
/// partially replace the active snapshot.
final class RemoteConfigService {
  RemoteConfigService({
    required ApiClient client,
    required Map<String, RemoteValue> defaults,
    required Map<String, RemoteValueType> allowedSchema,
    String endpoint = 'config/snapshot',
    DateTime Function()? now,
  }) : _client = client,
       _endpoint = ServiceSafety.endpoint(endpoint),
       _defaults = Map.unmodifiable(defaults),
       _schema = Map.unmodifiable(allowedSchema),
       _now = now ?? DateTime.now,
       _store = FeatureFlagStore(
         defaults: defaults,
         now: now ?? DateTime.now,
       ) {
    _validateLocalSchema(_defaults, _schema);
  }

  final ApiClient _client;
  final String _endpoint;
  final Map<String, RemoteValue> _defaults;
  final Map<String, RemoteValueType> _schema;
  final DateTime Function() _now;
  final FeatureFlagStore _store;
  int _fetchGeneration = 0;

  FeatureFlagReading get flags => _store;
  RemoteConfigSnapshot get snapshot => _store.snapshot;

  Future<void> fetch({CancellationToken? cancellation}) async {
    final generation = ++_fetchGeneration;
    final body = await ServiceSafety.execute(
      _client,
      ApiRequest(
        method: ApiMethod.get,
        path: _endpoint,
        headers: const {'Accept': 'application/json'},
      ),
      maxResponseBytes: 16 * 1024,
      cancellation: cancellation,
    );

    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(body, allowMalformed: false));
    } on Object {
      throw const FormatException('Remote config is invalid.');
    }
    if (decoded is! Map<String, dynamic> ||
        decoded.keys.toSet().difference(
          const {'version', 'expires_at', 'values'},
        ).isNotEmpty ||
        decoded.length != 3) {
      throw const FormatException('Remote config schema is invalid.');
    }

    final version = decoded['version'];
    final expiryRaw = decoded['expires_at'];
    final valuesRaw = decoded['values'];
    if (version is! int ||
        version <= 0 ||
        expiryRaw is! num ||
        !expiryRaw.toDouble().isFinite ||
        valuesRaw is! Map<String, dynamic> ||
        valuesRaw.length > 64) {
      throw const FormatException('Remote config schema is invalid.');
    }

    final expirySeconds = expiryRaw.toDouble();
    if (expirySeconds.abs() > 8640000000000) {
      throw const FormatException('Remote config expiry is invalid.');
    }
    final DateTime expiry;
    try {
      expiry = DateTime.fromMillisecondsSinceEpoch(
        (expirySeconds * 1000).truncate(),
        isUtc: true,
      );
    } on Object {
      throw const FormatException('Remote config expiry is invalid.');
    }
    final current = _now();
    final remaining = expiry.difference(current);
    if (!expiry.isAfter(current) ||
        remaining > const Duration(days: 365)) {
      throw const FormatException('Remote config is expired.');
    }

    final validated = <String, RemoteValue>{};
    for (final entry in valuesRaw.entries) {
      final key = entry.key;
      final type = _schema[key];
      if (type == null || !_isRemoteConfigurableKey(key)) {
        throw const FormatException('Remote config key is invalid.');
      }
      validated[key] = _decodeValue(type, entry.value);
    }

    final next = RemoteConfigSnapshot(
      version: version,
      expiresAt: expiry,
      values: {..._defaults, ...validated},
    );
    if (generation == _fetchGeneration) {
      _store.apply(next);
    }
  }

  static void _validateLocalSchema(
    Map<String, RemoteValue> defaults,
    Map<String, RemoteValueType> schema,
  ) {
    for (final entry in defaults.entries) {
      final type = schema[entry.key];
      if (type == null ||
          !_isRemoteConfigurableKey(entry.key) ||
          !_matchesType(type, entry.value)) {
        throw ArgumentError('Remote config defaults/schema are incompatible.');
      }
    }
    for (final key in schema.keys) {
      if (!_isRemoteConfigurableKey(key)) {
        throw ArgumentError('Remote config schema contains an unsafe key.');
      }
    }
  }

  static RemoteValue _decodeValue(RemoteValueType type, Object? raw) {
    return switch (type) {
      RemoteValueType.boolean when raw is bool => RemoteBoolean(raw),
      RemoteValueType.integer when raw is int => RemoteInteger(raw),
      RemoteValueType.text when raw is String &&
            utf8.encode(raw).length <= 128 &&
            !ServiceSafety.hasControl(raw) =>
        RemoteText(raw),
      _ => throw const FormatException('Remote config value is invalid.'),
    };
  }

  static bool _matchesType(RemoteValueType type, RemoteValue value) {
    return switch ((type, value)) {
      (RemoteValueType.boolean, RemoteBoolean()) => true,
      (RemoteValueType.integer, RemoteInteger()) => true,
      (RemoteValueType.text, RemoteText()) => true,
      _ => false,
    };
  }

  static bool _isRemoteConfigurableKey(String key) {
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_.-]{0,63}$').hasMatch(key)) {
      return false;
    }
    final normalized = key.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]'),
      '',
    );
    const protected = {
      'endpoint',
      'host',
      'url',
      'permission',
      'authorization',
      'auth',
      'token',
      'secret',
      'credential',
      'security',
      'trust',
      'certificate',
      'pinning',
      'tls',
    };
    return !protected.any(normalized.contains);
  }
}
