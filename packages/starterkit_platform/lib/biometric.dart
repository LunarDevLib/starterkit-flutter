import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';

const MethodChannel _biometricChannel = MethodChannel(
  'starterkit/platform/biometric',
);
const Duration _cancelAcknowledgementLimit = Duration(seconds: 1);
final Random _secureRandom = Random.secure();

enum BiometricAvailabilityState {
  ready,
  permissionRequired,
  noHardware,
  notEnrolled,
  lockedOut,
  unavailable,
}

enum BiometricResultKind {
  authenticated,
  cancelled,
  denied,
  lockedOut,
  unavailable,
  invalid,
  conflict,
  failure,
}

final class BiometricAvailability {
  const BiometricAvailability(this.state, this.code);

  final BiometricAvailabilityState state;
  final String code;
}

final class BiometricResult {
  const BiometricResult._(this.kind, this.code, this.requestId);

  final BiometricResultKind kind;
  final String code;
  final String requestId;

  /// True only for the exact authenticated outcome returned by the native API.
  bool get authenticated =>
      kind == BiometricResultKind.authenticated &&
      code == 'biometric.authenticated';
}

final class BiometricOperation {
  BiometricOperation._(this.requestId, this.result, this._cancel);

  final String requestId;
  final Future<BiometricResult> result;
  final Future<bool> Function() _cancel;

  /// Settles the result immediately; native acknowledgement is best-effort and
  /// bounded. Repeated calls share the same acknowledgement future.
  Future<bool> cancel() => _cancel();
}

/// An explicitly enabled, otherwise dormant biometric-authentication adapter.
final class StarterBiometricCapability {
  const StarterBiometricCapability({this.enabled = false});

  final bool enabled;

  Future<BiometricAvailability> availability() async {
    if (!enabled) {
      return const BiometricAvailability(
        BiometricAvailabilityState.unavailable,
        'biometric.disabled',
      );
    }
    try {
      final raw = await _biometricChannel.invokeMethod<Object?>(
        'biometricAvailability',
      );
      return _decodeAvailability(raw);
    } on MissingPluginException {
      return const BiometricAvailability(
        BiometricAvailabilityState.unavailable,
        'biometric.platform_unavailable',
      );
    } on Object {
      return const BiometricAvailability(
        BiometricAvailabilityState.unavailable,
        'biometric.platform_failure',
      );
    }
  }

  BiometricOperation authenticate({required String reason}) {
    if (!enabled) {
      return _immediateOperation(
        const BiometricResult._(
          BiometricResultKind.unavailable,
          'biometric.disabled',
          '',
        ),
      );
    }
    final requestId = _newRequestId();
    if (!_validReason(reason)) {
      return _immediateOperation(
        BiometricResult._(
          BiometricResultKind.denied,
          'biometric.invalid_reason',
          requestId,
        ),
      );
    }
    return _startOperation(requestId, reason);
  }
}

BiometricOperation _immediateOperation(BiometricResult result) {
  Future<bool> cancel() async => false;
  return BiometricOperation._(result.requestId, Future.value(result), cancel);
}

BiometricOperation _startOperation(String requestId, String reason) {
  final completer = Completer<BiometricResult>();
  var settled = false;
  Future<bool>? cancelFuture;

  void settle(BiometricResult result) {
    if (settled) return;
    settled = true;
    completer.complete(result);
  }

  Future<bool> sendCancel() async {
    try {
      return await _biometricChannel
              .invokeMethod<Object?>('cancelBiometric', {
                'requestId': requestId,
              })
              .timeout(_cancelAcknowledgementLimit) ==
          true;
    } on Object {
      return false;
    }
  }

  Future<bool> cancel() {
    final previous = cancelFuture;
    if (previous != null) return previous;
    if (settled) return Future<bool>.value(false);
    settle(
      BiometricResult._(
        BiometricResultKind.cancelled,
        'biometric.cancelled',
        requestId,
      ),
    );
    return cancelFuture = sendCancel();
  }

  unawaited(() async {
    try {
      final raw = await _biometricChannel.invokeMethod<Object?>(
        'authenticateBiometric',
        {'requestId': requestId, 'reason': reason},
      );
      settle(_decodeResult(raw, requestId));
    } on MissingPluginException {
      settle(
        BiometricResult._(
          BiometricResultKind.unavailable,
          'biometric.platform_unavailable',
          requestId,
        ),
      );
    } on Object {
      settle(
        BiometricResult._(
          BiometricResultKind.failure,
          'biometric.platform_failure',
          requestId,
        ),
      );
    }
  }());

  return BiometricOperation._(requestId, completer.future, cancel);
}

