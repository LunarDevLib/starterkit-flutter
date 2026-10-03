import 'dart:convert';

import 'package:flutter/services.dart';

const MethodChannel _shareChannel = MethodChannel('starterkit/platform/share');

enum NativeShareResultKind {
  presented,
  completed,
  cancelled,
  invalid,
  unavailable,
  conflict,
  failure,
}

/// Presentation/completion is not proof of recipient delivery.
final class NativeShareResult {
  const NativeShareResult._(this.kind, this.code);

  final NativeShareResultKind kind;
  final String code;
}

/// A product-supplied rectangle in the attached host view's logical points.
final class NativeShareAnchor {
  const NativeShareAnchor({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final double x;
  final double y;
  final double width;
  final double height;

  bool get _valid =>
      x.isFinite &&
      y.isFinite &&
      width.isFinite &&
      height.isFinite &&
      (x + width).isFinite &&
      (y + height).isFinite &&
      x >= 0 &&
      y >= 0 &&
      width > 0 &&
      height > 0;

  Map<String, double> get _snapshot =>
      Map.unmodifiable({'x': x, 'y': y, 'width': width, 'height': height});
}

/// Dormant unless explicitly enabled and called; never acquires or opens files.
final class StarterNativeShareCapability {
  const StarterNativeShareCapability({this.enabled = false});

  final bool enabled;

  Future<NativeShareResult> share({
    String? text,
    String? httpsUrl,
    String? fileUri,
    NativeShareAnchor? anchor,
  }) async {
    if (!enabled) {
      return const NativeShareResult._(
        NativeShareResultKind.unavailable,
        'share.disabled',
      );
    }
    if (!((text?.isNotEmpty ?? false) ||
            (httpsUrl?.isNotEmpty ?? false) ||
            (fileUri?.isNotEmpty ?? false)) ||
        (text != null && !_validString(text, 16384, maxCharacters: 4000)) ||
        (httpsUrl != null && !_validHttpsUrl(httpsUrl)) ||
        (fileUri != null && !_validFileUri(fileUri)) ||
        (anchor != null && !anchor._valid)) {
      return const NativeShareResult._(
        NativeShareResultKind.invalid,
        'share.invalid_payload',
      );
    }
    // Strings and the final anchor fields are immutable. Capture every supplied
    // value in an immutable wire map synchronously, before the first await.
    final payload = Map<String, Object>.unmodifiable({
      if (text != null) 'text': text,
      if (httpsUrl != null) 'httpsUrl': httpsUrl,
      if (fileUri != null) 'fileUri': fileUri,
      if (anchor != null) 'anchor': anchor._snapshot,
    });
    try {
      final raw = await _shareChannel.invokeMethod<Object?>('share', payload);
      return _decodeResult(raw);
    } on MissingPluginException {
      return const NativeShareResult._(
        NativeShareResultKind.unavailable,
        'share.platform_unavailable',
      );
    } on Object {
      return const NativeShareResult._(
        NativeShareResultKind.failure,
        'share.platform_failure',
      );
    }
  }
}

bool _validString(String value, int maxBytes, {int? maxCharacters}) {
  if (value.length > maxBytes) return false;
  // Reject lone UTF-16 surrogates before UTF-8 encoding can replace them.
  var characters = 0;
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
    characters++;
    if (maxCharacters != null && characters > maxCharacters) return false;
  }
  return utf8.encode(value).length <= maxBytes;
}

Uri? _boundedUri(String value) {
  if (value.isEmpty || !_validString(value, 2048)) return null;
  // Uri.parse normalizes stray percent signs; do not repair malformed input.
  if (RegExp(r'%(?![0-9a-fA-F]{2})').hasMatch(value)) return null;
  try {
    return Uri.parse(value);
  } on FormatException {
    return null;
  }
}

String? _authority(String value) =>
    RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*://([^/?#]*)').firstMatch(value)?.group(1);

bool _validHttpsUrl(String value) {
  final uri = _boundedUri(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.hasFragment ||
      uri.userInfo.isNotEmpty ||
      RegExp(r'\s').hasMatch(value) ||
      value.contains('\\')) {
    return false;
  }
  final host = uri.host;
  if (host.isEmpty ||
      host.length > 253 ||
      host.endsWith('.') ||
      !host
          .split('.')
          .every(
            (label) =>
                label.length <= 63 &&
                RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$')
                    .hasMatch(label),
          )) {
    return false;
  }
  final authority = _authority(value)?.toLowerCase();
  if (authority != host.toLowerCase() &&
      authority != '${host.toLowerCase()}:443') {
    return false;
  }
  const sensitiveKeys = [
    'token',
    'access_token',
    'authorization',
    'auth',
    'api_key',
    'key',
    'password',
    'secret',
    'session',
    'code',
  ];
  try {
    for (final parameter in uri.query.split('&')) {
      final rawKey = parameter.split('=').first.toLowerCase();
      final key = Uri.decodeQueryComponent(rawKey).toLowerCase();
      if (!_validString(key, 2048) ||
          sensitiveKeys.any(
            (sensitive) =>
                rawKey.contains(sensitive) || key.contains(sensitive),
          )) {
        return false;
      }
    }
  } on FormatException {
    return false;
  }
  return true;
}

bool _validFileUri(String value) {
  final uri = _boundedUri(value);
  if (uri == null ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort ||
      value.contains('\\')) {
    return false;
  }
  final authority = _authority(value);
  if (authority == null || authority.contains('@')) return false;
  if (uri.scheme == 'content') return authority.isNotEmpty;
  return uri.scheme == 'file' && uri.path.startsWith('/');
}

NativeShareResult _decodeResult(Object? raw) {
  const invalid = NativeShareResult._(
    NativeShareResultKind.invalid,
    'share.invalid_native_response',
  );
  if (raw is! Map || raw.length != 2) return invalid;
  final kind = raw['kind'];
  final code = raw['code'];
  if (kind is! String || code is! String) return invalid;
  const pairs = <(String, String), NativeShareResultKind>{
    ('presented', 'share.presented'): NativeShareResultKind.presented,
    ('completed', 'share.completed'): NativeShareResultKind.completed,
    ('cancelled', 'share.cancelled'): NativeShareResultKind.cancelled,
    ('invalid', 'share.invalid_payload'): NativeShareResultKind.invalid,
    ('unavailable', 'share.platform_unavailable'):
        NativeShareResultKind.unavailable,
    ('unavailable', 'share.host_unavailable'):
        NativeShareResultKind.unavailable,
    ('unavailable', 'share.file_unavailable'):
        NativeShareResultKind.unavailable,
    ('conflict', 'share.operation_in_progress'): NativeShareResultKind.conflict,
    ('cancelled', 'share.engine_detached'): NativeShareResultKind.cancelled,
    ('failure', 'share.platform_failure'): NativeShareResultKind.failure,
  };
  final parsed = pairs[(kind, code)];
  return parsed == null ? invalid : NativeShareResult._(parsed, code);
}
