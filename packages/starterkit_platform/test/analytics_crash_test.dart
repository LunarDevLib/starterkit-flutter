import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:starterkit_platform/starterkit_platform.dart';

const _host = 'metrics.example.test';
const _origin = 'https://metrics.example.test';
AnalyticsEvent _event() => AnalyticsEvent(name: 'product.action');
HandledReport _report() =>
    HandledReport(issue: HandledIssue.parsing, code: 'invalid_shape');

void main() {
  test('construction and default actions never access the transport', () async {
    final transport = _Transport();
    final analytics = StarterAnalyticsService(transport: transport);
    final crash = StarterCrashReportingService(transport: transport);
    _analytics(transport);
    _crash(transport);
    expect(transport.getters, 0);
    expect(transport.requests, isEmpty);
    expect(analytics.enabled, isFalse);
    expect(analytics.consent, AnalyticsConsent.denied);
    expect(crash.enabled, isFalse);
    expect(crash.consent, CrashConsent.denied);
    for (final result in [
      await analytics.submit(_event()),
      await crash.submit(_report()),
      await StarterAnalyticsService().submit(_event()),
      await StarterCrashReportingService().submit(_report()),
    ]) {
      expect(result.kind, TelemetrySubmitKind.disabled);
      expect(result.code, 'telemetry.disabled');
    }
    expect(transport.getters, 0);
    expect(transport.requests, isEmpty);
  });

  test(
    'denied and disabled malformed calls make zero getter and execute calls',
    () async {
      final transport = _Transport()
        ..getterError = StateError('private endpoint');
      final malformedEvent = AnalyticsEvent(
        name: 'private identity@example.test',
      );
      final malformedReport = HandledReport(
        issue: HandledIssue.other,
        code: 'raw exception prose',
        context: {'token': 'private'},
      );
      for (final enabled in [false, true]) {
        final analytics = StarterAnalyticsService(
          enabled: enabled,
          transport: transport,
          endpoint: '//evil.invalid',
          allowedHosts: {'INVALID HOST'},
        );
        final crash = StarterCrashReportingService(
          enabled: enabled,
          transport: transport,
          endpoint: '../escape',
          allowedHosts: {'*'},
        );
        for (final result in [
          await analytics.submit(malformedEvent),
          await crash.submit(malformedReport),
        ]) {
          expect(
            result.kind,
            enabled ? TelemetrySubmitKind.denied : TelemetrySubmitKind.disabled,
          );
          expect(
            result.code,
            enabled ? 'telemetry.consent_denied' : 'telemetry.disabled',
          );
        }
      }
      expect(transport.getters, 0);
      expect(transport.requests, isEmpty);
    },
  );

  test(
    'disabled precedes granted consent and missing transport precedes payload',
    () async {
      final analytics = StarterAnalyticsService(
        consent: AnalyticsConsent.granted,
      );
      final crash = StarterCrashReportingService(consent: CrashConsent.granted);
      expect((await analytics.submit(_event())).code, 'telemetry.disabled');
      expect((await crash.submit(_report())).code, 'telemetry.disabled');
      for (final result in [
        await StarterAnalyticsService(enabled: true).submit(_event()),
        await StarterCrashReportingService(enabled: true).submit(_report()),
      ]) {
        expect(result.code, 'telemetry.consent_denied');
      }
      for (final result in [
        await StarterAnalyticsService(
          enabled: true,
          consent: AnalyticsConsent.granted,
        ).submit(AnalyticsEvent(name: 'invalid name')),
        await StarterCrashReportingService(
          enabled: true,
          consent: CrashConsent.granted,
        ).submit(
          HandledReport(issue: HandledIssue.other, code: 'invalid code'),
        ),
      ]) {
        expect(result.kind, TelemetrySubmitKind.unavailable);
        expect(result.code, 'telemetry.transport_not_configured');
      }
    },
  );

  test(
    'analytics makes one exact typed JSON POST on explicit submission',
    () async {
      final transport = _Transport();
      final event = AnalyticsEvent(
        name: 'Product.action-1',
        fields: const {
          AnalyticsField.screen: AnalyticsFieldValue.text('Settings screen'),
          AnalyticsField.action: AnalyticsFieldValue.integer(-3),
          AnalyticsField.category: AnalyticsFieldValue.decimal(1.25),
          AnalyticsField.value: AnalyticsFieldValue.boolean(false),
          AnalyticsField.success: AnalyticsFieldValue.boolean(true),
        },
      );
      final result = await _analytics(transport).submit(event);
      expect(result.kind, TelemetrySubmitKind.submitted);
      expect(result.code, 'telemetry.submitted');
      expect(transport.getters, 1);
      final request = transport.requests.single;
      expect(request.uri.toString(), '$_origin/v1/analytics/events');
      expect(request.method, 'POST');
      expect(request.contentType, 'application/json');
      expect(jsonDecode(utf8.decode(request.body)), {
        'name': 'Product.action-1',
        'fields': {
          'screen': 'Settings screen',
          'action': -3,
          'category': 1.25,
          'value': false,
          'success': true,
        },
      });
      expect(request.body.length, lessThanOrEqualTo(2048));
    },
  );

  test(
    'handled issue enum values serialize only issue code and context',
    () async {
      final transport = _Transport();
      for (final issue in HandledIssue.values) {
        final result = await _crash(transport).submit(
          HandledReport(
            issue: issue,
            code: 'parse.failed',
            context: const {
              'operation': 'decode',
              'screen': 'settings',
              'component': 'reader',
              'stage': 'validation',
            },
          ),
        );
        expect(result.code, 'telemetry.submitted');
        final request = transport.requests.last;
        expect(request.uri.toString(), '$_origin/v1/crash/handled');
        expect(request.method, 'POST');
        expect(request.contentType, 'application/json');
        expect(jsonDecode(utf8.decode(request.body)), {
          'issue': issue.name,
          'code': 'parse.failed',
          'context': {
            'operation': 'decode',
            'screen': 'settings',
            'component': 'reader',
            'stage': 'validation',
          },
        });
        expect(request.body.length, lessThanOrEqualTo(1024));
      }
      expect(transport.getters, HandledIssue.values.length);
      expect(transport.requests, hasLength(HandledIssue.values.length));
    },
  );

  test('analytics names use the exact safe ASCII byte boundary', () async {
    final transport = _Transport();
    expect(
      (await _analytics(transport).submit(AnalyticsEvent(name: 'a' * 64))).code,
      'telemetry.submitted',
    );
    for (final name in [
      '',
      'a' * 65,
      'raw prose',
      'é',
      'event\n',
      'event\u0000',
      'event\u0085',
      'user@example.test',
    ]) {
      final result = await _analytics(transport)
          .submit(AnalyticsEvent(name: name));
      expect(result.kind, TelemetrySubmitKind.invalid);
      expect(result.code, 'telemetry.invalid_payload');
    }
    expect(transport.getters, 1);
    expect(transport.requests, hasLength(1));
  });

  test('analytics text has strict Unicode and 128 UTF8 byte bounds', () async {
    final transport = _Transport();
    for (final text in [
      '',
      'a' * 128,
      'é' * 64,
      '😀' * 32,
      'ordinary spaces',
    ]) {
      final result = await _analytics(transport).submit(
        AnalyticsEvent(
          name: 'view',
          fields: {AnalyticsField.screen: AnalyticsFieldValue.text(text)},
        ),
      );
      expect(result.code, 'telemetry.submitted');
      expect(
        (jsonDecode(utf8.decode(transport.requests.last.body))
            as Map)['fields'],
        {'screen': text},
      );
    }
    final prior = transport.getters;
    for (final text in [
      'a' * 129,
      'é' * 65,
      '😀' * 33,
      '\u0000',
      '\n',
      '\u001f',
      '\u007f',
      '\u0080',
      '\u009f',
      '\ud800',
      '\udc00',
    ]) {
      final result = await _analytics(transport).submit(
        AnalyticsEvent(
          name: 'view',
          fields: {AnalyticsField.screen: AnalyticsFieldValue.text(text)},
        ),
      );
      expect(result.code, 'telemetry.invalid_payload');
    }
    expect(transport.getters, prior);
    expect(transport.requests, hasLength(prior));
  });

  test(
    'integer min max and finite decimals retain their JSON scalar types',
    () async {
      final transport = _Transport();
      for (final value in [
        int.parse('-9223372036854775808'),
        -1,
        0,
        int.parse('9223372036854775807'),
      ]) {
        expect(
          (await _analytics(transport).submit(
            AnalyticsEvent(
              name: 'count',
              fields: {
                AnalyticsField.value: AnalyticsFieldValue.integer(value),
              },
            ),
          )).code,
          'telemetry.submitted',
        );
        final decoded =
            jsonDecode(utf8.decode(transport.requests.last.body)) as Map;
        expect(decoded['fields']['value'], value);
        expect(decoded['fields']['value'], isA<int>());
      }
      for (final value in [-1.5, 0.0, -0.0, 1.7976931348623157e308]) {
        expect(
          (await _analytics(transport).submit(
            AnalyticsEvent(
              name: 'value',
              fields: {
                AnalyticsField.value: AnalyticsFieldValue.decimal(value),
              },
            ),
          )).code,
          'telemetry.submitted',
        );
      }
      final prior = transport.getters;
      for (final value in [
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        expect(
          (await _analytics(transport).submit(
            AnalyticsEvent(
              name: 'value',
              fields: {
                AnalyticsField.value: AnalyticsFieldValue.decimal(value),
              },
            ),
          )).code,
          'telemetry.invalid_payload',
        );
      }
      expect(transport.getters, prior);
      expect(transport.requests, hasLength(prior));
    },
  );

  test(
    'all five typed fields and escaped text stay under the defensive body cap',
    () async {
      final transport = _Transport();
      final result = await _analytics(transport).submit(
        AnalyticsEvent(
          name: 'a' * 64,
          fields: {
            for (final field in AnalyticsField.values)
              field: AnalyticsFieldValue.text('"' * 128),
          },
        ),
      );
      expect(result.code, 'telemetry.submitted');
      final decoded =
          jsonDecode(utf8.decode(transport.requests.single.body)) as Map;
      expect(decoded.keys, unorderedEquals(['name', 'fields']));
      expect(
        (decoded['fields'] as Map).keys,
        unorderedEquals(AnalyticsField.values.map((f) => f.name)),
      );
      expect(transport.requests.single.body.length, lessThanOrEqualTo(2048));
    },
  );

  test(
    'handled code48 and all four context64 boundaries are accepted',
    () async {
      final transport = _Transport();
      final result = await _crash(transport).submit(
        HandledReport(
          issue: HandledIssue.authentication,
          code: 'a' * 48,
          context: {
            for (final key in ['operation', 'screen', 'component', 'stage'])
              key: 'b' * 64,
          },
        ),
      );
      expect(result.code, 'telemetry.submitted');
      expect(transport.requests.single.body.length, lessThanOrEqualTo(1024));
    },
  );

  test(
    'invalid handled codes values or unknown keys reject without I/O',
    () async {
      final transport = _Transport();
      for (final code in [
        '',
        'a' * 49,
        'raw failure text',
        'é',
        'error\n',
        'error\u0085',
        'email@example.test',
      ]) {
        expect(
          (await _crash(transport)
                  .submit(HandledReport(issue: HandledIssue.other, code: code)))
              .code,
          'telemetry.invalid_payload',
        );
      }
      for (final context in <Map<String, String>>[
        {'unknown': 'safe'},
        {'stack': 'safe'},
        {'Operation': 'safe'},
        {'token': 'safe'},
        {'operation': ''},
        {'screen': 'a' * 65},
        {'component': 'raw prose'},
        {'stage': 'é'},
        {'stage': 'x\u0000'},
        {
          'operation': 'a',
          'screen': 'b',
          'component': 'c',
          'stage': 'd',
          'extra': 'e',
        },
      ]) {
        expect(
          (await _crash(transport).submit(
            HandledReport(
              issue: HandledIssue.other,
              code: 'safe',
              context: context,
            ),
          )).code,
          'telemetry.invalid_payload',
        );
      }
      expect(transport.getters, 0);
      expect(transport.requests, isEmpty);
    },
  );

  test('event report and allowed-host maps are immutable snapshots', () async {
    final fields = {
      AnalyticsField.screen: const AnalyticsFieldValue.text('before'),
    };
    final context = {'operation': 'before'};
    final hosts = {_host};
    final event = AnalyticsEvent(name: 'snapshot', fields: fields);
    final report = HandledReport(
      issue: HandledIssue.other,
      code: 'snapshot',
      context: context,
    );
    final transport = _Transport();
    final analytics = _analytics(transport, hosts: hosts);
    final crash = _crash(transport, hosts: hosts);
    fields.clear();
    context.clear();
    hosts.clear();
    expect(() => event.fields.clear(), throwsUnsupportedError);
    expect(() => report.context.clear(), throwsUnsupportedError);
    expect(
      () => analytics.allowedHosts.add('evil.invalid'),
      throwsUnsupportedError,
    );
    expect(() => crash.allowedHosts.clear(), throwsUnsupportedError);
    expect((await analytics.submit(event)).code, 'telemetry.submitted');
    expect(
      (jsonDecode(utf8.decode(transport.requests.last.body)) as Map)['fields'],
      {'screen': 'before'},
    );
    expect((await crash.submit(report)).code, 'telemetry.submitted');
    expect(
      (jsonDecode(utf8.decode(transport.requests.last.body)) as Map)['context'],
      {'operation': 'before'},
    );
  });

  test('request and response bytes and URI detach from mutable inputs', () {
    final bytes = [1, 2, 3];
    final uri = _RawUri('$_origin/v1');
    final request = TelemetryRequest(uri: uri, body: bytes);
    final response = TelemetryResponse(statusCode: 200, body: bytes);
    bytes[0] = 255;
    bytes.clear();
    uri.raw = 'https://evil.invalid/';
    expect(request.uri.toString(), '$_origin/v1');
    expect(request.body, [1, 2, 3]);
    expect(response.body, [1, 2, 3]);
    expect(() => request.body[0] = 0, throwsUnsupportedError);
    expect(() => response.body.add(0), throwsUnsupportedError);
  });

  test(
    'snapshots survive changes while transport response is pending',
    () async {
      final pending = Completer<TelemetryResponse>();
      final transport = _Transport()..action = (_) => pending.future;
      final uri = _RawUri('$_origin/v1');
      transport.base = uri;
      final fields = {
        AnalyticsField.action: const AnalyticsFieldValue.text('before'),
      };
      final hosts = {_host};
      final analytics = _analytics(transport, hosts: hosts);
      final result = analytics.submit(
        AnalyticsEvent(name: 'pending', fields: fields),
      );
      fields[AnalyticsField.action] = const AnalyticsFieldValue.text('after');
      hosts.clear();
      uri.raw = 'https://evil.invalid/';
      final bytes = [0xff, 0x00];
      final response = TelemetryResponse(statusCode: 202, body: bytes);
      pending.complete(response);
      bytes.clear();
      expect((await result).code, 'telemetry.submitted');
      expect(
        transport.requests.single.uri.toString(),
        '$_origin/v1/analytics/events',
      );
      expect(
        (jsonDecode(utf8.decode(transport.requests.single.body))
            as Map)['fields'],
        {'action': 'before'},
      );
      expect(transport.getters, 1);
    },
  );

  test(
    'missing invalid wildcard uppercase or excessive host lists are rejected',
    () async {
      for (final hosts in <Set<String>>[
        {},
        {'*'},
        {_host, 'UPPER.example.test'},
        {_host, 'with space'},
        {_host, '-first.example.test'},
        {_host, 'last-.example.test'},
        {_host, 'double..example.test'},
        {_host, 'example.test.'},
        {_host, 'https://example.test'},
        {_host, 'example.test:443'},
        {_host, 'é.example.test'},
        {_host, 'encoded%2eexample.test'},
        {_host, '${'a' * 64}.example.test'},
        {_host, 'a' * 254},
        {for (var i = 0; i < 17; i++) 'host$i.example.test'},
      ]) {
        final transport = _Transport();
        for (final result in [
          await _analytics(transport, hosts: hosts).submit(_event()),
          await _crash(transport, hosts: hosts).submit(_report()),
        ]) {
          expect(result.code, 'telemetry.invalid_configuration');
        }
        expect(transport.getters, 0);
        expect(transport.requests, isEmpty);
      }
    },
  );

  test(
    'host253 and explicit list16 boundaries work without origin expansion',
    () async {
      final host = '${'a' * 63}.${'b' * 63}.${'c' * 63}.${'d' * 61}';
      expect(host.length, 253);
      final transport = _Transport()..base = _RawUri('https://$host/base');
      final hosts = {host, for (var i = 0; i < 15; i++) 'host$i.example.test'};
      expect(hosts.length, 16);
      expect(
        (await _analytics(transport, hosts: hosts).submit(_event())).code,
        'telemetry.submitted',
      );
      expect(transport.requests.single.uri.host, host);
    },
  );

  test(
    'relative paths reject override encoding whitespace and dot segments',
    () async {
      for (final endpoint in [
        '',
        '/absolute',
        '//evil.invalid',
        'https://evil.invalid/path',
        '.',
        '..',
        'a/./b',
        'a/../b',
        'a//b',
        'a/',
        'a?token=x',
        'a?',
        'a#',
        'a%2fb',
        '%2e%2e/x',
        'a\\b',
        'a b',
        'a\n',
        'é',
        'a' * 2049,
      ]) {
        final transport = _Transport();
        for (final result in [
          await _analytics(transport, endpoint: endpoint).submit(_event()),
          await _crash(transport, endpoint: endpoint).submit(_report()),
        ]) {
          expect(
            result.code,
            'telemetry.invalid_configuration',
            reason: endpoint,
          );
        }
        expect(transport.getters, 0);
        expect(transport.requests, isEmpty);
      }
    },
  );

  test(
    'base URI serialization rejects forged unsafe and noncanonical forms',
    () async {
      for (final raw in [
        'http://$_host/v1',
        'HTTPS://$_host/v1',
        'https://METRICS.example.test/v1',
        'https://user:password@$_host/v1',
        'https://$_host/v1?',
        'https://$_host/v1#',
        'https://$_host/v1?token=private',
        'https://$_host/v1#private',
        'https://$_host./v1',
        'https://evil.invalid/v1',
        'https://$_host.evil.invalid/v1',
        'https://%6detrics.example.test/v1',
        'https://$_host:0/v1',
        'https://$_host:65536/v1',
        'https://$_host:%34%34%33/v1',
        'https://$_host/v1/../escape',
        'https://$_host/%2e%2e/escape',
        'https://$_host/v%31',
        'https://$_host/v1\\escape',
        'https://$_host//v1',
        'https://$_host/v1//',
        'https://$_host/v1 ',
        'https://$_host/v1\n',
        'https://$_host/é',
        'https://[::1]/v1',
        '//$_host/v1',
      ]) {
        final transport = _Transport()..base = _RawUri(raw);
        for (final result in [
          await _analytics(transport).submit(_event()),
          await _crash(transport).submit(_report()),
        ]) {
          expect(result.code, 'telemetry.invalid_configuration', reason: raw);
        }
        expect(transport.getters, 2);
        expect(transport.requests, isEmpty);
      }
    },
  );

  test('real Uri empty query and fragment delimiters are rejected', () async {
    for (final raw in ['$_origin/v1?', '$_origin/v1#']) {
      final transport = _Transport()..base = Uri.parse(raw);
      expect(
        (await _analytics(transport).submit(_event())).code,
        'telemetry.invalid_configuration',
      );
      expect(transport.requests, isEmpty);
    }
  });

  test(
    'safe base paths join beneath origin with optional slash and valid ports',
    () async {
      for (final (raw, expected) in [
        (_origin, '$_origin/analytics/events'),
        ('$_origin/', '$_origin/analytics/events'),
        ('$_origin/v1', '$_origin/v1/analytics/events'),
        ('$_origin/v1/', '$_origin/v1/analytics/events'),
        ('$_origin/V1/a-._~/', '$_origin/V1/a-._~/analytics/events'),
        ('$_origin:1/base', '$_origin:1/base/analytics/events'),
        ('$_origin:65535/base/', '$_origin:65535/base/analytics/events'),
      ]) {
        final transport = _Transport()..base = Uri.parse(raw);
        expect(
          (await _analytics(transport).submit(_event())).code,
          'telemetry.submitted',
        );
        expect(transport.requests.single.uri.toString(), expected);
        expect(transport.requests.single.uri.scheme, 'https');
        expect(transport.requests.single.uri.host, _host);
        expect(transport.getters, 1);
      }
    },
  );

  test(
    'final URI exact2048 limit succeeds and overflow never executes',
    () async {
      final exact = 'a' * (2048 - _origin.length - 1);
      final transport = _Transport()..base = Uri.parse(_origin);
      expect(
        (await _analytics(transport, endpoint: exact).submit(_event())).code,
        'telemetry.submitted',
      );
      expect(transport.requests.single.uri.toString().length, 2048);
      expect(
        (await _analytics(transport, endpoint: '${exact}a').submit(_event()))
            .code,
        'telemetry.invalid_configuration',
      );
      expect(transport.requests, hasLength(1));
      expect(transport.getters, 2);
    },
  );

  test('endpoint getter failure is fixed and never executes', () async {
    final transport = _Transport()
      ..getterError = StateError('private endpoint credentials');
    for (final result in [
      await _analytics(transport).submit(_event()),
      await _crash(transport).submit(_report()),
    ]) {
      expect(result.kind, TelemetrySubmitKind.failure);
      expect(result.code, 'telemetry.transport_failed');
      expect(result.toString(), isNot(contains('private')));
    }
    expect(transport.getters, 2);
    expect(transport.requests, isEmpty);
  });

  test(
    'sync async and response-factory execute failures are fixed without retry',
    () async {
      for (final action
          in <Future<TelemetryResponse> Function(TelemetryRequest)>[
            (_) => throw StateError('private transport password'),
            (_) async => throw StateError('private transport password'),
            (_) async =>
                TelemetryResponse(statusCode: 200, body: _ThrowingBytes()),
          ]) {
        final transport = _Transport()..action = action;
        for (final result in [
          await _analytics(transport).submit(_event()),
          await _crash(transport).submit(_report()),
        ]) {
          expect(result.kind, TelemetrySubmitKind.failure);
          expect(result.code, 'telemetry.transport_failed');
          expect(result.toString(), isNot(contains('private')));
        }
        expect(transport.getters, 2);
        expect(transport.requests, hasLength(2));
      }
    },
  );

  test(
    '2xx means submitted and other valid HTTP statuses fail without retry',
    () async {
      for (final status in [
        100,
        199,
        200,
        202,
        204,
        299,
        300,
        401,
        429,
        500,
        599,
      ]) {
        final transport = _Transport()
          ..response = TelemetryResponse(statusCode: status, body: []);
        for (final result in [
          await _analytics(transport).submit(_event()),
          await _crash(transport).submit(_report()),
        ]) {
          final accepted = status >= 200 && status < 300;
          expect(
            result.kind,
            accepted
                ? TelemetrySubmitKind.submitted
                : TelemetrySubmitKind.failure,
          );
          expect(
            result.code,
            accepted ? 'telemetry.submitted' : 'telemetry.transport_failed',
          );
        }
        expect(transport.getters, 2);
        expect(transport.requests, hasLength(2));
      }
    },
  );

  test(
    'invalid typed status and nonbyte response units are fixed failures',
    () async {
      for (final response in [
        for (final status in [-1, 0, 99, 600, 1000])
          TelemetryResponse(statusCode: status, body: []),
        TelemetryResponse(statusCode: 200, body: [-1]),
        TelemetryResponse(statusCode: 200, body: [256]),
      ]) {
        final transport = _Transport()..response = response;
        for (final result in [
          await _analytics(transport).submit(_event()),
          await _crash(transport).submit(_report()),
        ]) {
          expect(result.kind, TelemetrySubmitKind.failure);
          expect(result.code, 'telemetry.invalid_response');
        }
        expect(transport.requests, hasLength(2));
      }
    },
  );

  test(
    'response65536 limit accepts opaque bytes without JSON or UTF8 parsing',
    () async {
      final transport = _Transport()
        ..response = TelemetryResponse(
          statusCode: 202,
          body: List.filled(65536, 0xff),
        );
      for (final result in [
        await _analytics(transport).submit(_event()),
        await _crash(transport).submit(_report()),
      ]) {
        expect(result.code, 'telemetry.submitted');
      }
      transport.response = TelemetryResponse(
        statusCode: 200,
        body: List.filled(65537, 0),
      );
      for (final result in [
        await _analytics(transport).submit(_event()),
        await _crash(transport).submit(_report()),
      ]) {
        expect(result.kind, TelemetrySubmitKind.failure);
        expect(result.code, 'telemetry.response_too_large');
      }
      expect(transport.getters, 4);
      expect(transport.requests, hasLength(4));
    },
  );

  test(
    'separate immutable consent instances have no implicit revocation or queue',
    () async {
      final pending = Completer<TelemetryResponse>();
      final transport = _Transport()..action = (_) => pending.future;
      final granted = _analytics(transport);
      final sent = granted.submit(_event());
      final denied = StarterAnalyticsService(
        enabled: true,
        transport: transport,
        allowedHosts: {_host},
      );
      expect((await denied.submit(_event())).code, 'telemetry.consent_denied');
      expect(granted.consent, AnalyticsConsent.granted);
      expect(denied.consent, AnalyticsConsent.denied);
      expect(transport.getters, 1);
      expect(transport.requests, hasLength(1));
      pending.complete(TelemetryResponse(statusCode: 202, body: []));
      expect((await sent).code, 'telemetry.submitted');
      transport.action = null;
      final crashGranted = _crash(transport);
      final crashDenied = StarterCrashReportingService(
        enabled: true,
        transport: transport,
        allowedHosts: {_host},
      );
      expect(
        (await crashDenied.submit(_report())).code,
        'telemetry.consent_denied',
      );
      expect(
        (await crashGranted.submit(_report())).code,
        'telemetry.submitted',
      );
      expect(crashGranted.consent, CrashConsent.granted);
      expect(crashDenied.consent, CrashConsent.denied);
      expect(transport.requests, hasLength(2));
    },
  );
}

StarterAnalyticsService _analytics(
  _Transport transport, {
  String endpoint = 'analytics/events',
  Set<String> hosts = const {_host},
}) => StarterAnalyticsService(
  enabled: true,
  consent: AnalyticsConsent.granted,
  transport: transport,
  endpoint: endpoint,
  allowedHosts: hosts,
);

StarterCrashReportingService _crash(
  _Transport transport, {
  String endpoint = 'crash/handled',
  Set<String> hosts = const {_host},
}) => StarterCrashReportingService(
  enabled: true,
  consent: CrashConsent.granted,
  transport: transport,
  endpoint: endpoint,
  allowedHosts: hosts,
);

final class _Transport implements TelemetryTransport {
  Uri base = Uri.parse('$_origin/v1/');
  int getters = 0;
  Object? getterError;
  final requests = <TelemetryRequest>[];
  TelemetryResponse response = TelemetryResponse(statusCode: 200, body: []);
  Future<TelemetryResponse> Function(TelemetryRequest)? action;

  @override
  Uri get baseEndpoint {
    getters++;
    if (getterError != null) throw getterError!;
    return base;
  }

  @override
  Future<TelemetryResponse> execute(TelemetryRequest request) {
    requests.add(request);
    return action?.call(request) ?? Future.value(response);
  }
}

/// Preserve raw supplied serialization to test forms Uri.parse would normalize.
final class _RawUri implements Uri {
  _RawUri(this.raw);

  String raw;

  @override
  String toString() => raw;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ThrowingBytes extends ListBase<int> {
  @override
  int get length => 1;

  @override
  set length(int value) => throw UnsupportedError('test-only');

  @override
  int operator [](int index) => throw StateError('private response bytes');

  @override
  void operator []=(int index, int value) =>
      throw UnsupportedError('test-only');
}
