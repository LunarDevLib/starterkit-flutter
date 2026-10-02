import 'dart:convert';
import 'dart:typed_data';

import '../../core/async/cancellation.dart';
import '../../core/network/api_client.dart';
import 'service_safety.dart';

enum CrashConsent { denied, granted }

enum HandledIssue {
  assertion,
  parsing,
  network,
  persistence,
  authentication,
  other,
}

final class HandledReport {
  HandledReport({
    required this.issue,
    required this.code,
    Map<String, String> context = const {},
  }) : context = Map.unmodifiable(context);

  final HandledIssue issue;
  final String code;
  final Map<String, String> context;
}

/// Explicit handled/nonfatal reporting only.
///
/// This service installs no fatal handler, captures no stack trace, and sends
/// nothing unless [submit] is called with granted consent.
final class CrashReportingService {
  CrashReportingService({
    required ApiClient client,
    required CrashConsent consent,
    String endpoint = 'crash/handled',
  }) : _client = client,
       _consent = consent,
       _endpoint = ServiceSafety.endpoint(endpoint);

  static const Set<String> _allowedContextKeys = {
    'operation',
    'screen',
    'component',
    'stage',
  };

  final ApiClient _client;
  final CrashConsent _consent;
  final String _endpoint;

  Future<void> submit(
    HandledReport report, {
    CancellationToken? cancellation,
  }) async {
    if (_consent == CrashConsent.denied) return;
    if (!ServiceSafety.safeCode(report.code) ||
        report.context.length > 4 ||
        !report.context.keys.every(_allowedContextKeys.contains)) {
      throw ArgumentError('Handled report is invalid.');
    }
    for (final value in report.context.values) {
      if (!ServiceSafety.safeCode(value, maxBytes: 64)) {
        throw ArgumentError('Handled report context is invalid.');
      }
    }

    final sortedContext = Map<String, String>.fromEntries(
      report.context.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    final body = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'issue': report.issue.name,
          'code': report.code,
          'context': sortedContext,
        }),
      ),
    );
    if (body.length > 1024) {
      throw ArgumentError('Handled report exceeds the allowed size.');
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
}
