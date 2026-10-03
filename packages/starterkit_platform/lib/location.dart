import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';

const MethodChannel _locationChannel = MethodChannel(
  'starterkit/platform/location',
);
const Duration _cancelAcknowledgementLimit = Duration(seconds: 1);
final Random _secureRandom = Random.secure();

enum LocationResultKind {
  success,
  cancelled,
  denied,
  restricted,
  unavailable,
  timeout,
  invalid,
  conflict,
  failure,
}

enum LocationPermissionStatus {
  notDetermined,
  granted,
  denied,
  restricted,
  unavailable,
}

final class LocationLimits {
  const LocationLimits({this.timeoutMillis = 15000, this.maxAgeMillis = 5000});

  static const int defaultPermissionTimeoutMillis = 60000;
  static const int maximumTimeoutMillis = 60000;
  static const int maximumAgeMillis = 60000;

  final int timeoutMillis;
  final int maxAgeMillis;

  void validate({bool includeAge = true}) {
    if (timeoutMillis < 1 || timeoutMillis > maximumTimeoutMillis) {
      throw ArgumentError.value(timeoutMillis, 'timeoutMillis');
    }
    if (includeAge && (maxAgeMillis < 1 || maxAgeMillis > maximumAgeMillis)) {
      throw ArgumentError.value(maxAgeMillis, 'maxAgeMillis');
    }
  }
}

final class ForegroundLocation {
  ForegroundLocation({
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
    required this.approximate,
    required this.ageMillis,
  }) {
    if (!latitude.isFinite || latitude < -90 || latitude > 90) {
      throw ArgumentError.value(latitude, 'latitude');
    }
    if (!longitude.isFinite || longitude < -180 || longitude > 180) {
      throw ArgumentError.value(longitude, 'longitude');
    }
    if (!accuracyMeters.isFinite || accuracyMeters < 0) {
      throw ArgumentError.value(accuracyMeters, 'accuracyMeters');
    }
    if (ageMillis < 0 || ageMillis > LocationLimits.maximumAgeMillis) {
      throw ArgumentError.value(ageMillis, 'ageMillis');
    }
  }

  final double latitude;
  final double longitude;
  final double accuracyMeters;
  final bool approximate;
  final int ageMillis;
}

final class LocationResult {
  const LocationResult._(this.kind, this.code, this.requestId, this.location);

  final LocationResultKind kind;
  final String code;
  final String? requestId;
  final ForegroundLocation? location;

  bool get isSuccess => kind == LocationResultKind.success;
}

final class LocationPermissionResult {
  const LocationPermissionResult._(
    this.kind,
    this.code,
    this.status,
    this.approximate,
    this.requestId,
  );

  final LocationResultKind kind;
  final String code;
  final LocationPermissionStatus status;
  final bool? approximate;
  final String? requestId;

  bool get isGranted =>
      kind == LocationResultKind.success &&
      status == LocationPermissionStatus.granted;
}

final class LocationOperation<T> {
  LocationOperation._(this.result, this._cancel);

  final Future<T> result;
  final Future<bool> Function() _cancel;

  /// Requests cancellation of this operation only. The acknowledgement is bounded.
  Future<bool> cancel() => _cancel();
}

/// An opt-in, foreground, one-shot location capability. Disabled instances never
/// invoke the platform channel.
final class StarterLocationCapability {
  const StarterLocationCapability({this.enabled = false});

  final bool enabled;

  Future<LocationPermissionResult> permissionStatus() async {
    if (!enabled) {
      return _permissionOutcome(
        LocationResultKind.unavailable,
        'location.disabled',
        LocationPermissionStatus.unavailable,
      );
    }
    try {
      final raw = await _locationChannel.invokeMethod<Object?>(
        'locationPermissionStatus',
      );
      return _decodePermission(raw, requestId: null, isStatus: true);
    } on MissingPluginException {
      return _permissionOutcome(
        LocationResultKind.unavailable,
        'location.platform_unavailable',
        LocationPermissionStatus.unavailable,
      );
    } on PlatformException {
      return _permissionOutcome(
        LocationResultKind.failure,
        'location.platform_failure',
        LocationPermissionStatus.unavailable,
      );
    } on Object {
      return _permissionOutcome(
        LocationResultKind.invalid,
        'location.invalid_native_response',
        LocationPermissionStatus.unavailable,
      );
    }
  }

