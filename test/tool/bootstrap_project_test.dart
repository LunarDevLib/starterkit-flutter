@Tags(['template-only'])
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('bootstrap_project.dart', () {
    late Directory fixture;

    setUp(() {
      fixture = _createFixture();
    });

    tearDown(() {
      if (fixture.existsSync()) {
        fixture.deleteSync(recursive: true);
      }
    });

    test('renames a copy successfully', () async {
      final qrBefore = _optionalQrPackageHashes(fixture);
      expect(qrBefore, isNotEmpty);
      final result = await _runBootstrap(fixture, [
        '--package-name',
        'sample_app',
        '--app-name',
        'Sample App',
        '--bundle-id',
        'dev.example.sampleapp',
        '--scheme',
        'sample-app',
      ]);
      expect(result.exitCode, 0, reason: result.stderr);
      _expectRenamed(
        fixture: fixture,
        packageName: 'sample_app',
        appName: 'Sample App',
        bundleId: 'dev.example.sampleapp',
        scheme: 'sample-app',
      );
      expect(_optionalQrPackageHashes(fixture), qrBefore);
    });

    test('dry-run makes no changes', () async {
      final before = _contentHashes(fixture);
      final result = await _runBootstrap(fixture, [
        '--dry-run',
        '--package-name',
        'sample_app',
        '--app-name',
        'Sample App',
        '--bundle-id',
        'dev.example.sampleapp',
        '--scheme',
        'sample-app',
      ]);
      expect(result.exitCode, 0, reason: result.stderr);
      final after = _contentHashes(fixture);
      expect(after, before);
    });

    test('rejects malformed inputs and makes no changes', () async {
      final before = _contentHashes(fixture);
      final result = await _runBootstrap(fixture, [
        '--package-name',
        'SampleApp',
        '--app-name',
        'Sample App',
        '--bundle-id',
        'dev.example.sampleapp',
        '--scheme',
        'sample-app',
      ]);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('package-name'));
      final after = _contentHashes(fixture);
      expect(after, before);
    });

    test('aborts on missing anchor without partial edits', () async {
      final pubspec = File('${fixture.path}/pubspec.yaml');
      pubspec.writeAsStringSync(
        pubspec.readAsStringSync().replaceFirst(
          'name: flutter_starterkit',
          'name: sample_app',
        ),
      );
      final before = _contentHashes(fixture);
      final result = await _runBootstrap(fixture, [
        '--package-name',
        'sample_app',
        '--app-name',
        'Sample App',
        '--bundle-id',
        'dev.example.sampleapp',
        '--scheme',
        'sample-app',
      ]);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('Anchor mismatch'));
      final after = _contentHashes(fixture);
      expect(after, before);
    });

    test(
      'aborts on Kotlin destination collision without partial edits',
      () async {
        final collisionDir = Directory(
          '${fixture.path}/android/app/src/main/kotlin/dev/example/sampleapp',
        );
        collisionDir.createSync(recursive: true);
        File('${collisionDir.path}/MainActivity.kt').writeAsStringSync('');
        final before = _contentHashes(fixture);
        final result = await _runBootstrap(fixture, [
          '--package-name',
          'sample_app',
          '--app-name',
          'Sample App',
          '--bundle-id',
          'dev.example.sampleapp',
          '--scheme',
          'sample-app',
        ]);
        expect(result.exitCode, isNot(0));
        expect(result.stderr, contains('Destination'));
        final after = _contentHashes(fixture);
        expect(after, before);
      },
    );

    test('rejects duplicate option flags', () async {
      final before = _contentHashes(fixture);
      final result = await _runBootstrap(fixture, [
        '--package-name',
        'sample_app',
        '--package-name',
        'other_app',
        '--app-name',
        'Sample App',
        '--bundle-id',
        'dev.example.sampleapp',
        '--scheme',
        'sample-app',
      ]);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('Duplicate option'));
      expect(_contentHashes(fixture), before);
    });

    test('rejects Dart reserved package name', () async {
      final before = _contentHashes(fixture);
      final result = await _runBootstrap(fixture, [
        '--package-name',
        'class',
        '--app-name',
        'Sample App',
        '--bundle-id',
        'dev.example.sampleapp',
        '--scheme',
        'sample-app',
      ]);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('Dart reserved word'));
      expect(_contentHashes(fixture), before);
    });

    test('rejects Kotlin/Java reserved bundle segment', () async {
      final before = _contentHashes(fixture);
      final result = await _runBootstrap(fixture, [
        '--package-name',
        'sample_app',
        '--app-name',
        'Sample App',
        '--bundle-id',
        'dev.class.cargo',
        '--scheme',
        'sample-app',
      ]);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('reserved Kotlin/Java keyword'));
      expect(_contentHashes(fixture), before);
    });

    test('rejects Kotlin in keyword bundle segment without writes', () async {
      final before = _contentHashes(fixture);
      final result = await _runBootstrap(fixture, [
        '--package-name',
        'sample_app',
        '--app-name',
        'Sample App',
        '--bundle-id',
        'dev.in.cargo',
        '--scheme',
        'sample-app',
      ]);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('reserved Kotlin/Java keyword'));
      expect(_contentHashes(fixture), before);
    });

    test('rejects bundle-id containing template bundle ID', () async {
      final before = _contentHashes(fixture);
      final result = await _runBootstrap(fixture, [
        '--package-name',
        'sample_app',
        '--app-name',
        'Sample App',
        '--bundle-id',
        'dev.com.example.flutterstarterkit',
        '--scheme',
        'sample-app',
      ]);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('template bundle ID'));
      expect(_contentHashes(fixture), before);
    });

    test('accepts apostrophe in app name and escapes it', () async {
      final result = await _runBootstrap(fixture, [
        '--package-name',
        'sample_app',
        '--app-name',
        "Sample's App",
        '--bundle-id',
        'dev.example.sampleapp',
        '--scheme',
        'sample-app',
      ]);
      expect(result.exitCode, 0, reason: result.stderr);
      final enArb = jsonDecode(
        File('${fixture.path}/lib/l10n/app_en.arb').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(enArb['appTitle'], "Sample's App");
      final koArb = jsonDecode(
        File('${fixture.path}/lib/l10n/app_ko.arb').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(koArb['appTitle'], "Sample's App");
      expect(
        File('${fixture.path}/android/app/src/main/AndroidManifest.xml')
            .readAsStringSync(),
        contains('android:label="Sample&apos;s App"'),
      );
      expect(
        File('${fixture.path}/ios/Runner/Info.plist').readAsStringSync(),
        contains('<string>Sample&apos;s App</string>'),
      );
    });

    test('escapes dollar sign in app name', () async {
      final result = await _runBootstrap(fixture, [
        '--package-name',
        'sample_app',
        '--app-name',
        r'Sample $ App',
        '--bundle-id',
        'dev.example.sampleapp',
        '--scheme',
        'sample-app',
      ]);
      expect(result.exitCode, 0, reason: result.stderr);
      final enArb = jsonDecode(
        File('${fixture.path}/lib/l10n/app_en.arb').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(enArb['appTitle'], r'Sample $ App');
    });

    test(
      'rejects symlink files in managed sources and does not follow them',
      () async {
        final externalDir = Directory.systemTemp.createTempSync(
          'bootstrap_ext_',
        );
        final externalFile = File('${externalDir.path}/external.dart')
          ..writeAsStringSync('// external');
        final linkFile = File('${fixture.path}/lib/external_link.dart');
        Link(linkFile.path).createSync(externalFile.path);
        final before = _contentHashes(fixture);
        final result = await _runBootstrap(fixture, [
          '--package-name',
          'sample_app',
          '--app-name',
          'Sample App',
          '--bundle-id',
          'dev.example.sampleapp',
          '--scheme',
          'sample-app',
        ]);
        expect(result.exitCode, isNot(0));
        expect(result.stderr, contains('Symlink'));
        expect(_contentHashes(fixture), before);
        expect(externalFile.readAsStringSync(), '// external');
        externalDir.deleteSync(recursive: true);
      },
    );

    test(
      'rejects symlinked top-level test directory without following it',
      () async {
        final managedTest = Directory('${fixture.path}/test');
        final originalTest = Directory('${fixture.path}/test_original');
        managedTest.renameSync(originalTest.path);

        final externalDir = Directory.systemTemp.createTempSync(
          'bootstrap_external_test_',
        );
        final sentinel = File('${externalDir.path}/sentinel.dart')
          ..writeAsStringSync('// external sentinel');
        Link(managedTest.path).createSync(externalDir.path);
        try {
          final before = _contentHashes(fixture);
          final result = await _runBootstrap(fixture, [
            '--package-name',
            'sample_app',
            '--app-name',
            'Sample App',
            '--bundle-id',
            'dev.example.sampleapp',
            '--scheme',
            'sample-app',
          ]);
          expect(result.exitCode, isNot(0));
          expect(result.stderr, contains('Symlink'));
          expect(_contentHashes(fixture), before);
          expect(sentinel.readAsStringSync(), '// external sentinel');
          expect(Link(managedTest.path).existsSync(), isTrue);
        } finally {
          if (Link(managedTest.path).existsSync()) {
            Link(managedTest.path).deleteSync();
          }
          if (originalTest.existsSync()) {
            originalTest.renameSync(managedTest.path);
          }
          if (externalDir.existsSync()) externalDir.deleteSync(recursive: true);
        }
      },
    );

    test(
      'rejects symlink destination ancestors and does not write outside root',
      () async {
        final externalDir = Directory.systemTemp.createTempSync(
          'bootstrap_ext_',
        );
        final symlinkDir = Directory(
          '${fixture.path}/android/app/src/main/kotlin/dev',
        );
        Link(symlinkDir.path).createSync(externalDir.path);
        final before = _contentHashes(fixture);
        final result = await _runBootstrap(fixture, [
          '--package-name',
          'sample_app',
          '--app-name',
          'Sample App',
          '--bundle-id',
          'dev.example.sampleapp',
          '--scheme',
          'sample-app',
        ]);
        expect(result.exitCode, isNot(0));
        expect(result.stderr, contains('Symlink'));
        expect(_contentHashes(fixture), before);
        expect(externalDir.listSync().isEmpty, isTrue);
        externalDir.deleteSync(recursive: true);
      },
    );

    test('rolls back on induced postcondition failure without changing files or directories', () async {
      File('${fixture.path}/lib/stale_marker.dart')
          .writeAsStringSync('// keep flutter_starterkit');
      final beforeFiles = _contentHashes(fixture);
      final beforeDirs = _directoryTree(fixture);
      final result = await _runBootstrap(fixture, [
        '--package-name',
        'sample_app',
        '--app-name',
        'Sample App',
        '--bundle-id',
        'dev.example.sampleapp',
        '--scheme',
        'sample-app',
      ]);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('Postcondition failed'));
      expect(_contentHashes(fixture), beforeFiles);
      expect(_directoryTree(fixture), beforeDirs);
    });

    test(
      'restores bytes after failure between backup and replacement rename',
      () async {
        File('${fixture.path}/.bootstrap_project_test_fixture')
            .writeAsStringSync('bootstrap-project-test-fixture');
        final beforeFiles = _contentHashes(fixture);
        final beforeDirs = _directoryTree(fixture);
        final result = await _runBootstrap(
          fixture,
          [
            '--package-name',
            'sample_app',
            '--app-name',
            'Sample App',
            '--bundle-id',
            'dev.example.sampleapp',
            '--scheme',
            'sample-app',
          ],
          environment: {
            'BOOTSTRAP_PROJECT_TEST_FAIL_STAGE': 'after-first-edit-backup',
          },
        );
        expect(result.exitCode, isNot(0));
        expect(
          result.stderr,
          contains('Injected execution-phase failure after original backup'),
        );
        expect(_contentHashes(fixture), beforeFiles);
        expect(_directoryTree(fixture), beforeDirs);
        expect(_stagingArtifacts(fixture), isEmpty);
      },
    );

    test('rollback preserves pre-existing empty Kotlin directories', () async {
      File('${fixture.path}/.bootstrap_project_test_fixture')
          .writeAsStringSync('bootstrap-project-test-fixture');
      final preexistingKotlinDir = Directory(
        '${fixture.path}/android/app/src/main/kotlin/dev/example',
      )..createSync(recursive: true);
      final beforeFiles = _contentHashes(fixture);
      final beforeDirs = _directoryTree(fixture);
      final result = await _runBootstrap(
        fixture,
        [
          '--package-name',
          'sample_app',
          '--app-name',
          'Sample App',
          '--bundle-id',
          'dev.example.sampleapp',
          '--scheme',
          'sample-app',
        ],
        environment: {'BOOTSTRAP_PROJECT_TEST_FAIL_STAGE': 'after-kotlin-move'},
      );
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('Injected execution-phase failure'));
      expect(_contentHashes(fixture), beforeFiles);
      expect(_directoryTree(fixture), beforeDirs);
      expect(preexistingKotlinDir.existsSync(), isTrue);
      expect(preexistingKotlinDir.listSync(), isEmpty);
      expect(_stagingArtifacts(fixture), isEmpty);
    });

    test(
      'preserves changed files and original backup on rollback conflict',
      () async {
        File('${fixture.path}/.bootstrap_project_test_fixture')
            .writeAsStringSync('bootstrap-project-test-fixture');
        final beforeFiles = _contentHashes(fixture);
        final beforeDirs = _directoryTree(fixture);
        final result = await _runBootstrap(
          fixture,
          [
            '--package-name',
            'sample_app',
            '--app-name',
            'Sample App',
            '--bundle-id',
            'dev.example.sampleapp',
            '--scheme',
            'sample-app',
          ],
          environment: {
            'BOOTSTRAP_PROJECT_TEST_FAIL_STAGE': 'conflict-during-second-edit',
          },
        );
        expect(result.exitCode, isNot(0));
        expect(result.stderr, contains('changed since planning'));
        expect(result.stderr, contains('Manual reconciliation required'));

        const userContent = '// bootstrap test user edit\n';
        final pubspec = File('${fixture.path}/pubspec.yaml');
        expect(pubspec.readAsStringSync(), userContent);
        final changedFiles = fixture
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .where((file) => file.readAsStringSync() == userContent)
            .toList();
        expect(changedFiles, hasLength(2));

        final backups = _stagingArtifacts(fixture)
            .where((path) => path.endsWith('.original'))
            .toList();
        expect(backups, hasLength(1));
        final backup = File(backups.single);
        expect(
          sha1Base64(backup.readAsBytesSync()),
          beforeFiles['pubspec.yaml'],
        );

        final afterFiles = _contentHashes(fixture);
        afterFiles.remove('pubspec.yaml');
        final otherChangedFile = changedFiles.singleWhere(
          (file) => file.path != pubspec.path,
        );
        final otherChangedPath = otherChangedFile.path.substring(
          fixture.path.length + 1,
        );
        afterFiles.remove(otherChangedPath);
        afterFiles.remove(backup.path.substring(fixture.path.length + 1));
        final unchangedFiles = Map<String, String>.of(beforeFiles)
          ..remove('pubspec.yaml')
          ..remove(otherChangedPath);
        expect(afterFiles, unchangedFiles);
        expect(_directoryTree(fixture), beforeDirs);
      },
    );

    test('preserves a Kotlin destination occupied after planning', () async {
      File('${fixture.path}/.bootstrap_project_test_fixture')
          .writeAsStringSync('bootstrap-project-test-fixture');
      final destinationDirectory = Directory(
        '${fixture.path}/android/app/src/main/kotlin/dev/example/sampleapp',
      )..createSync(recursive: true);
      final destination = File('${destinationDirectory.path}/MainActivity.kt');
      final beforeFiles = _contentHashes(fixture);
      final beforeDirs = _directoryTree(fixture);
      final result = await _runBootstrap(
        fixture,
        [
          '--package-name',
          'sample_app',
          '--app-name',
          'Sample App',
          '--bundle-id',
          'dev.example.sampleapp',
          '--scheme',
          'sample-app',
        ],
        environment: {
          'BOOTSTRAP_PROJECT_TEST_FAIL_STAGE': 'occupy-kotlin-destination',
        },
      );
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('Kotlin destination'));
      expect(
        destination.readAsStringSync(),
        '// bootstrap test occupied destination\n',
      );
      final afterFiles = _contentHashes(fixture);
      for (final entry in beforeFiles.entries) {
        expect(afterFiles[entry.key], entry.value, reason: entry.key);
      }
      expect(afterFiles.length, beforeFiles.length + 1);
      expect(_directoryTree(fixture), beforeDirs);
      expect(_stagingArtifacts(fixture), isEmpty);
    });

    test('release readiness fails on default fixture', () async {
      final result = await _runValidator(fixture, ['--release-readiness']);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('still'));
    });

    test('release readiness passes after rename', () async {
      final bootstrap = await _runBootstrap(fixture, [
        '--package-name',
        'sample_app',
        '--app-name',
        'Sample App',
        '--bundle-id',
        'dev.example.sampleapp',
        '--scheme',
        'sample-app',
      ]);
      expect(bootstrap.exitCode, 0, reason: bootstrap.stderr);
      final result = await _runValidator(fixture, ['--release-readiness']);
      expect(result.exitCode, 0, reason: result.stderr);
      expect(result.stdout, contains('Template validation passed'));
    });

    test('normal validator mode passes on default fixture', () async {
      final result = await _runValidator(fixture, const []);
      expect(result.exitCode, 0, reason: result.stderr);
      expect(result.stdout, contains('Template validation passed'));
    });
  });
}

