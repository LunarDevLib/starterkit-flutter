import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_starterkit/core/connectivity/connectivity_monitor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = EventChannel('starterkit/connectivity/events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  var nativeListenCalls = 0;

  setUp(() {
    nativeListenCalls = 0;
    messenger.setMockStreamHandler(
      channel,
      MockStreamHandler.inline(onListen: (_, __) => nativeListenCalls++),
    );
  });

  tearDown(() => messenger.setMockStreamHandler(channel, null));

  test(
    'disabled/unready monitor emits unknown and makes zero channel calls',
    () async {
      final monitor = ConnectivityMonitor(
        source: StarterkitConnectivitySource(),
        nativeConfigured: false,
        isReady: () => true,
      );
      expect(monitor.snapshot.state, ConnectivityState.unknown);
      monitor.start();
      monitor.start();
      expect(nativeListenCalls, 0);
      expect(monitor.snapshot.state, ConnectivityState.unknown);
      expect(monitor.snapshot.failure, isNotNull);
      await monitor.dispose();
      expect(nativeListenCalls, 0);
    },
  );

  test(
    'explicit activation starts once and cancels, fencing stale events',
    () async {
      final source = _FakeConnectivitySource();
      final snapshots = <ConnectivitySnapshot>[];
      final monitor = ConnectivityMonitor(
        source: source,
        nativeConfigured: true,
        isReady: () => true,
        onChanged: snapshots.add,
      );
      expect(source.eventsCalls, 0);
      monitor.start();
      monitor.start();
      expect(source.eventsCalls, 1);
      source.controller.add(ConnectivityState.onlineLike);
      await Future<void>.delayed(Duration.zero);
      expect(monitor.snapshot.state, ConnectivityState.onlineLike);

      await monitor.stop();
      expect(source.cancelled, 1);
      final countAtStop = snapshots.length;
      source.controller.add(ConnectivityState.offline);
      await Future<void>.delayed(Duration.zero);
      expect(snapshots.length, countAtStop);
      expect(monitor.snapshot.state, ConnectivityState.unknown);

      monitor.start();
      source.controller.addError(StateError('private diagnostic'));
      await Future<void>.delayed(Duration.zero);
      expect(monitor.snapshot.state, ConnectivityState.unknown);
      expect(monitor.snapshot.failure, isNotNull);
      expect(
        monitor.snapshot.failure.toString(),
        isNot(contains('private diagnostic')),
      );
      await monitor.dispose();
      final finalCount = snapshots.length;
      source.controller.add(ConnectivityState.onlineLike);
      await Future<void>.delayed(Duration.zero);
      expect(snapshots.length, finalCount);
      await source.controller.close();
    },
  );

  test(
    'dispose fences synchronously while cancellation is still pending',
    () async {
      final source = _DelayedConnectivitySource();
      final snapshots = <ConnectivitySnapshot>[];
      final monitor = ConnectivityMonitor(
        source: source,
        nativeConfigured: true,
        isReady: () => true,
        onChanged: snapshots.add,
      );
      monitor.start();
      source.streams.single.emit(ConnectivityState.onlineLike);

      final disposal = monitor.dispose();
      expect(monitor.isDisposed, isTrue);
      expect(monitor.snapshot.state, ConnectivityState.unknown);
      monitor.start();
      expect(source.eventsCalls, 1);
      expect(source.streams.single.cancelRequested, isTrue);

      source.streams.single.finishCancellation();
      await disposal;
      source.streams.single.emit(ConnectivityState.offline);
      expect(source.eventsCalls, 1);
      expect(snapshots.map((snapshot) => snapshot.state), [
        ConnectivityState.onlineLike,
      ]);
    },
  );

  test('stop completion cannot replace a snapshot after restart', () async {
    final source = _DelayedConnectivitySource();
    final monitor = ConnectivityMonitor(
      source: source,
      nativeConfigured: true,
      isReady: () => true,
    );
    monitor.start();
    final oldStream = source.streams.single;
    oldStream.emit(ConnectivityState.onlineLike);
    expect(monitor.snapshot.state, ConnectivityState.onlineLike);

    final stopping = monitor.stop();
    expect(oldStream.cancelRequested, isTrue);
    monitor.start();
    expect(source.eventsCalls, 2);
    final newStream = source.streams.last;
    newStream.emit(ConnectivityState.offline);
    expect(monitor.snapshot.state, ConnectivityState.offline);

    oldStream.finishCancellation();
    await stopping;
    expect(monitor.snapshot.state, ConnectivityState.offline);

    final disposal = monitor.dispose();
    newStream.finishCancellation();
    await disposal;
  });
}

final class _FakeConnectivitySource implements ConnectivityEventSource {
  late final StreamController<ConnectivityState> controller =
      StreamController<ConnectivityState>.broadcast(
        onCancel: () => cancelled++,
      );
  int eventsCalls = 0;
  int cancelled = 0;

  @override
  Stream<ConnectivityState> events() {
    eventsCalls++;
    return controller.stream;
  }
}

final class _DelayedConnectivitySource implements ConnectivityEventSource {
  final List<_DelayedConnectivityStream> streams =
      <_DelayedConnectivityStream>[];

  int get eventsCalls => streams.length;

  @override
  Stream<ConnectivityState> events() {
    final stream = _DelayedConnectivityStream();
    streams.add(stream);
    return stream;
  }
}

final class _DelayedConnectivityStream extends Stream<ConnectivityState> {
  final StreamController<ConnectivityState> _controller =
      StreamController<ConnectivityState>.broadcast(sync: true);
  final Completer<void> _cancellationGate = Completer<void>();
  bool cancelRequested = false;

  void emit(ConnectivityState state) => _controller.add(state);

  void finishCancellation() {
    if (!_cancellationGate.isCompleted) _cancellationGate.complete();
  }

  @override
  StreamSubscription<ConnectivityState> listen(
    void Function(ConnectivityState event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _DelayedCancellationSubscription(
    _controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    ),
    this,
    _cancellationGate.future,
  );
}

final class _DelayedCancellationSubscription<T>
    implements StreamSubscription<T> {
  _DelayedCancellationSubscription(this._inner, this._source, this._gate);

  final StreamSubscription<T> _inner;
  final _DelayedConnectivityStream _source;
  final Future<void> _gate;

  @override
  Future<void> cancel() async {
    _source.cancelRequested = true;
    await _inner.cancel();
    await _gate;
  }

  @override
  Future<E> asFuture<E>([E? futureValue]) => _inner.asFuture<E>(futureValue);

  @override
  bool get isPaused => _inner.isPaused;

  @override
  void onData(void Function(T event)? handleData) => _inner.onData(handleData);

  @override
  void onDone(void Function()? handleDone) => _inner.onDone(handleDone);

  @override
  void onError(Function? handleError) => _inner.onError(handleError);

  @override
  void pause([Future<void>? resumeSignal]) => _inner.pause(resumeSignal);

  @override
  void resume() => _inner.resume();
}
