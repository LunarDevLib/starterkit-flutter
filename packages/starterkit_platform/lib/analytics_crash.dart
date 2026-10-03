import 'dart:convert';

/// Product-owned transport. TLS, redirects, acquisition limits and credentials
/// belong to the product, not this validation facade.
abstract interface class TelemetryTransport {
  Uri get baseEndpoint;

  Future<TelemetryResponse> execute(TelemetryRequest request);
}

final class TelemetryRequest {
  TelemetryRequest({required Uri uri, required List<int> body})
    : uri = Uri.parse(uri.toString()),
      body = List<int>.unmodifiable(body);

  final Uri uri;
  final List<int> body;
  final String method = 'POST';
  final String contentType = 'application/json';
}

final class TelemetryResponse {
  TelemetryResponse({required this.statusCode, required List<int> body})
    : body = List<int>.unmodifiable(body);

  final int statusCode;
  final List<int> body;
}

enum AnalyticsConsent { denied, granted }

enum CrashConsent { denied, granted }

enum AnalyticsField { screen, action, category, value, success }

enum _FieldValueKind { text, integer, decimal, boolean }

/// Closed typed values, not arbitrary objects or an identity/exception API.
final class AnalyticsFieldValue {
  const AnalyticsFieldValue.text(String this.value)
    : _kind = _FieldValueKind.text;

  const AnalyticsFieldValue.integer(int this.value)
    : _kind = _FieldValueKind.integer;

  const AnalyticsFieldValue.decimal(double this.value)
    : _kind = _FieldValueKind.decimal;

  const AnalyticsFieldValue.boolean(bool this.value)
    : _kind = _FieldValueKind.boolean;

  final _FieldValueKind _kind;
  final Object value;
}

final class AnalyticsEvent {
  AnalyticsEvent({
    required this.name,
    Map<AnalyticsField, AnalyticsFieldValue> fields = const {},
  }) : fields = Map<AnalyticsField, AnalyticsFieldValue>.unmodifiable(fields);

  final String name;
  final Map<AnalyticsField, AnalyticsFieldValue> fields;
}

enum HandledIssue {
  assertion,
  parsing,
  network,
  persistence,
  authentication,
  other,
}

/// Handled issue codes only; no global handler, stack, fatal or exception input.
final class HandledReport {
  HandledReport({
    required this.issue,
    required this.code,
    Map<String, String> context = const {},
  }) : context = Map<String, String>.unmodifiable(context);

  final HandledIssue issue;
  final String code;
  final Map<String, String> context;
}

enum TelemetrySubmitKind {
  disabled,
  denied,
  invalid,
  unavailable,
  failure,
  submitted,
}

/// Submitted means a 2xx transport response, not delivery, persistence or capture.
final class TelemetrySubmitResult {
  const TelemetrySubmitResult._(this.kind, this.code);

  final TelemetrySubmitKind kind;
  final String code;
}

/// Consent and configuration are immutable per instance. Replace the instance
/// and remove old call sites when consent changes; dispatched work is not undone.
final class StarterAnalyticsService {
  StarterAnalyticsService({
    this.enabled = false,
    this.consent = AnalyticsConsent.denied,
    this.transport,
    this.endpoint = 'analytics/events',
    Set<String> allowedHosts = const {},
  }) : allowedHosts = Set<String>.unmodifiable(allowedHosts);

  final bool enabled;
  final AnalyticsConsent consent;
  final TelemetryTransport? transport;
  final String endpoint;
  final Set<String> allowedHosts;

  Future<TelemetrySubmitResult> submit(AnalyticsEvent event) async {
    if (!enabled) return _disabled;
    if (consent != AnalyticsConsent.granted) return _denied;
    final configured = transport;
    if (configured == null) return _unconfigured;
    if (!_safeCode(event.name, 64) || event.fields.length > 8) {
      return _invalidPayload;
    }
    final fields = <String, Object>{};
    for (final entry in event.fields.entries) {
      if (!_validFieldValue(entry.value)) return _invalidPayload;
      fields[entry.key.name] = entry.value.value;
    }
    return _submit(
      configured,
      endpoint,
      allowedHosts,
      utf8.encode(jsonEncode({'name': event.name, 'fields': fields})),
      2048,
    );
  }
}

/// Explicit handled reports only; denied by default and never auto-capturing.
final class StarterCrashReportingService {
  StarterCrashReportingService({
    this.enabled = false,
    this.consent = CrashConsent.denied,
    this.transport,
    this.endpoint = 'crash/handled',
    Set<String> allowedHosts = const {},
  }) : allowedHosts = Set<String>.unmodifiable(allowedHosts);

  final bool enabled;
  final CrashConsent consent;
  final TelemetryTransport? transport;
  final String endpoint;
  final Set<String> allowedHosts;

  Future<TelemetrySubmitResult> submit(HandledReport report) async {
    if (!enabled) return _disabled;
    if (consent != CrashConsent.granted) return _denied;
    final configured = transport;
    if (configured == null) return _unconfigured;
    if (!_safeCode(report.code, 48) || report.context.length > 4) {
      return _invalidPayload;
    }
    const keys = {'operation', 'screen', 'component', 'stage'};
    for (final entry in report.context.entries) {
      if (!keys.contains(entry.key) || !_safeCode(entry.value, 64)) {
        return _invalidPayload;
      }
    }
    return _submit(
      configured,
      endpoint,
      allowedHosts,
      utf8.encode(
        jsonEncode({
          'issue': report.issue.name,
          'code': report.code,
          'context': report.context,
        }),
      ),
      1024,
    );
  }
}

