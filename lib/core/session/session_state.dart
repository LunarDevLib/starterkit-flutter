import 'dart:typed_data';

import '../failure/app_failure.dart';

/// A copied opaque credential. Access must be explicit at storage or
/// authorization boundaries; its value is never rendered by [toString].
final class Credential {
  factory Credential(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw ArgumentError('Credential must contain 1-65536 bytes.');
    }
    return Credential._(Uint8List.fromList(bytes));
  }

  Credential._(this._bytes);

  static const int maxBytes = 64 * 1024;
  final Uint8List _bytes;

  Uint8List copyBytes() => Uint8List.fromList(_bytes);

  @override
  String toString() => 'Credential([REDACTED])';
}

sealed class SessionState {
  const SessionState();
}

final class SessionUnknown extends SessionState {
  const SessionUnknown();
}

final class SessionSignedOut extends SessionState {
  const SessionSignedOut();
}

final class SessionSignedIn extends SessionState {
  const SessionSignedIn();
}

final class SessionFailure extends SessionState {
  const SessionFailure(this.failure);

  final AppFailure failure;
}
