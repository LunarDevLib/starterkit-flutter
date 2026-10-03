import 'package:flutter/services.dart';

import 'src/payload_validation.dart';

const MethodChannel _channel = MethodChannel('starterkit/qr_barcode');
const int _maxEncodedBytes = 10 * 1024 * 1024;
const int _maxPayloadBytes = 2048;
const int _maxCodes = 16;
const int _maxAggregatePayloadBytes = 32768;

enum QrBarcodeResultKind {
  success,
  noResult,
  unsupported,
  unavailable,
  cancelled,
  invalid,
  conflict,
  failure,
}

enum QrBarcodeFormat { qr, ean13, code128 }

final class QrBarcodeCode {
  const QrBarcodeCode._(this.value, this.format);

  final String value;
  final QrBarcodeFormat format;
}

final class QrBarcodeResult {
  QrBarcodeResult._(this.kind, this.code, Iterable<QrBarcodeCode> codes)
    : codes = List<QrBarcodeCode>.unmodifiable(codes);

  final QrBarcodeResultKind kind;
  final String code;
  final List<QrBarcodeCode> codes;

  bool get isSuccess => kind == QrBarcodeResultKind.success;
}

/// Still-image decoder. Native functionality is opt-in and disabled by default.
final class StarterQrBarcodeCapability {
  const StarterQrBarcodeCapability({this.enabled = false});

  final bool enabled;

  /// Decodes encoded image bytes without accessing a camera, path, or URL.
  ///
  /// Disabled calls always return [QrBarcodeResultKind.unavailable] without
  /// validating, copying, or sending [encodedImage]. Enabled input is bounded
  /// and copied synchronously before this method returns to its caller.
  Future<QrBarcodeResult> decode(Uint8List encodedImage) {
    if (!enabled) {
      return Future<QrBarcodeResult>.value(
        _outcome(QrBarcodeResultKind.unavailable, 'qr.disabled'),
      );
    }
    if (encodedImage.isEmpty) {
      return Future<QrBarcodeResult>.value(
        _outcome(QrBarcodeResultKind.invalid, 'qr.invalid_image'),
      );
    }
    if (encodedImage.length > _maxEncodedBytes) {
      return Future<QrBarcodeResult>.value(
        _outcome(QrBarcodeResultKind.invalid, 'qr.image_too_large'),
      );
    }

    // Take ownership before any asynchronous boundary; caller mutation cannot
    // alter the bytes ultimately submitted to the platform channel.
    final snapshot = Uint8List.fromList(encodedImage);
    return _decodeSnapshot(snapshot);
  }
}

Future<QrBarcodeResult> _decodeSnapshot(Uint8List bytes) async {
  try {
    final raw = await _channel.invokeMethod<Object?>('decodeImage', {
      'bytes': bytes,
    });
    return _decodeNativeResult(raw);
  } on MissingPluginException {
    return _outcome(QrBarcodeResultKind.unavailable, 'qr.platform_unavailable');
  } on Object {
    return _outcome(QrBarcodeResultKind.failure, 'qr.platform_failure');
  }
}

QrBarcodeResult _decodeNativeResult(Object? raw) {
  if (raw is! Map || !_stringKeys(raw)) return _invalidNative();
  final kind = raw['kind'];
  final code = raw['code'];
  if (kind is! String || code is! String) return _invalidNative();

  final outcome = _outcomes[(kind, code)];
  if (outcome == null) return _invalidNative();
  if (kind != 'success') {
    if (!_exactKeys(raw, const {'kind', 'code'})) return _invalidNative();
    return _outcome(outcome, code);
  }
  if (!_exactKeys(raw, const {'kind', 'code', 'codes'})) {
    return _invalidNative();
  }
  final rawCodes = raw['codes'];
  if (rawCodes is! List || rawCodes.isEmpty || rawCodes.length > _maxCodes) {
    return _invalidNative();
  }

  final codes = <QrBarcodeCode>[];
  var aggregateBytes = 0;
  for (final rawCode in rawCodes) {
    if (rawCode is! Map ||
        !_stringKeys(rawCode) ||
        !_exactKeys(rawCode, const {'value', 'format'})) {
      return _invalidNative();
    }
    final value = rawCode['value'];
    final formatName = rawCode['format'];
    if (value is! String || formatName is! String) return _invalidNative();
    final format = _formats[formatName];
    if (format == null) return _invalidNative();
    final payloadBytes = validQrPayloadLength(value);
    if (payloadBytes == null ||
        payloadBytes == 0 ||
        payloadBytes > _maxPayloadBytes) {
      return _invalidNative();
    }
    aggregateBytes += payloadBytes;
    if (aggregateBytes > _maxAggregatePayloadBytes) return _invalidNative();
    codes.add(QrBarcodeCode._(value, format));
  }
  return QrBarcodeResult._(outcome, code, codes);
}

QrBarcodeResult _outcome(QrBarcodeResultKind kind, String code) =>
    QrBarcodeResult._(kind, code, const <QrBarcodeCode>[]);

QrBarcodeResult _invalidNative() =>
    _outcome(QrBarcodeResultKind.invalid, 'qr.invalid_native_response');

bool _stringKeys(Map map) => map.keys.every((key) => key is String);

bool _exactKeys(Map map, Set<String> expected) =>
    map.length == expected.length && map.keys.toSet().containsAll(expected);

const Map<(String, String), QrBarcodeResultKind> _outcomes = {
  ('success', 'qr.success'): QrBarcodeResultKind.success,
  ('noResult', 'qr.no_result'): QrBarcodeResultKind.noResult,
  ('unsupported', 'qr.unsupported_format'): QrBarcodeResultKind.unsupported,
  ('unavailable', 'qr.disabled'): QrBarcodeResultKind.unavailable,
  ('unavailable', 'qr.platform_unavailable'): QrBarcodeResultKind.unavailable,
  ('unavailable', 'qr.unavailable'): QrBarcodeResultKind.unavailable,
  ('cancelled', 'qr.engine_detached'): QrBarcodeResultKind.cancelled,
  ('invalid', 'qr.invalid_request'): QrBarcodeResultKind.invalid,
  ('invalid', 'qr.invalid_image'): QrBarcodeResultKind.invalid,
  ('invalid', 'qr.image_too_large'): QrBarcodeResultKind.invalid,
  ('invalid', 'qr.image_dimensions'): QrBarcodeResultKind.invalid,
  ('invalid', 'qr.invalid_payload'): QrBarcodeResultKind.invalid,
  ('invalid', 'qr.invalid_native_response'): QrBarcodeResultKind.invalid,
  ('conflict', 'qr.operation_in_progress'): QrBarcodeResultKind.conflict,
  ('failure', 'qr.decode_error'): QrBarcodeResultKind.failure,
  ('failure', 'qr.platform_failure'): QrBarcodeResultKind.failure,
};

const Map<String, QrBarcodeFormat> _formats = {
  'QR': QrBarcodeFormat.qr,
  'EAN13': QrBarcodeFormat.ean13,
  'Code128': QrBarcodeFormat.code128,
};
