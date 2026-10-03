import 'dart:convert';

enum RemoteValueType { boolean, integer, text }

/// Closed typed values, not arbitrary objects or capability metadata.
final class RemoteValue {
  const RemoteValue.boolean(bool this.value) : type = RemoteValueType.boolean;
  const RemoteValue.integer(int this.value) : type = RemoteValueType.integer;
  const RemoteValue.text(String this.value) : type = RemoteValueType.text;

  final RemoteValueType type;
  final Object value;
}

/// Product GET + Accept application/json port. Join [relativePath] beneath the
/// stable base directory, appending a slash if absent. Product owns credentials,
/// TLS, redirects, acquisition limits, headers, routing and timeouts.
abstract interface class RemoteConfigReader {
  Uri get baseEndpoint;
  Future<RemoteConfigResponse> read(String relativePath);
}

final class RemoteConfigResponse {
  RemoteConfigResponse({required this.statusCode, required List<int> body})
    : body = List<int>.unmodifiable(body);

  final int statusCode;
  final List<int> body;
}

/// Stored diagnostic data may be expired. Consumers should use the expiry-aware
/// [FeatureFlagReading] view rather than reading this map directly.
final class RemoteConfigSnapshot {
  RemoteConfigSnapshot({
    required this.version,
    required this.expiresAt,
    required Map<String, RemoteValue> values,
  }) : values = Map<String, RemoteValue>.unmodifiable(values);

  final int version;
  final DateTime? expiresAt;
  final Map<String, RemoteValue> values;
}

abstract interface class FeatureFlagReading {
  RemoteValue? value(String key);
}

enum RemoteConfigFetchKind {
  applied,
  disabled,
  unavailable,
  invalid,
  failure,
  superseded,
}

final class RemoteConfigFetchResult {
  const RemoteConfigFetchResult._(this.kind, this.code, [this.snapshot]);

  final RemoteConfigFetchKind kind;
  final String code;
  final RemoteConfigSnapshot? snapshot;
}

/// Explicit, in-memory and disabled by default. Atomic publication is confined
/// to one isolate; flags are not authorization or other security boundaries.
final class StarterRemoteConfigService {
  StarterRemoteConfigService({
    this.enabled = false,
    this.reader,
    this.endpoint = 'config/snapshot',
    Set<String> allowedHosts = const {},
    Map<String, RemoteValue> defaults = const {},
    Map<String, RemoteValueType> allowedSchema = const {},
    DateTime Function()? now,
  }) : _allowedHosts = Set<String>.unmodifiable(allowedHosts),
       _defaults = Map<String, RemoteValue>.unmodifiable(defaults),
       _allowedSchema = Map<String, RemoteValueType>.unmodifiable(
         allowedSchema,
       ),
       _now = now ?? DateTime.now,
       _snapshot = RemoteConfigSnapshot(
         version: 0,
         expiresAt: null,
         values: defaults,
       );

  final bool enabled;
  final RemoteConfigReader? reader;
  final String endpoint;
  final Set<String> _allowedHosts;
  final Map<String, RemoteValue> _defaults;
  final Map<String, RemoteValueType> _allowedSchema;
  final DateTime Function() _now;
  RemoteConfigSnapshot _snapshot;
  int _generation = 0;

  late final FeatureFlagReading flags = _FlagView(this);
  RemoteConfigSnapshot get snapshot => _snapshot;

  // Synchronous wrapper: even an invalid newest attempt supersedes older work,
  // and publication precedes any product getter/read/clock reentrancy.
  Future<RemoteConfigFetchResult> fetch() {
    if (!enabled) {
      return Future.value(
        const RemoteConfigFetchResult._(
          RemoteConfigFetchKind.disabled,
          'remote.disabled',
        ),
      );
    }
    final generation = ++_generation;
    final configuredReader = reader;
    if (configuredReader == null) {
      return Future.value(
        const RemoteConfigFetchResult._(
          RemoteConfigFetchKind.unavailable,
          'remote.reader_not_configured',
        ),
      );
    }
    if (!_validConfiguration()) return Future.value(_invalidConfiguration);
    return _fetch(generation, configuredReader);
  }

  /// Logical opt-out only: no HTTP abort or settlement of a hung fetch future.
  void reset() {
    _generation++;
    _snapshot = RemoteConfigSnapshot(
      version: 0,
      expiresAt: null,
      values: _defaults,
    );
  }