Future<ProcessResult> _runBootstrap(
  Directory fixture,
  List<String> args, {
  Map<String, String>? environment,
}) {
  return Process.run(
    'dart',
    ['tool/bootstrap_project.dart', ...args],
    workingDirectory: fixture.path,
    environment: environment,
  );
}

Future<ProcessResult> _runValidator(Directory fixture, List<String> args) {
  return Process.run('dart', [
    'tool/validate_template.dart',
    ...args,
  ], workingDirectory: fixture.path);
}

Directory _createFixture() {
  final repo = Directory.current;
  final temp = Directory.systemTemp.createTempSync('bootstrap_test_');
  final copy = _Copier(repo, temp);

  // Tooling and config
  copy.file('pubspec.yaml');
  copy.file('pubspec.lock');
  copy.file('l10n.yaml');
  copy.file('tool/bootstrap_project.dart');
  copy.file('tool/validate_template.dart');

  // Dart sources (skip generated localization)
  copy.dartFiles(
    'lib',
    exclude: (f) => f.path.contains('/l10n/app_localizations'),
  );
  copy.dartFiles('test');

  // ARB templates
  copy.file('lib/l10n/app_en.arb');
  copy.file('lib/l10n/app_ko.arb');

  // Android
  copy.file('android/app/build.gradle.kts');
  copy.file('android/app/src/main/AndroidManifest.xml');
  copy.file(
    'android/app/src/main/kotlin/com/example/flutterstarterkit/MainActivity.kt',
  );

  // iOS
  copy.file('ios/Runner/Info.plist');
  copy.file('ios/Runner.xcodeproj/project.pbxproj');
  final optionalQrPackage = Directory(
    '${repo.path}/packages/starterkit_qr_barcode',
  );
  if (optionalQrPackage.existsSync()) {
    for (final entity in optionalQrPackage.listSync(recursive: true)) {
      if (entity is File) {
        final relative = entity.path.substring(repo.path.length + 1);
        if (relative
            .split(Platform.pathSeparator)
            .any(
              (part) => const {
                '.dart_tool',
                'build',
                '.gradle',
                '.build',
                'Pods',
                '.symlinks',
                'ephemeral',
                '__pycache__',
              }.contains(part),
            )) {
          continue;
        }
        copy.file(relative);
      }
    }
  }
  return temp;
}

