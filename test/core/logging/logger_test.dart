import 'dart:convert';

import 'package:flutter_starterkit/core/logging/logger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SafeLogger', () {
    test(
      'keeps only bounded allowlisted fields and filters sensitive variants',
      () {
        LogLevel? level;
        String? event;
        Map<String, Object?>? fields;
        final logger = SafeLogger((gotLevel, gotEvent, gotFields) {
          level = gotLevel;
          event = gotEvent;
          fields = gotFields;
        });

        logger.warning(
          'request.failed',
          fields: {
            'status': 503,
            'duration-ms': 120,
            'access_token': 'not-to-log',
            'httpAuthorizationHeader': 'private',
            'sessionCookieValue': 'private',
            'api-key': 'private',
            'credentialHint': 'private',
            'payload': 'raw body',
            'reason': 'server_error',
          },
        );

        expect(level, LogLevel.warning);
        expect(event, 'request.failed');
        expect(fields, {
          'status': 503,
          'durationms': 120,
          'reason': 'server_error',
        });
        expect(fields.toString(), isNot(contains('private')));
      },
    );

    test(
      'drops normalized-key collisions and bounds nested depth and count',
      () {
        Map<String, Object?>? emitted;
        final logger = SafeLogger((_, __, fields) => emitted = fields);
        logger.info(
          'session.state',
          fields: {
            'failure-kind': 'network',
            'failure_kind': 'unknown',
            'reason': {
              'status': 'offline',
              'apiCredential': 'redacted',
              'operation': {
                'result': {'status': 'too-deep'},
              },
            },
            'result': List<Object?>.generate(40, (index) => index),
          },
        );
        expect(emitted!.containsKey('failurekind'), isFalse);
        final reason = emitted!['reason']! as Map<String, Object?>;
        expect(reason, {'status': 'offline'});
        expect((emitted!['result']! as List).length, lessThanOrEqualTo(16));
      },
    );

    test('rejects unsafe event text and does not throw if sink fails', () {
      var calls = 0;
      final logger = SafeLogger((_, __, ___) {
        calls++;
        throw StateError('private failure');
      });
      logger.error('https://secret.example/token');
      logger.error('operation.failed');
      expect(calls, 1);
    });

    test('serialized safe payload remains within the byte budget', () {
      Map<String, Object?>? emitted;
      final logger = SafeLogger((_, __, fields) => emitted = fields);
      logger.info(
        'config.loaded',
        fields: {
          'module': 'm' * 64,
          'operation': List<Object?>.filled(16, 'v' * 64),
          'reason': 'r' * 64,
          'result': 'ok',
          'feature': 'feature_name',
          'environment': 'development',
        },
      );
      expect(utf8.encode(jsonEncode(emitted)).length, lessThanOrEqualTo(4096));
    });
  });
}