  bool _validConfiguration() =>
      _safeRelativePath(endpoint) &&
      _allowedHosts.isNotEmpty &&
      _allowedHosts.length <= 16 &&
      _allowedHosts.every(_validHost) &&
      _defaults.length <= 64 &&
      _defaults.entries.every(
        (entry) => _validKey(entry.key) && _validValue(entry.value),
      ) &&
      _allowedSchema.length <= 64 &&
      _allowedSchema.entries.every(
        (entry) =>
            _validKey(entry.key) &&
            !_protectedKey(entry.key) &&
            (!_defaults.containsKey(entry.key) ||
                _defaults[entry.key]!.type == entry.value),
      );

  Future<RemoteConfigFetchResult> _fetch(
    int generation,
    RemoteConfigReader configuredReader,
  ) async {
    final String rawBase;
    try {
      rawBase = configuredReader.baseEndpoint.toString();
    } on Object {
      return generation == _generation
          ? _failure('remote.transport_failed')
          : _superseded;
    }
    if (generation != _generation) return _superseded;
    if (!_validBase(rawBase, endpoint, _allowedHosts)) {
      return _invalidConfiguration;
    }
    if (generation != _generation) return _superseded;
    final RemoteConfigResponse response;
    try {
      response = await configuredReader.read(endpoint);
    } on Object {
      return generation == _generation
          ? _failure('remote.transport_failed')
          : _superseded;
    }
    if (generation != _generation) return _superseded;
    if (response.statusCode < 100 || response.statusCode > 599) {
      return _failure('remote.invalid_response');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return _failure('remote.transport_failed');
    }
    final bytes = response.body;
    if (bytes.length > 16384) return _failure('remote.response_too_large');
    if (bytes.any((byte) => byte < 0 || byte > 255)) {
      return _failure('remote.invalid_response');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    } on Object {
      return _failure('remote.invalid_response');
    }
    if (decoded is! Map ||
        decoded.length != 3 ||
        !decoded.containsKey('version') ||
        !decoded.containsKey('expires_at') ||
        !decoded.containsKey('values')) {
      return _invalidSchema;
    }
    final version = decoded['version'];
    final expiresAt = _epoch(decoded['expires_at']);
    final values = decoded['values'];
    if (version is! int ||
        version < 1 ||
        !_signed64(version) ||
        expiresAt == null ||
        values is! Map ||
        values.length > 64) {
      return _invalidSchema;
    }
    final nextValues = <String, RemoteValue>{..._defaults};
    for (final entry in values.entries) {
      final key = entry.key;
      if (key is! String || !_validKey(key) || _protectedKey(key)) {
        return _invalidSchema;
      }
      final type = _allowedSchema[key];
      final value = _typedValue(type, entry.value);
      if (value == null || !_validValue(value)) return _invalidSchema;
      nextValues[key] = value;
    }
    final DateTime currentTime;
    try {
      currentTime = _now();
    } on Object {
      return generation == _generation
          ? _failure('remote.clock_failed')
          : _superseded;
    }
    if (generation != _generation) return _superseded;
    // BigInt differences avoid signed64 Duration overflow near DateTime limits.
    final lifetime =
        BigInt.from(expiresAt.microsecondsSinceEpoch) -
        BigInt.from(currentTime.microsecondsSinceEpoch);
    if (lifetime <= BigInt.zero) {
      return const RemoteConfigFetchResult._(
        RemoteConfigFetchKind.invalid,
        'remote.expired',
      );
    }
    if (lifetime > BigInt.from(31536000000000)) return _invalidSchema;
    final next = RemoteConfigSnapshot(
      version: version,
      expiresAt: expiresAt,
      values: nextValues,
    );
    if (generation != _generation) return _superseded;
    _snapshot = next;
    return RemoteConfigFetchResult._(
      RemoteConfigFetchKind.applied,
      'remote.applied',
      next,
    );
  }

  RemoteValue? _readFlag(String key) {
    if (!enabled || _snapshot.expiresAt == null) return _defaults[key];
    try {
      final currentTime = _now();
      // Select state AFTER the product clock: it may have reset this service.
      final current = _snapshot;
      final expiry = current.expiresAt;
      if (expiry != null && expiry.isAfter(currentTime)) {
        return current.values[key];
      }
    } on Object {
      // Clock failures expose neither stale remote values nor exception prose.
    }
    return _defaults[key];
  }
}

final class _FlagView implements FeatureFlagReading {
  const _FlagView(this.service);
  final StarterRemoteConfigService service;

  @override
  RemoteValue? value(String key) => service._readFlag(key);
}