  LocationOperation<LocationPermissionResult> requestPermission({
    int timeoutMillis = LocationLimits.defaultPermissionTimeoutMillis,
  }) {
    if (timeoutMillis < 1 ||
        timeoutMillis > LocationLimits.maximumTimeoutMillis) {
      throw ArgumentError.value(timeoutMillis, 'timeoutMillis');
    }
    if (!enabled) {
      return _disabledOperation(
        () => _permissionOutcome(
          LocationResultKind.unavailable,
          'location.disabled',
          LocationPermissionStatus.unavailable,
        ),
      );
    }
    final id = _newRequestId();
    return _startOperation<LocationPermissionResult>(
      requestId: id,
      timeoutMillis: timeoutMillis,
      method: 'requestLocationPermission',
      arguments: {'requestId': id, 'timeoutMillis': timeoutMillis},
      decode: (raw) => _decodePermission(raw, requestId: id),
      timeout: () => _permissionOperationOutcome(
        LocationResultKind.timeout,
        'location.timeout',
        id,
      ),
      cancelled: () => _permissionOperationOutcome(
        LocationResultKind.cancelled,
        'location.cancelled',
        id,
      ),
      unavailable: () => _permissionOperationOutcome(
        LocationResultKind.unavailable,
        'location.platform_unavailable',
        id,
      ),
      failure: () => _permissionOperationOutcome(
        LocationResultKind.failure,
        'location.platform_failure',
        id,
      ),
      invalid: () => _permissionOperationOutcome(
        LocationResultKind.invalid,
        'location.invalid_native_response',
        id,
      ),
    );
  }

  LocationOperation<LocationResult> locate({
    LocationLimits limits = const LocationLimits(),
  }) {
    limits.validate();
    if (!enabled) {
      return _disabledOperation(
        () => const LocationResult._(
          LocationResultKind.unavailable,
          'location.disabled',
          null,
          null,
        ),
      );
    }
    final id = _newRequestId();
    return _startOperation<LocationResult>(
      requestId: id,
      timeoutMillis: limits.timeoutMillis,
      method: 'locate',
      arguments: {
        'requestId': id,
        'timeoutMillis': limits.timeoutMillis,
        'maxAgeMillis': limits.maxAgeMillis,
      },
      decode: (raw) => _decodeLocation(raw, id, limits.maxAgeMillis),
      timeout: () =>
          _locationOutcome(LocationResultKind.timeout, 'location.timeout', id),
      cancelled: () => _locationOutcome(
        LocationResultKind.cancelled,
        'location.cancelled',
        id,
      ),
      unavailable: () => _locationOutcome(
        LocationResultKind.unavailable,
        'location.platform_unavailable',
        id,
      ),
      failure: () => _locationOutcome(
        LocationResultKind.failure,
        'location.platform_failure',
        id,
      ),
      invalid: () => _locationOutcome(
        LocationResultKind.invalid,
        'location.invalid_native_response',
        id,
      ),
    );
  }
}

LocationOperation<T> _disabledOperation<T>(T Function() result) =>
    LocationOperation<T>._(Future<T>.value(result()), () async => false);

LocationOperation<T> _startOperation<T>({
  required String requestId,
  required int timeoutMillis,
  required String method,
  required Map<String, Object> arguments,
  required T Function(Object?) decode,
  required T Function() timeout,
  required T Function() cancelled,
  required T Function() unavailable,
  required T Function() failure,
  required T Function() invalid,
}) {
  final elapsed = Stopwatch()..start();
  final deadline = Duration(milliseconds: timeoutMillis);
  final completer = Completer<T>();
  var settled = false;
  Timer? watchdog;
  Future<bool>? nativeCancelFuture;

  void settle(T result) {
    if (settled) return;
    settled = true;
    watchdog?.cancel();
    elapsed.stop();
    completer.complete(result);
  }

  Future<bool> sendCancel() async {
    try {
      return await _locationChannel
              .invokeMethod<Object?>('cancelLocation', {'requestId': requestId})
              .timeout(_cancelAcknowledgementLimit) ==
          true;
    } on Object {
      return false;
    }
  }

  Future<bool> sendCancelOnce() => nativeCancelFuture ??= sendCancel();

  void expire() {
    if (settled) return;
    settle(timeout());
    unawaited(sendCancelOnce());
  }

  bool expireIfDeadlinePassed() {
    if (settled || elapsed.elapsed < deadline) return false;
    expire();
    return true;
  }

  void settleMapped(T Function() map) {
    if (settled || expireIfDeadlinePassed()) return;
    final result = map();
    if (settled || expireIfDeadlinePassed()) return;
    settle(result);
  }

  void settleResponse(Object? raw) {
    if (settled || expireIfDeadlinePassed()) return;
    final result = decode(raw);
    if (settled || expireIfDeadlinePassed()) return;
    settle(result);
  }

  Future<bool> cancel() async {
    if (settled || expireIfDeadlinePassed()) return false;
    final result = cancelled();
    if (settled || expireIfDeadlinePassed()) return false;
    settle(result);
    return sendCancelOnce();
  }

  watchdog = Timer(Duration(milliseconds: timeoutMillis), () {
    expire();
  });
  unawaited(() async {
    try {
      final raw = await _locationChannel.invokeMethod<Object?>(
        method,
        arguments,
      );
      settleResponse(raw);
    } on MissingPluginException {
      settleMapped(unavailable);
    } on PlatformException {
      settleMapped(failure);
    } on Object {
      settleMapped(invalid);
    }
  }());
  return LocationOperation<T>._(completer.future, cancel);
}

