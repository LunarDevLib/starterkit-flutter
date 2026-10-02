import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_starterkit/core/failure/app_failure.dart';
import 'package:flutter_starterkit/core/session/session_manager.dart';
import 'package:flutter_starterkit/core/session/session_state.dart';
import 'package:flutter_starterkit/core/storage/stores.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SessionManager', () {
    test('constructor is inert and exposes nonsecret state/events', () async {
      final secure = _MemorySecureStore();
      final marker = _MemoryLogoutIntentStore();
      final manager = SessionManager(
        secureStore: secure,
        logoutIntentStore: marker,
      );
      final events = <SessionState>[];
      final subscription = manager.changes.listen(events.add);
      expect(manager.state, isA<SessionUnknown>());
      expect(secure.readCalls, 0);
      expect(secure.writeCalls, 0);
      expect(marker.calls, isEmpty);

      await manager.restore();
      expect(manager.state, isA<SessionSignedOut>());
      await Future<void>.delayed(Duration.zero);
      expect(events.single, isA<SessionSignedOut>());
      await subscription.cancel();
      await manager.dispose();
    });

    test(
      'restore reads marker before credential and never embeds bytes in state',
      () async {
        final secure = _MemorySecureStore()
          ..values[SessionManager.credentialStorageKey] = Uint8List.fromList([
            11,
            22,
            33,
          ]);
        final marker = _MemoryLogoutIntentStore();
        final manager = SessionManager(
          secureStore: secure,
          logoutIntentStore: marker,
        );
        await manager.restore();
        expect(marker.calls, ['read']);
        expect(secure.readCalls, 1);
        expect(manager.state, isA<SessionSignedIn>());
        expect(manager.state.toString(), isNot(contains('11')));
        final bytes = manager.copyCredentialForAuthorization()!;
        bytes[0] = 0;
        expect(manager.copyCredentialForAuthorization(), [11, 22, 33]);
        await manager.dispose();
      },
    );

    test(
      'unreadable or pending marker fails closed before any secure read',
      () async {
        final secure = _MemorySecureStore()
          ..values[SessionManager.credentialStorageKey] = Uint8List.fromList([
            4,
            5,
          ]);
        final unreadableMarker = _MemoryLogoutIntentStore()
          ..readError = StateError('private marker detail');
        final unreadableManager = SessionManager(
          secureStore: secure,
          logoutIntentStore: unreadableMarker,
        );
        await expectLater(
          unreadableManager.restore(),
          throwsA(isA<AppFailure>()),
        );
        expect(secure.readCalls, 0);
        expect(unreadableManager.state, isA<SessionFailure>());
        expect(unreadableManager.state.toString(), isNot(contains('private')));
        await unreadableManager.dispose();

        final pendingMarker = _MemoryLogoutIntentStore()..pending = true;
        final pendingManager = SessionManager(
          secureStore: secure,
          logoutIntentStore: pendingMarker,
        );
        await pendingManager.restore();
        expect(pendingManager.state, isA<SessionSignedOut>());
        expect(secure.readCalls, 0);
        await pendingManager.dispose();
      },
    );

    test('signOut revokes synchronously and marks before deleting', () async {
      final secure = _MemorySecureStore()
        ..values[SessionManager.credentialStorageKey] = Uint8List.fromList([
          7,
          8,
        ]);
      final timeline = <String>[];
      final marker = _MemoryLogoutIntentStore()..timeline = timeline;
      secure.timeline = timeline;
      final manager = SessionManager(
        secureStore: secure,
        logoutIntentStore: marker,
      );
      await manager.restore();
      final events = <SessionState>[];
      final subscription = manager.changes.listen(events.add);
      final logout = manager.signOut();
      expect(manager.state, isA<SessionSignedOut>());
      expect(manager.copyCredentialForAuthorization(), isNull);
      await logout;
      await Future<void>.delayed(Duration.zero);
      expect(timeline, containsAllInOrder(['read', 'mark', 'remove']));
      expect(secure.calls, [
        'read:session_credential',
        'remove:session_credential',
      ]);
      expect(marker.pending, isTrue);
      expect(events.first, isA<SessionSignedOut>());
      await subscription.cancel();
      await manager.dispose();
    });

    test(
      'logout marker and delete outcomes preserve fail-closed behavior',
      () async {
        final scenarios = [
          (markFails: false, deleteFails: false, expectedCode: null),
          (markFails: true, deleteFails: false, expectedCode: 'store.failed'),
          (markFails: false, deleteFails: true, expectedCode: 'store.failed'),
          (
            markFails: true,
            deleteFails: true,
            expectedCode: 'session.logout_durability_unproven',
          ),
        ];
        for (final scenario in scenarios) {
          final secure = _MemorySecureStore()
            ..values[SessionManager.credentialStorageKey] = Uint8List.fromList([
              4,
              5,
              6,
            ]);
          final marker = _MemoryLogoutIntentStore();
          final storeFailure = AppFailure(
            FailureKind.unavailable,
            code: 'store.failed',
            localizationKey: 'failure.unavailable',
          );
          if (scenario.markFails) marker.markError = storeFailure;
          if (scenario.deleteFails) secure.removeError = storeFailure;
          final manager = SessionManager(
            secureStore: secure,
            logoutIntentStore: marker,
          );

          if (scenario.expectedCode == null) {
            await manager.signOut();
            expect(manager.state, isA<SessionSignedOut>());
          } else {
            await expectLater(
              manager.signOut(),
              throwsA(
                isA<AppFailure>().having(
                  (failure) => failure.code,
                  'code',
                  scenario.expectedCode,
                ),
              ),
            );
            expect(manager.state, isA<SessionFailure>());
            expect(manager.copyCredentialForAuthorization(), isNull);
          }

          expect(
            secure.removeCalls,
            1,
            reason: 'delete attempted for $scenario',
          );
          expect(marker.pending, !scenario.markFails);
          await manager.dispose();

          final readsBeforeRestart = secure.readCalls;
          final restarted = SessionManager(
            secureStore: secure,
            logoutIntentStore: marker,
          );
          await restarted.restore();
          if (marker.pending) {
            expect(restarted.state, isA<SessionSignedOut>());
            expect(secure.readCalls, readsBeforeRestart);
          } else if (scenario.deleteFails) {
            // With both persistence operations failed, restart durability is
            // explicitly unproven: the surviving credential can be restored.
            expect(restarted.state, isA<SessionSignedIn>());
            expect(secure.readCalls, readsBeforeRestart + 1);
          } else {
            expect(restarted.state, isA<SessionSignedOut>());
            expect(secure.readCalls, readsBeforeRestart + 1);
          }
          await restarted.dispose();
        }
      },
    );

    test('failed sign-out marker is followed by deletion and restart sees safe state', () async {
      final secure = _MemorySecureStore()
        ..values[SessionManager.credentialStorageKey] = Uint8List.fromList([
          8,
          9,
        ]);
      final marker = _MemoryLogoutIntentStore()..markError = _StoreFailure();
      final manager = SessionManager(
        secureStore: secure,
        logoutIntentStore: marker,
      );
      await expectLater(manager.signOut(), throwsA(isA<AppFailure>()));
      expect(secure.removeCalls, 1);
      expect(marker.calls, ['mark']);
      expect(
        secure.values.containsKey(SessionManager.credentialStorageKey),
        isFalse,
      );
      await manager.dispose();

      final restarted = SessionManager(
        secureStore: secure,
        logoutIntentStore: marker,
      );
      await restarted.restore();
      expect(restarted.state, isA<SessionSignedOut>());
      expect(
        secure.values.containsKey(SessionManager.credentialStorageKey),
        isFalse,
      );
      await restarted.dispose();
    });

    test(
      'later logout supersedes a sign-in blocked in credential write',
      () async {
        final gate = Completer<void>();
        final secure = _MemorySecureStore()..writeGate = gate;
        final marker = _MemoryLogoutIntentStore();
        final manager = SessionManager(
          secureStore: secure,
          logoutIntentStore: marker,
        );
        final signIn = manager.signIn(
          Credential(Uint8List.fromList([1, 2, 3])),
        );
        await Future<void>.delayed(Duration.zero);
        expect(secure.writeCalls, 1);
        final signOut = manager.signOut();
        expect(manager.state, isA<SessionSignedOut>());
        gate.complete();
        await signIn;
        await signOut;
        expect(marker.pending, isTrue);
        expect(
          secure.values.containsKey(SessionManager.credentialStorageKey),
          isFalse,
        );
        expect(manager.state, isA<SessionSignedOut>());
        await manager.dispose();
      },
    );

    test(
      'sign-out during marker clear re-marks before returning signed out',
      () async {
        final clearGate = Completer<void>();
        final secure = _MemorySecureStore();
        final marker = _MemoryLogoutIntentStore()..clearGate = clearGate;
        final manager = SessionManager(
          secureStore: secure,
          logoutIntentStore: marker,
        );
        final signIn = manager.signIn(Credential(Uint8List.fromList([6])));
        await Future<void>.delayed(Duration.zero);
        expect(marker.clearCalls, 1);
        final signOut = manager.signOut();
        expect(manager.state, isA<SessionSignedOut>());
        clearGate.complete();
        await signIn;
        await signOut;
        expect(marker.markCalls, 2);
        expect(marker.pending, isTrue);
        expect(manager.copyCredentialForAuthorization(), isNull);
        await manager.dispose();
      },
    );

    test('sign-out racing marker read prevents stale secure restore', () async {
      final readGate = Completer<bool>();
      final secure = _MemorySecureStore()
        ..values[SessionManager.credentialStorageKey] = Uint8List.fromList([1]);
      final marker = _MemoryLogoutIntentStore()..readGate = readGate;
      final manager = SessionManager(
        secureStore: secure,
        logoutIntentStore: marker,
      );
      final restore = manager.restore();
      await Future<void>.delayed(Duration.zero);
      final signOut = manager.signOut();
      expect(manager.state, isA<SessionSignedOut>());
      readGate.complete(false);
      await restore;
      await signOut;
      expect(secure.readCalls, 0);
      expect(manager.state, isA<SessionSignedOut>());
      await manager.dispose();
    });

    test(
      'queue recovers after failure and dispose does not abandon logout',
      () async {
        final removeGate = Completer<void>();
        final secure = _MemorySecureStore()..removeGate = removeGate;
        final marker = _MemoryLogoutIntentStore();
        final manager = SessionManager(
          secureStore: secure,
          logoutIntentStore: marker,
        );
        final events = <SessionState>[];
        final subscription = manager.changes.listen(events.add);
        final logout = manager.signOut();
        await Future<void>.delayed(Duration.zero);
        expect(marker.pending, isTrue);
        final eventCountAtDispose = events.length;
        final disposing = manager.dispose();
        removeGate.complete();
        await logout;
        await disposing;
        expect(
          secure.values.containsKey(SessionManager.credentialStorageKey),
          isFalse,
        );
        expect(marker.pending, isTrue);
        expect(events.length, eventCountAtDispose);
        expect(manager.copyCredentialForAuthorization(), isNull);
        await subscription.cancel();
      },
    );

    test('dispose from revoke listener still drains started logout', () async {
      final secure = _MemorySecureStore();
      final marker = _MemoryLogoutIntentStore();
      final manager = SessionManager(
        secureStore: secure,
        logoutIntentStore: marker,
      );
      Future<void>? disposing;
      final subscription = manager.changes.listen((state) {
        if (state is SessionSignedOut) disposing = manager.dispose();
      });
      final logout = manager.signOut();
      await logout;
      await disposing;
      expect(marker.pending, isTrue);
      expect(secure.removeCalls, 1);
      await subscription.cancel();
    });

    test('signed-in listener can synchronously request logout without nested-add failure', () async {
      final secure = _MemorySecureStore();
      final marker = _MemoryLogoutIntentStore();
      final manager = SessionManager(
        secureStore: secure,
        logoutIntentStore: marker,
      );
      final logoutStarted = Completer<Future<void>>();
      final signedOutEvent = Completer<void>();
      Uint8List? credentialAtListenerSignOut;
      final subscription = manager.changes.listen((state) {
        if (state is SessionSignedIn && !logoutStarted.isCompleted) {
          final logout = manager.signOut();
          credentialAtListenerSignOut = manager
              .copyCredentialForAuthorization();
          logoutStarted.complete(logout);
        } else if (state is SessionSignedOut &&
            !signedOutEvent.isCompleted &&
            logoutStarted.isCompleted) {
          signedOutEvent.complete();
        }
      });

      await manager.signIn(Credential(Uint8List.fromList([3, 2, 1])));
      final logout = await logoutStarted.future.timeout(
        const Duration(seconds: 5),
      );
      expect(credentialAtListenerSignOut, isNull);
      await logout;
      await signedOutEvent.future.timeout(const Duration(seconds: 5));
      expect(manager.state, isA<SessionSignedOut>());
      expect(marker.pending, isTrue);
      expect(secure.removeCalls, 1);
      await subscription.cancel();
      await manager.dispose();
    });

    test('queue can be used again after a failed persisted sign-out', () async {
      final secure = _MemorySecureStore();
      final marker = _MemoryLogoutIntentStore()..markError = _StoreFailure();
      final manager = SessionManager(
        secureStore: secure,
        logoutIntentStore: marker,
      );
      await expectLater(manager.signOut(), throwsA(isA<AppFailure>()));
      marker.markError = null;
      await manager.signIn(Credential(Uint8List.fromList([4, 2])));
      expect(manager.state, isA<SessionSignedIn>());
      expect(marker.pending, isFalse);
      expect(manager.copyCredentialForAuthorization(), [4, 2]);
      await manager.dispose();
    });
  });
}

