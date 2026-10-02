import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_starterkit/capabilities/services/analytics.dart';
import 'package:flutter_starterkit/capabilities/services/crash_reporting.dart';
import 'package:flutter_starterkit/capabilities/services/remote_config.dart';
import 'package:flutter_starterkit/core/async/cancellation.dart';
import 'package:flutter_starterkit/core/network/api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AnalyticsService', () {
    test('denied consent performs zero transport calls', () async {
      final client = _FakeApiClient();
      final service = AnalyticsService(
        client: client,
        consent: AnalyticsConsent.denied,
      );

      await service.submit(AnalyticsEvent(name: 'screen.open'));

      expect(client.requests, isEmpty);
    });

    test('submits only bounded typed fields', () async {
      final client = _FakeApiClient();
      final service = AnalyticsService(
        client: client,
        consent: AnalyticsConsent.granted,
      );

      await service.submit(
        AnalyticsEvent(
          name: 'screen.open',
          fields: const {
            AnalyticsField.screen: AnalyticsText('sample'),
            AnalyticsField.success: AnalyticsBoolean(true),
            AnalyticsField.value: AnalyticsInteger(3),
          },
        ),
      );

      expect(client.requests, hasLength(1));
      final request = client.requests.single;
      expect(request.method, ApiMethod.post);
      expect(request.path, 'analytics/events');
      final body = jsonDecode(utf8.decode(request.body!)) as Map<String, dynamic>;
      expect(body['name'], 'screen.open');
      expect(
        body['fields'],
        {'screen': 'sample', 'success': true, 'value': 3},
      );
    });

    test('invalid event is rejected before transport', () async {
      final client = _FakeApiClient();
      final service = AnalyticsService(
        client: client,
        consent: AnalyticsConsent.granted,
      );

      await expectLater(
        service.submit(
          AnalyticsEvent(
            name: 'screen.open',
            fields: const {
              AnalyticsField.screen: AnalyticsText('unsafe\nvalue'),
            },
          ),
        ),
        throwsArgumentError,
      );
      expect(client.requests, isEmpty);
    });
  });

  group('CrashReportingService', () {
    test('denied consent performs zero transport calls', () async {
      final client = _FakeApiClient();
      final service = CrashReportingService(
        client: client,
        consent: CrashConsent.denied,
      );

      await service.submit(
        HandledReport(issue: HandledIssue.parsing, code: 'parse.failed'),
      );

      expect(client.requests, isEmpty);
    });

    test('submits only handled safe codes and allowlisted context', () async {
      final client = _FakeApiClient();
      final service = CrashReportingService(
        client: client,
        consent: CrashConsent.granted,
      );

      await service.submit(
        HandledReport(
          issue: HandledIssue.persistence,
          code: 'write.failed',
          context: const {'operation': 'save_item', 'stage': 'commit'},
        ),
      );

      final body =
          jsonDecode(utf8.decode(client.requests.single.body!))
              as Map<String, dynamic>;
      expect(body['issue'], 'persistence');
      expect(body['code'], 'write.failed');
      expect(body['context'], {'operation': 'save_item', 'stage': 'commit'});
    });

    test('arbitrary context is rejected before transport', () async {
      final client = _FakeApiClient();
      final service = CrashReportingService(
        client: client,
        consent: CrashConsent.granted,
      );

      await expectLater(
        service.submit(
          HandledReport(
            issue: HandledIssue.other,
            code: 'handled.failure',
            context: const {'token': 'must_not_send'},
          ),
        ),
        throwsArgumentError,
      );
      expect(client.requests, isEmpty);
    });
  });

  group('RemoteConfigService', () {
    late DateTime now;
    late _FakeApiClient client;

    setUp(() {
      now = DateTime.utc(2026, 10, 2, 12);
      client = _FakeApiClient();
    });

    RemoteConfigService service() => RemoteConfigService(
      client: client,
      defaults: const {
        'sample.enabled': RemoteBoolean(false),
        'sample.limit': RemoteInteger(5),
        'sample.label': RemoteText('local'),
      },
      allowedSchema: const {
        'sample.enabled': RemoteValueType.boolean,
        'sample.limit': RemoteValueType.integer,
        'sample.label': RemoteValueType.text,
      },
      now: () => now,
    );

    test('applies a complete typed snapshot atomically', () async {
      client.handler = (_) async => _jsonResponse({
        'version': 2,
        'expires_at': now.add(const Duration(hours: 1)).millisecondsSinceEpoch /
            1000,
        'values': {
          'sample.enabled': true,
          'sample.limit': 9,
          'sample.label': 'remote',
        },
      });
      final remote = service();

      await remote.fetch();

      expect(remote.snapshot.version, 2);
      expect(remote.flags.value('sample.enabled'), const RemoteBoolean(true));
      expect(remote.flags.value('sample.limit'), const RemoteInteger(9));
      expect(remote.flags.value('sample.label'), const RemoteText('remote'));
    });

    test('invalid protected or unknown data preserves prior snapshot', () async {
      var response = <String, Object?>{
        'version': 1,
        'expires_at': now.add(const Duration(hours: 1)).millisecondsSinceEpoch /
            1000,
        'values': {'sample.enabled': true},
      };
      client.handler = (_) async => _jsonResponse(response);
      final remote = service();
      await remote.fetch();
      expect(remote.snapshot.version, 1);

      response = {
        'version': 2,
        'expires_at': now.add(const Duration(hours: 1)).millisecondsSinceEpoch /
            1000,
        'values': {'security.endpoint': 'https://evil.invalid'},
      };
      await expectLater(remote.fetch(), throwsFormatException);

      expect(remote.snapshot.version, 1);
      expect(remote.flags.value('sample.enabled'), const RemoteBoolean(true));
    });

    test('expired active snapshot falls back to local defaults', () async {
      client.handler = (_) async => _jsonResponse({
        'version': 1,
        'expires_at':
            now.add(const Duration(minutes: 5)).millisecondsSinceEpoch / 1000,
        'values': {'sample.enabled': true},
      });
      final remote = service();

      await remote.fetch();
      expect(remote.flags.value('sample.enabled'), const RemoteBoolean(true));

      now = now.add(const Duration(minutes: 6));
      expect(remote.flags.value('sample.enabled'), const RemoteBoolean(false));
    });

    test('newer overlapping fetch wins even if older completes later', () async {
      final first = Completer<ApiResponse>();
      final second = Completer<ApiResponse>();
      var call = 0;
      client.handler = (_) {
        call += 1;
        return call == 1 ? first.future : second.future;
      };
      final remote = service();

      final oldFetch = remote.fetch();
      final newFetch = remote.fetch();
      second.complete(
        _jsonResponse({
          'version': 2,
          'expires_at': now.add(const Duration(hours: 2)).millisecondsSinceEpoch /
              1000,
          'values': {'sample.limit': 20},
        }),
      );
      await newFetch;
      first.complete(
        _jsonResponse({
          'version': 1,
          'expires_at': now.add(const Duration(hours: 1)).millisecondsSinceEpoch /
              1000,
          'values': {'sample.limit': 10},
        }),
      );
      await oldFetch;

      expect(remote.snapshot.version, 2);
      expect(remote.flags.value('sample.limit'), const RemoteInteger(20));
    });
  });
}

final class _FakeApiClient implements ApiClient {
  _FakeApiClient();

  @override
  final Uri baseEndpoint = Uri.parse('https://api.example.test/v1/');

  final List<ApiRequest> requests = [];
  Future<ApiResponse> Function(ApiRequest request)? handler;

  @override
  Future<ApiResponse> execute(
    ApiRequest request, {
    CancellationToken? cancellation,
    Duration? timeout,
  }) async {
    requests.add(request);
    final active = handler;
    if (active != null) return active(request);
    return ApiResponse(
      statusCode: 204,
      body: Uint8List(0),
    );
  }
}

ApiResponse _jsonResponse(Map<String, Object?> value) => ApiResponse(
  statusCode: 200,
  headers: const {
    'content-type': ['application/json'],
  },
  body: Uint8List.fromList(utf8.encode(jsonEncode(value))),
);
