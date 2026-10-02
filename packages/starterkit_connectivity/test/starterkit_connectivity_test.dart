import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:starterkit_connectivity/starterkit_connectivity.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = EventChannel('starterkit/connectivity/events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final listenCalls = <String>[];
  late MockStreamHandlerEventSink eventSink;

  setUp(() {
    listenCalls.clear();
    messenger.setMockStreamHandler(
      channel,
      MockStreamHandler.inline(
        onListen: (_, sink) {
          listenCalls.add('listen');
          eventSink = sink;
        },
        onCancel: (_) => listenCalls.add('cancel'),
      ),
    );
  });

  tearDown(() {
    messenger.setMockStreamHandler(channel, null);
  });

  test(
    'construction is inert; subscribing explicitly starts and cancels stream',
    () async {
      final connectivity = StarterkitConnectivity();
      expect(listenCalls, isEmpty);

      final subscription = connectivity.events().listen((_) {});
      await Future<void>.delayed(Duration.zero);
      expect(listenCalls, ['listen']);

      await subscription.cancel();
      expect(listenCalls, ['listen', 'cancel']);
    },
  );

  test(
    'decodes fixed statuses and maps unknown or malformed values to unknown',
    () async {
      final statuses = <ConnectivityStatus>[];
      final subscription = StarterkitConnectivity().events().listen(
        statuses.add,
      );
      await Future<void>.delayed(Duration.zero);
      eventSink.success('unknown');
      eventSink.success('offline');
      eventSink.success('onlineLike');
      eventSink.success('unexpected');
      await Future<void>.delayed(Duration.zero);
      expect(statuses, [
        ConnectivityStatus.unknown,
        ConnectivityStatus.offline,
        ConnectivityStatus.onlineLike,
        ConnectivityStatus.unknown,
      ]);
      await subscription.cancel();
    },
  );

  test('preserves platform stream errors', () async {
    Object? receivedError;
    final subscription = StarterkitConnectivity().events().listen(
      (_) {},
      onError: (Object error) => receivedError = error,
    );
    await Future<void>.delayed(Duration.zero);
    eventSink.error(code: 'native_failure');
    await Future<void>.delayed(Duration.zero);
    expect(receivedError, isA<PlatformException>());
    expect((receivedError! as PlatformException).code, 'native_failure');
    await subscription.cancel();
  });
}
