import 'dart:async';
import 'dart:typed_data';

import '../failure/app_failure.dart';
import '../storage/stores.dart';
import 'session_state.dart';

/// Coordinates explicit session operations over one serialized persistence
/// queue. Construction is inert: it never reads credentials or logout state.
final class SessionManager {
  factory SessionManager({
    required SecureStore secureStore,
    required LogoutIntentStore logoutIntentStore,
  }) => SessionManager._(secureStore, logoutIntentStore);

  SessionManager._(this._secureStore, this._logoutIntentStore);

  static const String credentialStorageKey = 'session_credential';

  final SecureStore _secureStore;
  final LogoutIntentStore _logoutIntentStore;
  final StreamController<SessionState> _changes =
      StreamController<SessionState>.broadcast();

  Future<void> _queueTail = Future<void>.value();
  Future<void>? _disposeFuture;
  SessionState _state = const SessionUnknown();
  Credential? _credential;
  AppFailure? _revocationFailure;
  int _generation = 0;
  bool _locallyRevoked = false;
  bool _disposed = false;

  SessionState get state => _state;
  Stream<SessionState> get changes => _changes.stream;

  /// Explicit authorization-boundary access; callers receive only a copy.
  Uint8List? copyCredentialForAuthorization() => _credential?.copyBytes();

  /// Reads marker before secure storage and never restores a credential unless
  /// the marker is readable, valid, and false.
  Future<void> restore() {
    if (_disposed) return Future<void>.error(_disposedFailure());
    final generation = ++_generation;
    return _enqueue(() async {
      if (!_isCurrent(generation)) return;
      if (_locallyRevoked) {
        final failure = _revocationFailure;
        if (failure != null) {
          _publish(SessionFailure(failure), generation);
        } else {
          _publish(const SessionSignedOut(), generation);
        }
        return;
      }

      bool pending;
      try {
        pending = await _logoutIntentStore.readPending();
      } catch (error) {
        final failure = _asFailure(error);
        _failClosed(failure, generation);
        throw failure;
      }
      if (!_isCurrent(generation) || _locallyRevoked) return;
      if (pending) {
        _credential = null;
        _locallyRevoked = true;
        _revocationFailure = null;
        _publish(const SessionSignedOut(), generation);
        return;
      }

      Uint8List? bytes;
      try {
        bytes = await _secureStore.read(credentialStorageKey);
      } catch (error) {
        final failure = _asFailure(error);
        _failClosed(failure, generation);
        throw failure;
      }
      if (!_isCurrent(generation) || _locallyRevoked) return;
      if (bytes == null) {
        _credential = null;
        _publish(const SessionSignedOut(), generation);
        return;
      }
      if (bytes.isEmpty || bytes.length > Credential.maxBytes) {
        final failure = AppFailure(
          FailureKind.validation,
          code: 'session.credential_invalid',
          localizationKey: 'failure.validation',
        );
        _failClosed(failure, generation);
        throw failure;
      }
      _credential = Credential(bytes);
      _publish(const SessionSignedIn(), generation);
    });
  }

  /// Explicit sign-in writes a pending marker first, then the copied
  /// credential, and clears that marker only after all prior steps succeed.
  Future<void> signIn(Credential credential) {
    if (_disposed) return Future<void>.error(_disposedFailure());
    final generation = ++_generation;
    final bytes = credential.copyBytes();
    _credential = null;
    _locallyRevoked = true;
    _revocationFailure = null;
    final persistence = _enqueue(() async {
      if (!_isCurrent(generation)) return;
      try {
        await _logoutIntentStore.markPending();
        if (!_isCurrent(generation)) return;
        await _secureStore.write(
          credentialStorageKey,
          Uint8List.fromList(bytes),
        );
        if (!_isCurrent(generation)) return;
        await _logoutIntentStore.clear();
        if (!_isCurrent(generation)) return;

        _credential = Credential(bytes);
        _locallyRevoked = false;
        _revocationFailure = null;
        _publish(const SessionSignedIn(), generation);
      } catch (error) {
        final failure = _asFailure(error);
        _failClosed(failure, generation);
        throw failure;
      }
    });
    _publish(const SessionSignedOut(), generation);
    return persistence;
  }

  /// Immediately revokes in-memory access and publishes signed-out state before
  /// returning. Persistence is serialized but never cancelled by disposal.
  Future<void> signOut() {
    if (_disposed) return Future<void>.error(_disposedFailure());
    final generation = ++_generation;
    _credential = null;
    _locallyRevoked = true;
    _revocationFailure = null;
    final persistence = _enqueue(() async {
      AppFailure? markerFailure;
      AppFailure? deletionFailure;
      try {
        await _logoutIntentStore.markPending();
      } catch (error) {
        markerFailure = _asFailure(error);
      }
      try {
        await _secureStore.remove(credentialStorageKey);
      } catch (error) {
        deletionFailure = _asFailure(error);
      }

      final failure = markerFailure != null && deletionFailure != null
          ? AppFailure(
              FailureKind.unknown,
              code: 'session.logout_durability_unproven',
              localizationKey: 'failure.unknown',
            )
          : markerFailure ?? deletionFailure;
      if (failure != null) {
        _failClosed(failure, generation);
        throw failure;
      }
      // Keep the durable marker until a later explicit sign-in succeeds.
      _publish(const SessionSignedOut(), generation);
    });
    _publish(const SessionSignedOut(), generation);
    return persistence;
  }

  /// Invalidates authorization and events immediately, then waits for already
  /// queued persistence (in particular a started logout) to finish.
  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;
    _disposed = true;
    _generation++;
    _credential = null;
    _locallyRevoked = true;
    _state = const SessionSignedOut();
    final future = _queueTail.then((_) {}).whenComplete(_changes.close);
    _disposeFuture = future;
    return future;
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _queueTail.then<void>((_) => operation());
    _queueTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  void _publish(SessionState state, int generation) {
    if (!_isCurrent(generation)) return;
    _state = state;
    if (!_changes.isClosed) _changes.add(state);
  }

  void _failClosed(AppFailure failure, int generation) {
    if (!_isCurrent(generation)) return;
    _credential = null;
    _locallyRevoked = true;
    _revocationFailure = failure;
    _publish(SessionFailure(failure), generation);
  }

  static AppFailure _asFailure(Object error) =>
      error is AppFailure ? error : AppFailure.fromException(error);

  static AppFailure _disposedFailure() => AppFailure(
    FailureKind.cancelled,
    code: 'session.disposed',
    localizationKey: 'failure.cancelled',
  );
}