const _disabled = TelemetrySubmitResult._(
  TelemetrySubmitKind.disabled,
  'telemetry.disabled',
);
const _denied = TelemetrySubmitResult._(
  TelemetrySubmitKind.denied,
  'telemetry.consent_denied',
);
const _unconfigured = TelemetrySubmitResult._(
  TelemetrySubmitKind.unavailable,
  'telemetry.transport_not_configured',
);
const _invalidConfiguration = TelemetrySubmitResult._(
  TelemetrySubmitKind.invalid,
  'telemetry.invalid_configuration',
);
const _invalidPayload = TelemetrySubmitResult._(
  TelemetrySubmitKind.invalid,
  'telemetry.invalid_payload',
);
const _transportFailed = TelemetrySubmitResult._(
  TelemetrySubmitKind.failure,
  'telemetry.transport_failed',
);

Future<TelemetrySubmitResult> _submit(
  TelemetryTransport transport,
  String endpoint,
  Set<String> allowedHosts,
  List<int> body,
  int maxBodyBytes,
) async {
  if (body.length > maxBodyBytes) {
    return const TelemetrySubmitResult._(
      TelemetrySubmitKind.invalid,
      'telemetry.payload_too_large',
    );
  }
  if (!_validHosts(allowedHosts) || !_safePath(endpoint, base: false)) {
    return _invalidConfiguration;
  }
  final Uri base;
  try {
    base = transport.baseEndpoint;
  } on Object {
    return _transportFailed;
  }
  final uri = _resolveEndpoint(base, endpoint, allowedHosts);
  if (uri == null) return _invalidConfiguration;
  final TelemetryResponse response;
  try {
    response = await transport.execute(TelemetryRequest(uri: uri, body: body));
  } on Object {
    return _transportFailed;
  }
  if (response.statusCode < 100 || response.statusCode > 599) {
    return const TelemetrySubmitResult._(
      TelemetrySubmitKind.failure,
      'telemetry.invalid_response',
    );
  }
  if (response.body.length > 65536) {
    return const TelemetrySubmitResult._(
      TelemetrySubmitKind.failure,
      'telemetry.response_too_large',
    );
  }
  if (response.body.any((byte) => byte < 0 || byte > 255)) {
    return const TelemetrySubmitResult._(
      TelemetrySubmitKind.failure,
      'telemetry.invalid_response',
    );
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    return _transportFailed;
  }
  return const TelemetrySubmitResult._(
    TelemetrySubmitKind.submitted,
    'telemetry.submitted',
  );
}

bool _matches(String value, String pattern) {
  final match = RegExp(pattern).firstMatch(value);
  return match != null && match.start == 0 && match.end == value.length;
}

bool _safeCode(String value, int maxBytes) =>
    value.length <= maxBytes && _matches(value, r'[A-Za-z0-9._-]+');

bool _validFieldValue(AnalyticsFieldValue field) => switch (field._kind) {
  _FieldValueKind.text => _safeText(field.value as String),
  _FieldValueKind.integer =>
    BigInt.from(field.value as int) >= BigInt.parse('-9223372036854775808') &&
        BigInt.from(field.value as int) <= BigInt.parse('9223372036854775807'),
  _FieldValueKind.decimal => (field.value as double).isFinite,
  _FieldValueKind.boolean => true,
};

bool _safeText(String value) {
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

bool _validHost(String host) =>
    host.length <= 253 &&
    host
        .split('.')
        .every(
          (label) => _matches(label, r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?'),
        );

bool _validHosts(Set<String> hosts) =>
    hosts.isNotEmpty && hosts.length <= 16 && hosts.every(_validHost);

bool _safePath(String path, {required bool base}) {
  if (path.length > 2048) return false;
  var segments = path;
  if (base) {
    if (segments.isEmpty) return true;
    if (!segments.startsWith('/')) return false;
    segments = segments.substring(1);
    if (segments.endsWith('/')) {
      segments = segments.substring(0, segments.length - 1);
    }
    if (segments.isEmpty) return path == '/';
  } else if (segments.isEmpty || segments.startsWith('/')) {
    return false;
  }
  return segments
      .split('/')
      .every(
        (part) =>
            part != '.' && part != '..' && _matches(part, r'[A-Za-z0-9._~-]+'),
      );
}

Uri? _resolveEndpoint(Uri base, String endpoint, Set<String> allowedHosts) {
  try {
    // Validate the supplied serialization, then detach from custom mutable Uri
    // implementations. Uri.parse may already have erased original URL spelling;
    // the product owns construction/provenance of its configured Uri.
    final raw = base.toString();
    if (raw.length > 2048) return null;
    final match = RegExp(r'https://([a-z0-9.-]+)(?::([0-9]+))?(/[^?#]*)?')
        .firstMatch(raw);
    if (match == null || match.start != 0 || match.end != raw.length) {
      return null;
    }
    final host = match.group(1)!;
    final port = match.group(2);
    if (!_validHost(host) || !allowedHosts.contains(host)) return null;
    if (port != null) {
      if (port.length > 5) return null;
      final number = int.parse(port);
      if (number < 1 || number > 65535) return null;
    }
    final path = match.group(3) ?? '';
    if (!_safePath(path, base: true)) return null;
    final prefix = path.endsWith('/') ? path : '$path/';
    final joined =
        'https://$host${port == null ? '' : ':$port'}$prefix$endpoint';
    if (joined.length > 2048) return null;
    return Uri.parse(joined);
  } on Object {
    return null;
  }
}
