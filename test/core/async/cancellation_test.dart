import 'package:flutter_starterkit/core/async/cancellation.dart';
import 'package:flutter_starterkit/core/failure/app_failure.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CancellationSource and CancellationToken', () {
    test('cancels synchronously and is idempotent', () {
      final source = CancellationSource();
      var calls = 0;
      source.token.onCancel(() => calls++);
      source.cancel();
      source.cancel();
      expect(source.token.isCancelled, isTrue);
      expect(calls, 1);
      expect(source.token.throwIfCancelled, throwsA(isA<AppFailure>()));
    });

    test(
      'late listeners run immediately and can be unsubscribed harmlessly',
      () {
        final source = CancellationSource()..cancel();
        var calls = 0;
        final unsubscribe = source.token.onCancel(() => calls++);
        unsubscribe();
        unsubscribe();
        expect(calls, 1);
      },
    );

    test('unsubscribe before delivery, including during another callback', () {
      final source = CancellationSource();
      var removedCalls = 0;
      late void Function() unsubscribe;
      source.token.onCancel(() => unsubscribe());
      unsubscribe = source.token.onCancel(() => removedCalls++);
      source.cancel();
      expect(removedCalls, 0);
    });

    test('duplicate callback registrations have independent subscriptions', () {
      final source = CancellationSource();
      var calls = 0;
      void listener() => calls++;
      final first = source.token.onCancel(listener);
      source.token.onCancel(listener);
      first();
      source.cancel();
      expect(calls, 1);
    });
  });
}
