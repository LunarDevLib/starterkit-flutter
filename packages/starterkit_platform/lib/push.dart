import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

const MethodChannel _pushChannel = MethodChannel('starterkit/platform/push');

enum PushPermissionKind {
  granted,
  notDetermined,
  denied,
  restricted,
  unavailable,
  conflict,
  invalid,
  failure,
}

final class PushPermissionResult {
  const PushPermissionResult._(this.kind, this.code);

  final PushPermissionKind kind;
  final String code;
}

enum PushProviderRegistrationKind {
  registered,
  denied,
  unavailable,
  cancelled,
  failure,
}

/// Only a registered outcome may contain a token; the facade validates it.
final class PushProviderRegistration {
  const PushProviderRegistration(this.kind, {this.token});

  final PushProviderRegistrationKind kind;
  final String? token;
}

/// Product-owned SDK/APNs integration. Neither member is accessed at startup.
abstract interface class PushProvider {
  Future<PushProviderRegistration> register();

  /// Untrusted messages must be maps with only title, body and optional data.
  Stream<Object?> get messages;
}

enum PushRegistrationKind {
  registered,
  denied,
  unavailable,
  cancelled,
  invalid,
  failure,
}

/// A valid token is opaque and case-preserved, never a delivery receipt.
final class PushRegistrationResult {
  const PushRegistrationResult._(this.kind, this.code, [this.token]);

  final PushRegistrationKind kind;
  final String code;
  final String? token;
}

final class PushMessage {
  const PushMessage._(this.title, this.body, this.data);

  final String? title;
  final String? body;
  final Map<String, String> data;
}

enum PushMessageActivationKind { active, unavailable, failure, closed }

/// A subscription handle, not proof of delivery. Terminal errors are redacted.
final class PushMessageActivation {
  PushMessageActivation._(this._kind, this._code, [this._onMessage])
    : _accepting = _kind == PushMessageActivationKind.active;

  PushMessageActivationKind _kind;
  String _code;
  bool _accepting;
  final void Function(PushMessage)? _onMessage;
  StreamSubscription<Object?>? _subscription;
  Future<void>? _cancellation;

  PushMessageActivationKind get kind => _kind;
  String get code => _code;

  /// Fence callbacks immediately; cancel once. Existing terminal errors remain.
  Future<void> close() {
    if (_accepting) {
      _accepting = false;
      _kind = PushMessageActivationKind.closed;
      _code = 'push.messages_closed';
    }
    return _cancel();
  }

  void _attach(StreamSubscription<Object?> subscription) {
    _subscription = subscription;
    if (!_accepting) unawaited(_cancel());
  }

  void _receive(Object? raw) {
    if (!_accepting) return;
    try {
      final message = _parseMessage(raw);
      if (message == null) {
        _fail('push.invalid_message');
        return;
      }
      _onMessage!(message);
    } on Object {
      _fail('push.message_failed');
    }
  }

  void _fail(String code) {
    if (!_accepting) return;
    _accepting = false;
    _kind = PushMessageActivationKind.failure;
    _code = code;
    unawaited(_cancel());
  }

  void _done() {
    if (!_accepting) return;
    _accepting = false;
    _kind = PushMessageActivationKind.closed;
    _code = 'push.messages_closed';
  }

  Future<void> _cancel() {
    final subscription = _subscription;
    if (subscription == null) return Future<void>.value();
    final pending = _cancellation;
    if (pending != null) return pending;
    final completion = Completer<void>();
    _cancellation = completion.future;
    unawaited(_cancelSafely(subscription, completion));
    return completion.future;
  }

  Future<void> _cancelSafely(
    StreamSubscription<Object?> subscription,
    Completer<void> completion,
  ) async {
    try {
      await subscription.cancel();
    } on Object {
      _kind = PushMessageActivationKind.failure;
      _code = 'push.message_failed';
    } finally {
      completion.complete();
    }
  }
}

/// Dormant by default. Permission, registration and listening are independent.
final class StarterPushCapability {
  const StarterPushCapability({this.enabled = false, this.provider});

  final bool enabled;
  final PushProvider? provider;

  Future<PushPermissionResult> permissionStatus() =>
      _permission('permissionStatus');

  Future<PushPermissionResult> requestPermission() =>
      _permission('requestPermission');

  Future<PushPermissionResult> _permission(String method) async {
    if (!enabled) {
      return const PushPermissionResult._(
        PushPermissionKind.unavailable,
        'push.disabled',
      );
    }
    try {
      return _decodePermission(
        await _pushChannel.invokeMethod<Object?>(method),
      );
    } on MissingPluginException {
      return const PushPermissionResult._(
        PushPermissionKind.unavailable,
        'push.platform_unavailable',
      );
    } on Object {
      return const PushPermissionResult._(
        PushPermissionKind.failure,
        'push.permission_failed',
      );
    }
  }