final class _StoreFailure implements Exception {
  @override
  String toString() => 'private storage detail';
}

final class _MemorySecureStore implements SecureStore {
  final Map<String, Uint8List> values = {};
  final List<String> calls = [];
  List<String>? timeline;
  int readCalls = 0;
  int writeCalls = 0;
  int removeCalls = 0;
  Completer<void>? writeGate;
  Completer<void>? removeGate;
  Object? readError;
  Object? writeError;
  Object? removeError;

  @override
  Future<Uint8List?> read(String key) async {
    calls.add('read:$key');
    timeline?.add('read');
    readCalls++;
    if (readError case final error?) throw error;
    final value = values[key];
    return value == null ? null : Uint8List.fromList(value);
  }

  @override
  Future<void> write(String key, Uint8List value) async {
    calls.add('write:$key');
    timeline?.add('write');
    writeCalls++;
    final copy = Uint8List.fromList(value);
    final gate = writeGate;
    if (gate != null) await gate.future;
    if (writeError case final error?) throw error;
    values[key] = copy;
  }

  @override
  Future<void> remove(String key) async {
    calls.add('remove:$key');
    timeline?.add('remove');
    removeCalls++;
    final gate = removeGate;
    if (gate != null) await gate.future;
    if (removeError case final error?) throw error;
    values.remove(key);
  }
}

final class _MemoryLogoutIntentStore implements LogoutIntentStore {
  bool pending = false;
  final List<String> calls = [];
  List<String>? timeline;
  int markCalls = 0;
  int clearCalls = 0;
  Completer<bool>? readGate;
  Completer<void>? markGate;
  Completer<void>? clearGate;
  Object? readError;
  Object? markError;
  Object? clearError;

  @override
  Future<bool> readPending() async {
    calls.add('read');
    timeline?.add('read');
    final gate = readGate;
    final result = gate == null ? pending : await gate.future;
    if (readError case final error?) throw error;
    return result;
  }

  @override
  Future<void> markPending() async {
    calls.add('mark');
    timeline?.add('mark');
    markCalls++;
    final gate = markGate;
    if (gate != null) await gate.future;
    if (markError case final error?) throw error;
    pending = true;
  }

  @override
  Future<void> clear() async {
    calls.add('clear');
    timeline?.add('clear');
    clearCalls++;
    final gate = clearGate;
    if (gate != null) await gate.future;
    if (clearError case final error?) throw error;
    pending = false;
  }
}