Map<String, String> _optionalQrPackageHashes(Directory root) {
  final package = Directory('${root.path}/packages/starterkit_qr_barcode');
  if (!package.existsSync()) return const {};
  return _contentHashes(package);
}

class _Copier {
  _Copier(this.sourceRoot, this.targetRoot);

  final Directory sourceRoot;
  final Directory targetRoot;

  void file(String relativePath) {
    final source = File('${sourceRoot.path}/$relativePath');
    final target = File('${targetRoot.path}/$relativePath');
    if (!source.existsSync()) {
      throw StateError('Fixture source missing: $relativePath');
    }
    target.parent.createSync(recursive: true);
    source.copySync(target.path);
  }

  void dartFiles(String dirName, {bool Function(File)? exclude}) {
    final sourceDir = Directory('${sourceRoot.path}/$dirName');
    if (!sourceDir.existsSync()) return;
    for (final entity in sourceDir.listSync(recursive: true)) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.dart')) continue;
      if (exclude != null && exclude(entity)) continue;
      final relative = entity.path.substring(sourceRoot.path.length + 1);
      file(relative);
    }
  }
}

Map<String, String> _contentHashes(Directory dir) {
  final result = <String, String>{};
  final files = dir.listSync(recursive: true).whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    final relative = file.path.substring(dir.path.length + 1);
    result[relative] = sha1Base64(file.readAsBytesSync());
  }
  return result;
}