  Future<PushRegistrationResult> register() async {
    if (!enabled) {
      return const PushRegistrationResult._(
        PushRegistrationKind.unavailable,
        'push.disabled',
      );
    }
    final configured = provider;
    if (configured == null) {
      return const PushRegistrationResult._(
        PushRegistrationKind.unavailable,
        'push.provider_not_configured',
      );
    }
    try {
      final result = await configured.register();
      final token = result.token;
      if (result.kind == PushProviderRegistrationKind.registered) {
        if (token == null ||
            token.trim().isEmpty ||
            !_validString(token, 4096)) {
          return const PushRegistrationResult._(
            PushRegistrationKind.invalid,
            'push.invalid_provider_result',
          );
        }
        return PushRegistrationResult._(
          PushRegistrationKind.registered,
          'push.registered',
          token,
        );
      }
      if (token != null) {
        return const PushRegistrationResult._(
          PushRegistrationKind.invalid,
          'push.invalid_provider_result',
        );
      }
      return switch (result.kind) {
        PushProviderRegistrationKind.denied => const PushRegistrationResult._(
          PushRegistrationKind.denied,
          'push.registration_denied',
        ),
        PushProviderRegistrationKind.unavailable =>
          const PushRegistrationResult._(
            PushRegistrationKind.unavailable,
            'push.provider_unavailable',
          ),
        PushProviderRegistrationKind.cancelled =>
          const PushRegistrationResult._(
            PushRegistrationKind.cancelled,
            'push.registration_cancelled',
          ),
        _ => const PushRegistrationResult._(
          PushRegistrationKind.failure,
          'push.registration_failed',
        ),
      };
    } on Object {
      return const PushRegistrationResult._(
        PushRegistrationKind.failure,
        'push.registration_failed',
      );
    }
  }

  PushMessageActivation activateMessages({
    required void Function(PushMessage) onMessage,
  }) {
    if (!enabled) {
      return PushMessageActivation._(
        PushMessageActivationKind.unavailable,
        'push.disabled',
      );
    }
    final configured = provider;
    if (configured == null) {
      return PushMessageActivation._(
        PushMessageActivationKind.unavailable,
        'push.provider_not_configured',
      );
    }
    final handle = PushMessageActivation._(
      PushMessageActivationKind.active,
      'push.messages_active',
      onMessage,
    );
    try {
      handle._attach(
        configured.messages.listen(
          handle._receive,
          onError: (Object error, StackTrace stack) =>
              handle._fail('push.message_failed'),
          onDone: handle._done,
        ),
      );
    } on Object {
      handle._fail('push.message_failed');
    }
    return handle;
  }
}

PushPermissionResult _decodePermission(Object? raw) {
  const invalid = PushPermissionResult._(
    PushPermissionKind.failure,
    'push.invalid_native_response',
  );
  if (raw is! Map || raw.length != 2) return invalid;
  final kind = raw['kind'];
  final code = raw['code'];
  if (kind is! String || code is! String) return invalid;
  const pairs = <(String, String), PushPermissionKind>{
    ('granted', 'push.permission_granted'): PushPermissionKind.granted,
    ('notDetermined', 'push.permission_not_determined'):
        PushPermissionKind.notDetermined,
    ('denied', 'push.permission_denied'): PushPermissionKind.denied,
    ('restricted', 'push.permission_restricted'): PushPermissionKind.restricted,
    ('unavailable', 'push.permission_not_configured'):
        PushPermissionKind.unavailable,
    ('unavailable', 'push.activity_unavailable'):
        PushPermissionKind.unavailable,
    ('unavailable', 'push.platform_unavailable'):
        PushPermissionKind.unavailable,
    ('conflict', 'push.operation_in_progress'): PushPermissionKind.conflict,
    ('invalid', 'push.invalid_arguments'): PushPermissionKind.invalid,
    ('failure', 'push.permission_failed'): PushPermissionKind.failure,
    ('failure', 'push.engine_detached'): PushPermissionKind.failure,
    ('failure', 'push.activity_detached'): PushPermissionKind.failure,
    ('failure', 'push.dispatch_failed'): PushPermissionKind.failure,
  };
  final parsed = pairs[(kind, code)];
  return parsed == null ? invalid : PushPermissionResult._(parsed, code);
}

bool _validString(String value, int maxBytes) {
  if (value.length > maxBytes) return false;
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
  return utf8.encode(value).length <= maxBytes;
}

PushMessage? _parseMessage(Object? raw) {
  if (raw is! Map ||
      raw.length > 3 ||
      raw.keys.any((key) => key != 'title' && key != 'body' && key != 'data')) {
    return null;
  }
  final title = raw['title'];
  final body = raw['body'];
  if ((raw.containsKey('title') &&
          (title is! String || !_validString(title, 256))) ||
      (raw.containsKey('body') &&
          (body is! String || !_validString(body, 2048)))) {
    return null;
  }
  if (!(title is String && title.trim().isNotEmpty) &&
      !(body is String && body.trim().isNotEmpty)) {
    return null;
  }
  final data = <String, String>{};
  if (raw.containsKey('data')) {
    final incoming = raw['data'];
    if (incoming is! Map || incoming.length > 32) return null;
    const sensitive = [
      'password',
      'secret',
      'token',
      'authorization',
      'credential',
      'apikey',
      'privatekey',
    ];
    for (final entry in incoming.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String ||
          value is! String ||
          key.trim().isEmpty ||
          !_validString(key, 64) ||
          !_validString(value, 512)) {
        return null;
      }
      final normalized = key.toLowerCase().replaceAll(RegExp('[^a-z]'), '');
      if (sensitive.any(normalized.contains)) return null;
      data[key] = value;
    }
  }
  return PushMessage._(
    title as String?,
    body as String?,
    Map.unmodifiable(data),
  );
}
