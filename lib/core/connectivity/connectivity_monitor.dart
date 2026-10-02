import 'dart:async';

import 'package:starterkit_connectivity/starterkit_connectivity.dart';

import '../failure/app_failure.dart';

enum ConnectivityState { unknown, offline, onlineLike }

final class ConnectivitySnapshot {
  const ConnectivitySnapshot({required this.state, this.failure});

  final ConnectivityState state;
  final AppFailure? failure;
}

abstract interface class ConnectivityEventSource {
  Stream<ConnectivityState> events();
}

/// Bridges the optional native plugin into the app-owned state vocabulary.
final class StarterkitConnectivitySource implements ConnectivityEventSource {
  StarterkitConnectivitySource({StarterkitConnectivity? connectivity})
    : _connectivity = connectivity ?? StarterkitConnectivity();

  final StarterkitConnectivity _connectivity;

  @override
  Stream<ConnectivityState> events() => _connectivity.events().map(
    (status) => switch (status) {
      ConnectivityStatus.unknown => ConnectivityState.unknown,
      ConnectivityStatus.offline => ConnectivityState.offline,
      ConnectivityStatus.onlineLike => ConnectivityState.onlineLike,
    },
  );
}

/// An explicitly activated, lifecycle-owned native status subscription.
///
/// [nativeConfigured] represents the application's deliberate platform
/// configuration; [isReady] is an additional runtime readiness gate. Both
/// must be true before [start] touches the event source.
final class ConnectivityMonitor {
  ConnectivityMonitor({
    required this.source,
    required this.nativeConfigured,
    required this.isReady,
    this.onChanged,
  });

  final ConnectivityEventSource source;
  final bool nativeConfigured;
  final bool Function() isReady;
  final void Function(ConnectivitySnapshot snapshot)? onChanged;
  ConnectivitySnapshot _snapshot = const ConnectivitySnapshot(
    state: ConnectivityState.unknown,
  );
  StreamSubscription<ConnectivityState>? _subscription;
  final Set<Future<void>> _pendingCancellations = <Future<void>>{};
  int _generation = 0;
  bool _started = false;
  bool _disposed = false;

  ConnectivitySnapshot get snapshot => _snapshot;
  bool get isDisposed => _disposed;

  void start() {
    if (_started || _disposed) return;
    _started = true;
    final generation = ++_generation;
    bool ready;
    try {
      ready = nativeConfigured && isReady();
    } on Object {
      ready = false;
    }
    if (!ready) {
      _publish(
        ConnectivitySnapshot(
          state: ConnectivityState.unknown,
          failure: _configurationFailure,
        ),
      );
      return;
    }

    try {
      _subscription = source.events().listen(
        (state) {
          if (_isCurrent(generation)) {
            _publish(ConnectivitySnapshot(state: state));
          }
        },
        onError: (Object error) {
          if (_isCurrent(generation)) {
            _publish(
              ConnectivitySnapshot(
                state: ConnectivityState.unknown,
                failure: AppFailure.fromException(error),
              ),
            );
          }
        },
        onDone: () {
          if (_isCurrent(generation)) {
            _publish(
              ConnectivitySnapshot(
                state: ConnectivityState.unknown,
                failure: _configurationFailure,
              ),
            );
          }
        },
      );
    } on Object catch (error) {
      if (_isCurrent(generation)) {
        _publish(
          ConnectivitySnapshot(
            state: ConnectivityState.unknown,
            failure: AppFailure.fromException(error),
          ),
        );
      }
    }
  }

  Future<void> stop() async {
    if (!_started || _disposed) return;
    _started = false;
    final generation = ++_generation;
    final subscription = _subscription;
    _subscription = null;
    try {
      await _cancelSubscription(subscription);
    } on Object catch (error) {
      if (_canPublishStoppedState(generation)) {
        _publish(
          ConnectivitySnapshot(
            state: ConnectivityState.unknown,
            failure: AppFailure.fromException(error),
          ),
        );
      }
      return;
    }
    if (_canPublishStoppedState(generation)) {
      _publish(const ConnectivitySnapshot(state: ConnectivityState.unknown));
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _started = false;
    final generation = ++_generation;
    final subscription = _subscription;
    _subscription = null;

    // Disposed observers are silent; expose the stopped value synchronously.
    _snapshot = const ConnectivitySnapshot(state: ConnectivityState.unknown);
    final pending = <Future<void>>{..._pendingCancellations};
    if (subscription != null) {
      pending.add(_cancelSubscription(subscription));
    }
    for (final cancellation in pending) {
      try {
        await cancellation;
      } on Object catch (error) {
        if (_disposed && generation == _generation) {
          _snapshot = ConnectivitySnapshot(
            state: ConnectivityState.unknown,
            failure: AppFailure.fromException(error),
          );
        }
      }
    }
  }

  Future<void> _cancelSubscription(
    StreamSubscription<ConnectivityState>? subscription,
  ) {
    if (subscription == null) return Future<void>.value();
    late final Future<void> cancellation;
    cancellation = Future<void>.sync(subscription.cancel).whenComplete(() {
      _pendingCancellations.remove(cancellation);
    });
    _pendingCancellations.add(cancellation);
    return cancellation;
  }

  bool _canPublishStoppedState(int generation) =>
      generation == _generation && !_started && !_disposed;

  bool _isCurrent(int generation) =>
      _started && !_disposed && generation == _generation;

  void _publish(ConnectivitySnapshot snapshot) {
    _snapshot = snapshot;
    onChanged?.call(snapshot);
  }

  static final AppFailure _configurationFailure = AppFailure(
    FailureKind.unavailable,
    code: 'connectivity.unavailable',
    localizationKey: 'failure.connectivity_unavailable',
  );
}
