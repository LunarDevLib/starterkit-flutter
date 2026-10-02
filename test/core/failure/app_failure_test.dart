import 'dart:async';

import 'package:flutter_starterkit/core/failure/app_failure.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FailureKind and AppFailure', () {
    test('exposes exactly the contract failure taxonomy', () {
      expect(FailureKind.values.map((kind) => kind.name), [
        'validation',
        'unauthorized',
        'forbidden',
        'notFound',
        'conflict',
        'network',
        'timeout',
        'cancelled',
        'server',
        'unavailable',
        'unknown',
      ]);
    });

    test('validates short developer-authored public identifiers', () {
      expect(
        () => AppFailure(
          FailureKind.unknown,
          code: 'raw token value',
          localizationKey: 'failure.unknown',
        ),
        throwsArgumentError,
      );
      expect(
        () => AppFailure(
          FailureKind.unknown,
          code: 'x' * 65,
          localizationKey: 'failure.unknown',
        ),
        throwsArgumentError,
      );
    });

    test('maps HTTP outcomes to safe failures', () {
      expect(AppFailure.fromHttpStatus(204), isNull);
      expect(AppFailure.fromHttpStatus(401)?.kind, FailureKind.unauthorized);
      expect(AppFailure.fromHttpStatus(408)?.kind, FailureKind.timeout);
      expect(AppFailure.fromHttpStatus(429)?.kind, FailureKind.unavailable);
      expect(AppFailure.fromHttpStatus(302)?.kind, FailureKind.unavailable);
      expect(AppFailure.fromHttpStatus(503)?.kind, FailureKind.unavailable);
      expect(AppFailure.fromHttpStatus(500)?.kind, FailureKind.server);
      expect(AppFailure.fromHttpStatus(799)?.kind, FailureKind.unknown);
      expect(
        AppFailure.fromHttpStatus(404)?.localizationKey,
        'failure.resource.not_found',
      );
    });

    test('maps timeout and unknown exceptions without exposing their text', () {
      final timeout = AppFailure.fromException(
        TimeoutException('secret-token-value'),
      );
      final unknown = AppFailure.fromException(
        StateError('authorization: Bearer private'),
      );
      expect(timeout.kind, FailureKind.timeout);
      expect(unknown.kind, FailureKind.unknown);
      expect(timeout.toString(), isNot(contains('secret-token-value')));
      expect(unknown.toString(), isNot(contains('private')));
    });
  });
}