const _invalidConfiguration = RemoteConfigFetchResult._(
  RemoteConfigFetchKind.invalid,
  'remote.invalid_configuration',
);
const _invalidSchema = RemoteConfigFetchResult._(
  RemoteConfigFetchKind.invalid,
  'remote.invalid_schema',
);
const _superseded = RemoteConfigFetchResult._(
  RemoteConfigFetchKind.superseded,
  'remote.superseded',
);
RemoteConfigFetchResult _failure(String code) =>
    RemoteConfigFetchResult._(RemoteConfigFetchKind.failure, code);

bool _matches(String value, String pattern) {
  final match = RegExp(pattern).firstMatch(value);
  return match != null && match.start == 0 && match.end == value.length;
}

bool _validKey(String key) => _matches(key, r'[A-Za-z][A-Za-z0-9_.-]{0,63}');

bool _protectedKey(String key) {
  final normalized = key.toLowerCase().replaceAll(RegExp(r'[_.-]'), '');
  return const [
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
  ].any(normalized.contains);
}

bool _signed64(int value) {
  final number = BigInt.from(value);
  return number >= BigInt.parse('-9223372036854775808') &&
      number <= BigInt.parse('9223372036854775807');
}

bool _validText(String value) {
  if (value.length > 128) return false;
  for (var index = 0; index < value.length; index++) {
    final unit = value.codeUnitAt(index);
    if (unit <= 0x1f || (unit >= 0x7f && unit <= 0x9f)) return false;
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++index >= value.length) return false;
      final low = value.codeUnitAt(index);
      if (low < 0xdc00 || low > 0xdfff) return false;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return false;
    }
  }
  return utf8.encode(value).length <= 128;
}

bool _validValue(RemoteValue value) => switch (value.type) {
  RemoteValueType.boolean => value.value is bool,
  RemoteValueType.integer =>
    value.value is int && _signed64(value.value as int),
  RemoteValueType.text =>
    value.value is String && _validText(value.value as String),
};

RemoteValue? _typedValue(RemoteValueType? type, Object? value) =>
    switch (type) {
      RemoteValueType.boolean when value is bool => RemoteValue.boolean(value),
      RemoteValueType.integer when value is int => RemoteValue.integer(value),
      RemoteValueType.text when value is String => RemoteValue.text(value),
      _ => null,
    };

DateTime? _epoch(Object? value) {
  if (value is! num || !value.isFinite) return null;
  final micros = value.toDouble() * Duration.microsecondsPerSecond;
  if (!micros.isFinite || micros.abs() > 8640000000000000000) return null;
  try {
    return DateTime.fromMicrosecondsSinceEpoch(micros.round(), isUtc: true);
  } on Object {
    return null;
  }
}

bool _validHost(String host) =>
    host.length <= 253 &&
    host
        .split('.')
        .every(
          (label) => _matches(label, r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?'),
        );

bool _safeRelativePath(String path) =>
    path.isNotEmpty &&
    path.length <= 2048 &&
    path
        .split('/')
        .every(
          (part) =>
              part != '.' &&
              part != '..' &&
              _matches(part, r'[A-Za-z0-9._~-]+'),
        );

bool _validBase(String raw, String endpoint, Set<String> hosts) {
  // Supplied serialization only: parsing by the product can erase provenance.
  if (raw.length > 2048) return false;
  final match = RegExp(r'https://([a-z0-9.-]+)(?::([0-9]+))?(/[^?#]*)?')
      .firstMatch(raw);
  if (match == null || match.start != 0 || match.end != raw.length) {
    return false;
  }
  final host = match.group(1)!;
  if (!_validHost(host) || !hosts.contains(host)) return false;
  final port = match.group(2);
  if (port != null) {
    if (port.length > 5) return false;
    final number = int.parse(port);
    if (number < 1 || number > 65535) return false;
  }
  var path = match.group(3) ?? '';
  if (path.isNotEmpty) {
    path = path.substring(1);
    if (path.endsWith('/')) path = path.substring(0, path.length - 1);
    if (path.isNotEmpty && !_safeRelativePath(path)) return false;
    if (path.isEmpty && match.group(3) != '/') return false;
  }
  final base = Uri.parse(raw);
  final prefix = base.path.endsWith('/') ? base.path : '${base.path}/';
  final joined = base.replace(path: prefix).resolve(endpoint);
  return joined.origin == base.origin &&
      joined.path == '$prefix$endpoint' &&
      joined.toString().length <= 2048;
}
