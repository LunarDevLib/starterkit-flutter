import '../failure/app_failure.dart';

typedef CancelListener = void Function();
typedef CancellationUnsubscribe = void Function();

final class CancellationSource {
  final Map<int, CancelListener> _listeners = <int, CancelListener>{};
  late final CancellationToken token = CancellationToken._(this);
  bool _isCancelled = false;
  int _nextListenerId = 0;

  bool get isCancelled => _isCancelled;

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    final listenerIds = List<int>.of(_listeners.keys);
    for (final id in listenerIds) {
      final listener = _listeners.remove(id);
      if (listener == null) continue;
      try {
        listener();
      } on Object {
        // One subscriber cannot prevent cancellation from reaching others.
      }
    }
  }

  CancellationUnsubscribe _listen(CancelListener listener) {
    if (_isCancelled) {
      try {
        listener();
      } on Object {
        // Late listeners observe cancellation immediately, but cannot undo it.
      }
      return () {};
    }
    final id = _nextListenerId++;
    _listeners[id] = listener;
    var active = true;
    return () {
      if (!active) return;
      active = false;
      _listeners.remove(id);
    };
  }
}

final class CancellationToken {
  CancellationToken._(this._source);

  final CancellationSource _source;

  bool get isCancelled => _source.isCancelled;

  void throwIfCancelled() {
    if (isCancelled) {
      throw AppFailure(
        FailureKind.cancelled,
        code: 'operation.cancelled',
        localizationKey: 'failure.cancelled',
      );
    }
  }

  CancellationUnsubscribe onCancel(CancelListener listener) =>
      _source._listen(listener);
}