String _newRequestId() {
  final bytes = List<int>.generate(16, (_) => _secureRandom.nextInt(256));
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

LocationPermissionResult _decodePermission(
  Object? raw, {
  required String? requestId,
  bool isStatus = false,
}) {
  if (raw is! Map || !_stringMap(raw)) return _badPermission(requestId);
  final expectedKeys = isStatus
      ? const {'kind', 'code', 'status', 'approximate'}
      : const {'kind', 'code', 'status', 'approximate', 'requestId'};
  if (raw.keys.toSet().difference(expectedKeys).isNotEmpty ||
      expectedKeys.difference(raw.keys.toSet()).isNotEmpty) {
    return _badPermission(requestId);
  }
  final kind = _kind(raw['kind']);
  final code = raw['code'];
  final status = _permissionStatus(raw['status']);
  final approximate = raw['approximate'];
  if (kind == null || code is! String || status == null) {
    return _badPermission(requestId);
  }
  if (isStatus ? raw.containsKey('requestId') : raw['requestId'] != requestId) {
    return _badPermission(requestId);
  }
  if (requestId != null && !_validId(raw['requestId'])) {
    return _badPermission(requestId);
  }
  if (status == LocationPermissionStatus.granted) {
    if (approximate is! bool) return _badPermission(requestId);
  } else if (approximate != null) {
    return _badPermission(requestId);
  }
  if (!_validCode(kind, code, permission: true, statusQuery: isStatus)) {
    return _badPermission(requestId);
  }
  if (isStatus &&
      kind == LocationResultKind.success &&
      code != 'location.permission_status') {
    return _badPermission(requestId);
  }
  if (isStatus &&
      kind != LocationResultKind.success &&
      (kind == LocationResultKind.denied ||
          kind == LocationResultKind.restricted ||
          status != LocationPermissionStatus.unavailable ||
          approximate != null)) {
    return _badPermission(requestId);
  }
  if (!isStatus &&
      kind == LocationResultKind.success &&
      (status != LocationPermissionStatus.granted ||
          code != 'location.permission_granted')) {
    return _badPermission(requestId);
  }
  if (!isStatus &&
      ((kind == LocationResultKind.denied &&
              status != LocationPermissionStatus.denied) ||
          (kind == LocationResultKind.restricted &&
              status != LocationPermissionStatus.restricted))) {
    return _badPermission(requestId);
  }
  if (!isStatus &&
      kind != LocationResultKind.success &&
      kind != LocationResultKind.denied &&
      kind != LocationResultKind.restricted &&
      status != LocationPermissionStatus.unavailable) {
    return _badPermission(requestId);
  }
  return LocationPermissionResult._(
    kind,
    code,
    status,
    approximate as bool?,
    requestId,
  );
}

LocationResult _decodeLocation(Object? raw, String id, int maxAge) {
  if (raw is! Map || !_stringMap(raw)) return _badLocation(id);
  final kind = _kind(raw['kind']);
  final code = raw['code'];
  if (kind == null ||
      code is! String ||
      raw['requestId'] != id ||
      !_validId(raw['requestId'])) {
    return _badLocation(id);
  }
  if (!_validCode(kind, code)) return _badLocation(id);
  if (kind != LocationResultKind.success) {
    if (raw.keys.toSet().difference(const {
      'kind',
      'code',
      'requestId',
    }).isNotEmpty) {
      return _badLocation(id);
    }
    return _locationOutcome(kind, code, id);
  }
  if (raw.keys.toSet().difference(const {
    'kind',
    'code',
    'requestId',
    'location',
  }).isNotEmpty) {
    return _badLocation(id);
  }
  final value = raw['location'];
  if (value is! Map || !_stringMap(value) || value.length != 5) {
    return _badLocation(id);
  }
  final latitude = value['latitude'];
  final longitude = value['longitude'];
  final accuracy = value['accuracyMeters'];
  final approximate = value['approximate'];
  final age = value['ageMillis'];
  if (latitude is! double ||
      longitude is! double ||
      accuracy is! double ||
      approximate is! bool ||
      age is! int ||
      !latitude.isFinite ||
      !longitude.isFinite ||
      !accuracy.isFinite ||
      latitude < -90 ||
      latitude > 90 ||
      longitude < -180 ||
      longitude > 180 ||
      accuracy < 0 ||
      age < 0 ||
      age > maxAge ||
      code != 'location.success') {
    return _badLocation(id);
  }
  return LocationResult._(
    LocationResultKind.success,
    code,
    id,
    ForegroundLocation(
      latitude: latitude,
      longitude: longitude,
      accuracyMeters: accuracy,
      approximate: approximate,
      ageMillis: age,
    ),
  );
}

bool _stringMap(Map map) => map.keys.every((key) => key is String);
bool _validId(Object? value) =>
    value is String && RegExp(r'^[0-9a-f]{32}$').hasMatch(value);

LocationResultKind? _kind(Object? value) => value is String
    ? LocationResultKind.values.cast<LocationResultKind?>().firstWhere(
        (kind) => kind?.name == value,
        orElse: () => null,
      )
    : null;

LocationPermissionStatus? _permissionStatus(Object? value) => value is String
    ? LocationPermissionStatus.values
          .cast<LocationPermissionStatus?>()
          .firstWhere((status) => status?.name == value, orElse: () => null)
    : null;

bool _validCode(
  LocationResultKind kind,
  String code, {
  bool permission = false,
  bool statusQuery = false,
}) {
  const codes = <LocationResultKind, Set<String>>{
    LocationResultKind.success: {
      'location.success',
      'location.permission_status',
      'location.permission_granted',
    },
    LocationResultKind.cancelled: {
      'location.cancelled',
      'location.backgrounded',
      'location.activity_detached',
      'location.engine_detached',
    },
    LocationResultKind.denied: {'location.denied'},
    LocationResultKind.restricted: {'location.restricted'},
    LocationResultKind.unavailable: {
      'location.disabled',
      'location.platform_unavailable',
      'location.permission_not_configured',
      'location.permission_required',
      'location.provider_disabled',
      'location.provider_unavailable',
      'location.foreground_required',
      'location.activity_unavailable',
    },
    LocationResultKind.timeout: {'location.timeout'},
    LocationResultKind.invalid: {
      'location.invalid_request',
      'location.invalid_limits',
      'location.invalid_coordinate',
      'location.invalid_accuracy',
      'location.sample_stale',
      'location.invalid_sample_time',
      'location.invalid_native_response',
    },
    LocationResultKind.conflict: {'location.operation_in_progress'},
    LocationResultKind.failure: {
      'location.platform_failure',
      'location.request_codes_exhausted',
    },
  };
  if (!(codes[kind]?.contains(code) ?? false)) return false;
  if (permission && kind == LocationResultKind.success) {
    return statusQuery
        ? code == 'location.permission_status'
        : code == 'location.permission_granted';
  }
  return true;
}

LocationPermissionResult _badPermission(String? id) =>
    LocationPermissionResult._(
      LocationResultKind.invalid,
      'location.invalid_native_response',
      LocationPermissionStatus.unavailable,
      null,
      id,
    );

LocationPermissionResult _permissionOutcome(
  LocationResultKind kind,
  String code,
  LocationPermissionStatus status,
) => LocationPermissionResult._(kind, code, status, null, null);

LocationPermissionResult _permissionOperationOutcome(
  LocationResultKind kind,
  String code,
  String id,
) => LocationPermissionResult._(
  kind,
  code,
  LocationPermissionStatus.unavailable,
  null,
  id,
);

LocationResult _badLocation(String id) => _locationOutcome(
  LocationResultKind.invalid,
  'location.invalid_native_response',
  id,
);

LocationResult _locationOutcome(
  LocationResultKind kind,
  String code,
  String id,
) => LocationResult._(kind, code, id, null);