String sha1Base64(List<int> bytes) {
  return base64Encode(bytes);
}

void _expectRenamed({
  required Directory fixture,
  required String packageName,
  required String appName,
  required String bundleId,
  required String scheme,
}) {
  final pubspec = File('${fixture.path}/pubspec.yaml').readAsStringSync();
  expect(pubspec, contains('name: $packageName'));
  expect(pubspec, isNot(contains('name: flutter_starterkit')));

  final sampleImport = File('${fixture.path}/test/widget_test.dart')
      .readAsStringSync();
  expect(sampleImport, contains('package:$packageName/app/sample_app.dart'));
  expect(sampleImport, contains('SampleApp'));

  final enArb = jsonDecode(
    File('${fixture.path}/lib/l10n/app_en.arb').readAsStringSync(),
  ) as Map<String, dynamic>;
  expect(enArb['appTitle'], appName);

  final androidBuild = File('${fixture.path}/android/app/build.gradle.kts')
      .readAsStringSync();
  expect(androidBuild, contains('namespace = "$bundleId"'));
  expect(androidBuild, contains('applicationId = "$bundleId"'));

  final manifest = File(
    '${fixture.path}/android/app/src/main/AndroidManifest.xml',
  ).readAsStringSync();
  expect(manifest, contains('android:label="$appName"'));
  expect(manifest, contains('android:scheme="$scheme"'));

  final mainActivity = File(
    '${fixture.path}/android/app/src/main/kotlin/${bundleId.replaceAll('.', '/')}/MainActivity.kt',
  );
  expect(mainActivity.existsSync(), isTrue);
  expect(mainActivity.readAsStringSync(), contains('package $bundleId'));

  final infoPlist = File('${fixture.path}/ios/Runner/Info.plist')
      .readAsStringSync();
  expect(infoPlist, contains('<string>$appName</string>'));
  expect(infoPlist, contains('<string>$packageName</string>'));
  expect(infoPlist, contains('<string>$scheme</string>'));

  final pbxproj = File('${fixture.path}/ios/Runner.xcodeproj/project.pbxproj')
      .readAsStringSync();
  expect(pbxproj, contains('PRODUCT_BUNDLE_IDENTIFIER = $bundleId;'));
  expect(
    pbxproj,
    contains('PRODUCT_BUNDLE_IDENTIFIER = $bundleId.RunnerTests;'),
  );

  // No stale template imports in non-tool lib/test sources
  final dartFiles =
      Directory('${fixture.path}/lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList()
        ..addAll(
          Directory('${fixture.path}/test')
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart')),
        );
  for (final file in dartFiles) {
    if (file.path.split(Platform.pathSeparator).contains('tool')) continue;
    expect(
      file.readAsStringSync(),
      isNot(contains('package:flutter_starterkit/')),
      reason: file.path,
    );
  }
}

Set<String> _directoryTree(Directory dir) {
  return dir
      .listSync(recursive: true)
      .whereType<Directory>()
      .map((d) => d.path.substring(dir.path.length + 1))
      .toSet();
}

List<String> _stagingArtifacts(Directory dir) {
  return dir
      .listSync(recursive: true, followLinks: false)
      .where(
        (entity) => entity.uri.pathSegments.last.startsWith(
          '.bootstrap_project_stage_',
        ),
      )
      .map((entity) => entity.path)
      .toList();
}
