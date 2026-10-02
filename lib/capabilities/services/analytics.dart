import 'dart:convert';
import 'dart:typed_data';

import '../../core/async/cancellation.dart';
import '../../core/network/api_client.dart';
import 'service_safety.dart';

enum AnalyticsConsent { denied, granted }

enum AnalyticsField { screen, action, category, value, success }

sealed class AnalyticsFieldValue {
  const AnalyticsFieldValue();
}

final class AnalyticsText extends AnalyticsFieldValue {
  const AnalyticsText(this.value);
  final String value;
}

final class AnalyticsInteger extends AnalyticsFieldValue {
  const AnalyticsInteger(this.value);
  final int value;
}

final class AnalyticsDecimal extends AnalyticsFieldValue {
  const AnalyticsDecimal(this.value);
  final double value;
}

final class AnalyticsBoolean extends AnalyticsFieldValue {
  const AnalyticsBoolean(this.value);
  final bool value;
}

final class AnalyticsEvent {
  AnalyticsEvent({
    required this.name,
    Map<AnalyticsField, AnalyticsFieldValue> fields = const {},
  }) : fields = Map.unmodifiable(fields);

  final String name;
  final Map<AnalyticsField, AnalyticsFieldValue> fields;
}

/// Backend-neutral, explicit analytics submission.
///
/// Construction performs no I/O. With denied consent, [submit] returns without
/// consulting the transport.
final class AnalyticsService {
  AnalyticsService({
    required ApiClient client,
    required AnalyticsConsent consent,
    String endpoint = 'analytics/events',
  }) : _client = client,
       _consent = consent,
       _endpoint = ServiceSafety.endpoint(endpoint);

  final ApiClient _client;
  final AnalyticsConsent _consent;
  final String _endpoint;

  Future<void> submit(
    AnalyticsEvent event, {
    CancellationToken? cancellation,
  }) async {
    if (_consent == AnalyticsConsent.denied) return;
    if (!ServiceSafety.safeCode(event.name, maxBytes: 64) ||
        event.fields.length > 8) {
      throw ArgumentError('Analytics event is invalid.');
    }

    final encodedFields = <String, Object>{};
    for (final entry in event.fields.entries) {
      encodedFields[entry.key.name] = switch (entry.value) {
        AnalyticsText(:final value) => _validateText(value),
        AnalyticsInteger(:final value) => value,
        AnalyticsDecimal(:final value) => _validateDecimal(value),
        AnalyticsBoolean(:final value) => value,
      };
    }

    final body = Uint8List.fromList(
      utf8.encode(jsonEncode({'name': event.name, 'fields': encodedFields})),
    );
    if (body.length > 2048) {
      throw ArgumentError('Analytics event exceeds the allowed size.');
    }

    await ServiceSafety.execute(
      _client,
      ApiRequest(
        method: ApiMethod.post,
        path: _endpoint,
        headers: const {'Content-Type': 'application/json'},
        body: body,
      ),
      cancellation: cancellation,
    );
  }

  static String _validateText(String value) {
    if (utf8.encode(value).length > 128 || ServiceSafety.hasControl(value)) {
      throw ArgumentError('Analytics text field is invalid.');
    }
    return value;
  }

  static double _validateDecimal(double value) {
    if (!value.isFinite) {
      throw ArgumentError('Analytics decimal field must be finite.');
    }
    return value;
  }
}
