import 'dart:convert';
import 'dart:typed_data';

import '../../core/async/cancellation.dart';
import '../../core/failure/app_failure.dart';
import '../../core/network/api_client.dart';

final class ServiceSafety {
  const ServiceSafety._();

  static final RegExp _codePattern = RegExp(r'^[A-Za-z0-9._-]+$');

  static bool safeCode(String value, {int maxBytes = 48}) {
    return value.isNotEmpty &&
        utf8.encode(value).length <= maxBytes &&
        _codePattern.hasMatch(value);
  }

  static bool hasControl(String value) =>
      value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f);

  static String endpoint(String path) {
    ApiRequest(method: ApiMethod.get, path: path);
    return path;
  }

  static Future<Uint8List> execute(
    ApiClient client,
    ApiRequest request, {
    int maxResponseBytes = 64 * 1024,
    CancellationToken? cancellation,
  }) async {
    if (maxResponseBytes < 0 ||
        maxResponseBytes > ApiResponse.maxResponseBodyBytes) {
      throw ArgumentError.value(maxResponseBytes, 'maxResponseBytes');
    }
    final response = await client.execute(
      request,
      cancellation: cancellation,
    );
    final failure = AppFailure.fromHttpStatus(response.statusCode);
    if (failure != null) throw failure;
    final body = response.body;
    if (body.length > maxResponseBytes) {
      throw AppFailure(
        FailureKind.validation,
        code: 'service.response_too_large',
        localizationKey: 'failure.service.response_too_large',
      );
    }
    return body;
  }
}
