import 'package:flutter/services.dart';

/// Coarse status of the device's network interface, not verified reachability.
enum ConnectivityStatus { unknown, offline, onlineLike }

/// A low-level, explicitly subscribed stream of native interface status.
///
/// Constructing this object does not contact the platform or start monitoring.
/// Native monitoring begins when a listener subscribes to [events] and stops
/// when its last listener cancels.
class StarterkitConnectivity {
  StarterkitConnectivity({
    this.channel = const EventChannel('starterkit/connectivity/events'),
  });

  final EventChannel channel;
  late final Stream<ConnectivityStatus> _events = channel
      .receiveBroadcastStream()
      .map(_decodeStatus);

  /// Emits [ConnectivityStatus] values while explicitly subscribed.
  ///
  /// Unrecognized platform values are treated as [ConnectivityStatus.unknown].
  Stream<ConnectivityStatus> events() => _events;

  static ConnectivityStatus _decodeStatus(Object? value) => switch (value) {
    'unknown' => ConnectivityStatus.unknown,
    'offline' => ConnectivityStatus.offline,
    'onlineLike' => ConnectivityStatus.onlineLike,
    _ => ConnectivityStatus.unknown,
  };
}