String _newRequestId() {
  final bytes = List<int>.generate(16, (_) => _secureRandom.nextInt(256));
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

bool _validReason(String reason) =>
    reason.trim().isNotEmpty &&
    !reason.contains('\u0000') &&
    utf8.encode(reason).length <= 256;

BiometricAvailability _decodeAvailability(Object? raw) {
  if (raw is! Map ||
      !_stringMap(raw) ||
      !_exactKeys(raw, const {'state', 'code'})) {
    return const BiometricAvailability(
      BiometricAvailabilityState.unavailable,
      'biometric.platform_failure',
    );
  }
  final state = raw['state'];
  final code = raw['code'];
  if (state is! String || code is! String) return _badAvailability();
  final parsed = BiometricAvailabilityState.values
      .cast<BiometricAvailabilityState?>()
      .firstWhere((value) => value?.name == state, orElse: () => null);
  const codes = <BiometricAvailabilityState, Set<String>>{
    BiometricAvailabilityState.ready: {'biometric.ready'},
    BiometricAvailabilityState.permissionRequired: {
      'biometric.permission_required',
    },
    BiometricAvailabilityState.noHardware: {'biometric.no_hardware'},
    BiometricAvailabilityState.notEnrolled: {'biometric.not_enrolled'},
    BiometricAvailabilityState.lockedOut: {'biometric.locked_out'},
    BiometricAvailabilityState.unavailable: {
      'biometric.unavailable',
      'biometric.disabled',
      'biometric.platform_unavailable',
      'biometric.invalid_request',
      'biometric.face_id_not_configured',
      'biometric.platform_failure',
    },
  };
  if (parsed == null || !(codes[parsed]?.contains(code) ?? false)) {
    return _badAvailability();
  }
  return BiometricAvailability(parsed, code);
}

BiometricAvailability _badAvailability() => const BiometricAvailability(
  BiometricAvailabilityState.unavailable,
  'biometric.platform_failure',
);

BiometricResult _decodeResult(Object? raw, String requestId) {
  if (raw is! Map ||
      !_stringMap(raw) ||
      !_exactKeys(raw, const {'kind', 'code', 'requestId'})) {
    return _badResult(requestId);
  }
  final kindName = raw['kind'];
  final code = raw['code'];
  if (kindName is! String || code is! String || raw['requestId'] != requestId) {
    return _badResult(requestId);
  }
  final kind = BiometricResultKind.values
      .cast<BiometricResultKind?>()
      .firstWhere((value) => value?.name == kindName, orElse: () => null);
  if (kind == null || !_validResultCode(kind, code)) {
    return _badResult(requestId);
  }
  return BiometricResult._(kind, code, requestId);
}

bool _validResultCode(BiometricResultKind kind, String code) {
  const codes = <BiometricResultKind, Set<String>>{
    BiometricResultKind.authenticated: {'biometric.authenticated'},
    BiometricResultKind.cancelled: {
      'biometric.cancelled',
      'biometric.backgrounded',
      'biometric.activity_detached',
      'biometric.engine_detached',
    },
    BiometricResultKind.denied: {
      'biometric.denied',
      'biometric.permission_required',
      'biometric.invalid_reason',
    },
    BiometricResultKind.lockedOut: {'biometric.locked_out'},
    BiometricResultKind.unavailable: {
      'biometric.unavailable',
      'biometric.disabled',
      'biometric.platform_unavailable',
      'biometric.no_hardware',
      'biometric.not_enrolled',
      'biometric.face_id_not_configured',
      'biometric.foreground_required',
      'biometric.activity_unavailable',
    },
    BiometricResultKind.invalid: {
      'biometric.invalid_request',
      'biometric.invalid_native_response',
    },
    BiometricResultKind.conflict: {'biometric.operation_in_progress'},
    BiometricResultKind.failure: {
      'biometric.platform_failure',
      'biometric.prompt_failed',
    },
  };
  return codes[kind]?.contains(code) ?? false;
}

BiometricResult _badResult(String id) => BiometricResult._(
  BiometricResultKind.invalid,
  'biometric.invalid_native_response',
  id,
);

bool _stringMap(Map map) => map.keys.every((key) => key is String);

bool _exactKeys(Map map, Set<String> expected) =>
    map.length == expected.length && map.keys.toSet().containsAll(expected);
