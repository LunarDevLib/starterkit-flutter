import 'package:flutter/widgets.dart';

enum LifecycleStatus { unknown, foreground, background, inactive, detached }

/// Platform lifecycle event source. [start] and [stop] must be explicitly used.
abstract interface class LifecycleEventSource {
  void start(void Function(LifecycleStatus status) onStatus);
  void stop();
}

/// Opt-in lifecycle observer. Construction does not touch WidgetsBinding.
final class LifecycleMonitor {
  LifecycleMonitor({LifecycleEventSource? source, this.onChanged})
    : _injectedSource = source;

  final LifecycleEventSource? _injectedSource;
  final void Function(LifecycleStatus status)? onChanged;
  LifecycleEventSource? _source;
  LifecycleStatus _status = LifecycleStatus.unknown;
  bool _started = false;
  bool _disposed = false;
  int _generation = 0;

  LifecycleStatus get status => _status;
  bool get isDisposed => _disposed;

  void start() {
    if (_started || _disposed) return;
    _started = true;
    final generation = ++_generation;
    final source = _source ??=
        _injectedSource ?? _WidgetsLifecycleEventSource();
    source.start((status) {
      if (!_started || _disposed || generation != _generation) return;
      _status = status;
      onChanged?.call(status);
    });
  }

  void stop() {
    if (!_started) return;
    _started = false;
    _generation++;
    _source?.stop();
  }

  void dispose() {
    if (_disposed) return;
    stop();
    _disposed = true;
    _generation++;
  }
}

/// Deterministic mapping for Flutter's lifecycle enum.
LifecycleStatus lifecycleStatusFor(AppLifecycleState state) => switch (state) {
  AppLifecycleState.resumed => LifecycleStatus.foreground,
  AppLifecycleState.paused ||
  AppLifecycleState.hidden => LifecycleStatus.background,
  AppLifecycleState.inactive => LifecycleStatus.inactive,
  AppLifecycleState.detached => LifecycleStatus.detached,
};

final class _WidgetsLifecycleEventSource extends WidgetsBindingObserver
    implements LifecycleEventSource {
  void Function(LifecycleStatus status)? _onStatus;
  bool _active = false;

  @override
  void start(void Function(LifecycleStatus status) onStatus) {
    if (_active) return;
    _active = true;
    _onStatus = onStatus;
    final binding = WidgetsBinding.instance;
    binding.addObserver(this);
    final current = binding.lifecycleState;
    if (current != null) onStatus(lifecycleStatusFor(current));
  }

  @override
  void stop() {
    if (!_active) return;
    _active = false;
    _onStatus = null;
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_active) _onStatus?.call(lifecycleStatusFor(state));
  }
}
