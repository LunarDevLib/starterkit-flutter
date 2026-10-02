import 'dart:typed_data';

import 'package:flutter_starterkit/core/failure/app_failure.dart';
import 'package:flutter_starterkit/core/session/session_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Credential and SessionState', () {
    test(
      'Credential defensively copies bounded bytes and redacts string form',
      () {
        final source = Uint8List.fromList([11, 22, 33]);
        final credential = Credential(source);
        source[0] = 0;
        final copy = credential.copyBytes();
        copy[1] = 0;
        expect(credential.copyBytes(), [11, 22, 33]);
        expect(credential.toString(), isNot(contains('11')));
        expect(credential.toString(), contains('REDACTED'));
        expect(() => Credential(Uint8List(0)), throwsArgumentError);
        expect(
          () => Credential(Uint8List(Credential.maxBytes + 1)),
          throwsArgumentError,
        );
      },
    );

    test(
      'session values are observable but signed-in state carries no secret',
      () {
        const SessionState unknown = SessionUnknown();
        const SessionState signedOut = SessionSignedOut();
        const SessionState signedIn = SessionSignedIn();
        final failure = SessionFailure(
          AppFailure(
            FailureKind.unavailable,
            code: 'service.unavailable',
            localizationKey: 'failure.unavailable',
          ),
        );
        expect(unknown, isA<SessionUnknown>());
        expect(signedOut, isA<SessionSignedOut>());
        expect(signedIn, isA<SessionSignedIn>());
        expect(failure.failure.kind, FailureKind.unavailable);
        expect(signedIn.toString(), isNot(contains('Credential')));
      },
    );
  });
}
