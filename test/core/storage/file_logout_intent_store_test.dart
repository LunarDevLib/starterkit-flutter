import 'dart:io';

import 'package:flutter_starterkit/core/failure/app_failure.dart';
import 'package:flutter_starterkit/core/storage/file_logout_intent_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FileLogoutIntentStore', () {
    late Directory root;

    setUp(() {
      final created = Directory.systemTemp.createTempSync('logout_marker_');
      root = Directory(created.resolveSymbolicLinksSync());
    });
    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('is inert until called and persists across fresh instances', () async {
      final store = FileLogoutIntentStore(directory: root);
      expect(await store.readPending(), isFalse);
      await store.markPending();
      expect(
        await FileLogoutIntentStore(directory: root).readPending(),
        isTrue,
      );
      await FileLogoutIntentStore(directory: root).clear();
      await store.clear();
      expect(await store.readPending(), isFalse);
    });

    test('rejects malformed and over-limit marker contents', () async {
      final marker = File(
        '${root.path}/${FileLogoutIntentStore.markerFileName}',
      );
      final store = FileLogoutIntentStore(directory: root);
      marker.writeAsStringSync('wrong-version\n');
      await expectLater(store.readPending(), throwsA(isA<AppFailure>()));
      marker.writeAsStringSync('x' * 1024 * 1024);
      await expectLater(store.readPending(), throwsA(isA<AppFailure>()));
    });

    test('rejects marker symlinks and noncanonical directory paths', () async {
      final outside = File('${root.path}/logout-marker-outside')
        ..writeAsStringSync('starterkit.logout-intent.v1\n');
      final marker = Link(
        '${root.path}/${FileLogoutIntentStore.markerFileName}',
      );
      try {
        marker.createSync(outside.path);
        await expectLater(
          FileLogoutIntentStore(directory: root).readPending(),
          throwsA(isA<AppFailure>()),
        );
      } finally {
        if (marker.existsSync()) marker.deleteSync();
        if (outside.existsSync()) outside.deleteSync();
      }

      final alias = Directory('${root.path}/alias')..createSync();
      final directoryLink = Link('${alias.path}/link');
      directoryLink.createSync(root.path);
      try {
        await expectLater(
          FileLogoutIntentStore(directory: Directory(directoryLink.path))
              .readPending(),
          throwsA(isA<AppFailure>()),
        );
      } finally {
        if (directoryLink.existsSync()) directoryLink.deleteSync();
        if (alias.existsSync()) alias.deleteSync(recursive: true);
      }
    });

    test(
      'ignores stale stage files without treating them as a pending marker',
      () async {
        final stale = File(
          '${root.path}/${FileLogoutIntentStore.markerFileName}.stage.stale',
        )..writeAsStringSync('partial');
        expect(
          await FileLogoutIntentStore(directory: root).readPending(),
          isFalse,
        );
        expect(stale.readAsStringSync(), 'partial');
      },
    );

    test('does not follow stale staging symlinks', () async {
      final target = File('${root.path}/stage-target')
        ..writeAsStringSync('do not read or mutate');
      final staleLink = Link(
        '${root.path}/${FileLogoutIntentStore.markerFileName}.stage.stale',
      )..createSync(target.path);
      expect(
        await FileLogoutIntentStore(directory: root).readPending(),
        isFalse,
      );
      expect(target.readAsStringSync(), 'do not read or mutate');
      expect(staleLink.existsSync(), isTrue);
    });

    test('failed atomic rename leaves an existing marker untouched', () async {
      final initial = FileLogoutIntentStore(directory: root);
      await initial.markPending();
      final marker = File(
        '${root.path}/${FileLogoutIntentStore.markerFileName}',
      );
      final before = marker.readAsBytesSync();
      final failing = FileLogoutIntentStore(
        directory: root,
        renameStageForTesting: (_, __) {
          throw const FileSystemException('private test failure');
        },
      );
      await expectLater(failing.markPending(), throwsA(isA<AppFailure>()));
      expect(marker.readAsBytesSync(), before);
      expect(await initial.readPending(), isTrue);
      expect(
        root.listSync().whereType<File>().where(
          (file) => file.path.contains('.stage.'),
        ),
        isEmpty,
      );
    });

    test(
      'clear propagates unsafe marker errors and missing directory failures',
      () async {
        Directory('${root.path}/${FileLogoutIntentStore.markerFileName}')
            .createSync();
        await expectLater(
          FileLogoutIntentStore(directory: root).clear(),
          throwsA(isA<AppFailure>()),
        );
        final missing = Directory('${root.path}/missing');
        await expectLater(
          FileLogoutIntentStore(directory: missing).readPending(),
          throwsA(isA<AppFailure>()),
        );
      },
    );
  });
}
