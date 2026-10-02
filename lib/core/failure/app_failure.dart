import 'dart:async';
import 'dart:io';

enum FailureKind {
  validation,
  unauthorized,
  forbidden,
  notFound,
  conflict,
  network,
  timeout,
  cancelled,
  server,
  unavailable,
  unknown,
}

/// A safe, presentation-ready failure value. Diagnostic causes are never
/// included in public fields or [toString].
final class AppFailure implements Exception {
  AppFailure(this.kind, {required this.code, required this.localizationKey})
    : _cause = null {
    _validatePublicValue('code', code);
    _validatePublicValue('localizationKey', localizationKey);
  }

  AppFailure._(this.kind, this.code, this.localizationKey, this._cause) {
    _validatePublicValue('code', code);
    _validatePublicValue('localizationKey', localizationKey);
  }

  final FailureKind kind;
  final String code;
  final String localizationKey;
  // ignore: unused_field
  final Object? _cause;

  static const int maxPublicValueLength = 64;
  static final RegExp _publicValue = RegExp(r'^[a-z0-9_.-]{1,64}$');

  static AppFailure? fromHttpStatus(int status) {
    if (status >= 200 && status < 300) return null;
    return switch (status) {
      400 || 422 => _of(FailureKind.validation, 'request.invalid'),
      401 => _of(FailureKind.unauthorized, 'auth.required'),
      403 => _of(FailureKind.forbidden, 'access.denied'),
      404 => _of(FailureKind.notFound, 'resource.not_found'),
      408 => _of(FailureKind.timeout, 'request.timeout'),
      409 => _of(FailureKind.conflict, 'request.conflict'),
      429 || 503 => _of(FailureKind.unavailable, 'service.unavailable'),
      >= 300 && < 400 => _of(FailureKind.unavailable, 'service.unavailable'),
      >= 500 && < 600 => _of(FailureKind.server, 'server.error'),
      _ => _of(FailureKind.unknown, 'unexpected.response'),
    };
  }

  static AppFailure fromException(Object error) {
    if (error is AppFailure) return error;
    if (error is TimeoutException) {
      return _of(FailureKind.timeout, 'request.timeout', cause: error);
    }
    if (error is SocketException) {
      return _of(FailureKind.network, 'network.error', cause: error);
    }
    return _of(FailureKind.unknown, 'unexpected.error', cause: error);
  }

  static AppFailure _of(FailureKind kind, String code, {Object? cause}) =>
      AppFailure._(kind, code, 'failure.$code', cause);

  static void _validatePublicValue(String name, String value) {
    if (value.length > maxPublicValueLength || !_publicValue.hasMatch(value)) {
      throw ArgumentError(
        '$name must be 1-64 lowercase ASCII letters, digits, dots, underscores, or hyphens',
      );
    }
  }

  @override
  String toString() =>
      'AppFailure(kind: ${kind.name}, code: $code, localizationKey: $localizationKey)';
}
