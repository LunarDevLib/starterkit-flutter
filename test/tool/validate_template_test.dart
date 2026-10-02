@Tags(['template-only'])
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _validatorScript = File(
  '${Directory.current.path}/tool/validate_template.dart',
).absolute.path;

void main() {
  final repoRoot = Directory.current;

  group('validate_template forbidden-package regex regression', () {
    final forbidden = RegExp(
      r'^\s{2}(firebase_|sentry|webview|geolocator|image_picker|camera|permission_handler|firebase_messaging)',
      multiLine: true,
    );

    test('matches top-level dependency declarations at two-space indent', () {
      expect(forbidden.hasMatch('  firebase_core: ^1.0.0'), isTrue);
      expect(forbidden.hasMatch('  sentry_flutter: ^5.0.0'), isTrue);
      expect(forbidden.hasMatch('  permission_handler: ^10.0.0'), isTrue);
      expect(forbidden.hasMatch('  firebase_messaging: ^1.0.0'), isTrue);
      expect(forbidden.hasMatch('  camera: ^1.0.0'), isTrue);
      expect(forbidden.hasMatch('  webview_flutter: ^1.0.0'), isTrue);
      expect(forbidden.hasMatch('  geolocator: ^1.0.0'), isTrue);
      expect(forbidden.hasMatch('  flutter_secure_storage: 11.2.0'), isFalse);
    });

    test('does not match comments or deeper indents', () {
      expect(forbidden.hasMatch('# firebase_core: ^1.0.0'), isFalse);
      expect(forbidden.hasMatch('    firebase_core: ^1.0.0'), isFalse);
      expect(forbidden.hasMatch('description: A firebase project'), isFalse);
    });
  });

  group('default template', () {
    test('passes normal validation', () async {
      final result = await _runValidator(repoRoot.path, release: false);
      expect(result.exitCode, 0, reason: result.stderr);
      expect(result.stdout, contains('Template validation passed'));
    }, timeout: const Timeout(Duration(seconds: 120)));

    test(
      '--release-readiness fails because identity still uses defaults',
      () async {
        final result = await _runValidator(repoRoot.path, release: true);
        expect(result.exitCode, isNot(0));
        expect(
          result.stderr,
          contains('pubspec name is still the template default'),
        );
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  });

  test(
    'network permission in Android main manifest fails normal validation',
    () async {
      final fixture = _createRenamedFixture(repoRoot);
      try {
        final manifest = File(
          '${fixture.path}/android/app/src/main/AndroidManifest.xml',
        );
        final content = manifest.readAsStringSync();
        final manifestTagEnd = content.indexOf('>');
        expect(manifestTagEnd, greaterThan(0));
        manifest.writeAsStringSync(
          content.replaceRange(
            manifestTagEnd + 1,
            manifestTagEnd + 1,
            '\n    <uses-permission android:name="android.permission.INTERNET" />',
          ),
        );
        final result = await _runValidator(fixture.path, release: false);
        expect(result.exitCode, isNot(0));
        expect(result.stderr, contains('must not declare network'));
      } finally {
        fixture.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  group('renamed fixture with O\'Brien title', () {
    late Directory fixture;

    setUp(() => fixture = _createRenamedFixture(repoRoot));
    tearDown(() => fixture.deleteSync(recursive: true));

    test('passes --release-readiness', () async {
      final result = await _runValidator(fixture.path, release: true);
      expect(result.exitCode, 0, reason: result.stderr);
      expect(
        result.stdout,
        contains('Template validation passed (release readiness)'),
      );
    }, timeout: const Timeout(Duration(seconds: 120)));

    test(
      'ignores placeholder stale imports in docs and tool fixtures',
      () async {
        _writeFile(
          fixture,
          'docs/placeholder.md',
          "# package:flutter_starterkit/ and Flutter Starter Kit placeholder",
        );
        _writeFile(
          fixture,
          'tool/stale_fixture.dart',
          "import 'package:flutter_starterkit/main.dart';",
        );
        _writeFile(
          fixture,
          'test/tool/stale_fixture.dart',
          "import 'package:flutter_starterkit/main.dart';",
        );
        final result = await _runValidator(fixture.path, release: true);
        expect(result.exitCode, 0, reason: result.stderr);
        expect(
          result.stderr,
          isNot(contains('stale package:flutter_starterkit/')),
        );
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  });

  group('release-readiness identity failures', () {
    late Directory fixture;

    setUp(() => fixture = _createRenamedFixture(repoRoot));
    tearDown(() => fixture.deleteSync(recursive: true));

    test('missing Info.plist fails', () async {
      File('${fixture.path}/ios/Runner/Info.plist').deleteSync();
      final result = await _runValidator(fixture.path, release: true);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('iOS Info.plist missing'));
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('missing CFBundleName fails', () async {
      final plist = File('${fixture.path}/ios/Runner/Info.plist');
      final content = plist.readAsStringSync().replaceAll(
        RegExp(r'<key>CFBundleName</key>\s*<string>[^<]*</string>'),
        '',
      );
      plist.writeAsStringSync(content);
      final result = await _runValidator(fixture.path, release: true);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('CFBundleName missing'));
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('mismatched test bundle identifiers fail', () async {
      final pbxproj = File(
        '${fixture.path}/ios/Runner.xcodeproj/project.pbxproj',
      );
      final content = pbxproj.readAsStringSync().replaceFirst(
        'com.obrien.obrienapp.RunnerTests;',
        'com.obrien.obrienapp2.RunnerTests;',
      );
      pbxproj.writeAsStringSync(content);
      final result = await _runValidator(fixture.path, release: true);
      expect(result.exitCode, isNot(0));
      expect(
        result.stderr,
        contains(
          'iOS test bundle identifiers do not match app bundle identifier',
        ),
      );
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('divergent native display names fail', () async {
      final manifest = File(
        '${fixture.path}/android/app/src/main/AndroidManifest.xml',
      );
      final content = manifest.readAsStringSync().replaceFirst(
        'android:label="O\'Brien"',
        'android:label="Different"',
      );
      manifest.writeAsStringSync(content);
      final result = await _runValidator(fixture.path, release: true);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('native display names drift'));
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  group('third-locale readiness', () {
    late Directory fixture;

    setUp(() => fixture = _createRenamedFixture(repoRoot));
    tearDown(() => fixture.deleteSync(recursive: true));

    test('valid third locale with matching appTitle passes', () async {
      _addArbLocale(fixture, 'es', appTitle: "O'Brien");
      final result = await _runValidator(fixture.path, release: true);
      expect(result.exitCode, 0, reason: result.stderr);
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('third locale with a different appTitle fails', () async {
      _addArbLocale(fixture, 'es', appTitle: 'Different');
      final result = await _runValidator(fixture.path, release: true);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('ARB appTitle values are inconsistent'));
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('third locale with missing appTitle fails', () async {
      _addArbLocale(fixture, 'es');
      final result = await _runValidator(fixture.path, release: true);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('app_es.arb missing appTitle'));
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}

Future<ProcessResult> _runValidator(
  String workingDirectory, {
  required bool release,
}) async {
  final args = <String>[_validatorScript];
  if (release) args.add('--release-readiness');
  return Process.run(
    'dart',
    args,
    workingDirectory: workingDirectory,
    runInShell: false,
  );
}

Directory _createRenamedFixture(Directory repoRoot) {
  final fixture = Directory.systemTemp.createTempSync(
    'validate_template_test_',
  );
  final src = repoRoot.path;

  _copyFile(
    src,
    fixture.path,
    'pubspec.yaml',
    (c) => c.replaceFirst('name: flutter_starterkit', 'name: obrien_app'),
  );
  _copyFile(src, fixture.path, 'pubspec.lock');
  _copyFile(src, fixture.path, 'l10n.yaml');

  // Keep the validator fixture structurally valid while retaining its custom
  // main/test sources below for stale-import coverage.
  for (final path in [
    'lib/app/bootstrap/bootstrap.dart',
    'lib/app/sample_app.dart',
    'lib/app/routing/sample_router.dart',
    'lib/features/sample/application/sample_providers.dart',
    'lib/features/sample/data/in_memory_sample_repository.dart',
    'lib/features/sample/domain/sample_item.dart',
    'lib/features/sample/domain/sample_repository.dart',
    'lib/features/sample/presentation/sample_detail_page.dart',
    'lib/features/sample/presentation/sample_list_page.dart',
  ]) {
    _copyFile(
      src,
      fixture.path,
      path,
      (content) => content.replaceAll(
        'package:flutter_starterkit/',
        'package:obrien_app/',
      ),
    );
  }

  _copyFile(
    src,
    fixture.path,
    'lib/l10n/app_en.arb',
    (c) => c.replaceAll('"Flutter Starter Kit"', '"O\'Brien"'),
  );
  _copyFile(
    src,
    fixture.path,
    'lib/l10n/app_ko.arb',
    (c) => c.replaceAll('"Flutter Starter Kit"', '"O\'Brien"'),
  );

  _copyFile(
    src,
    fixture.path,
    'android/app/src/main/AndroidManifest.xml',
    (c) => c
        .replaceFirst(
          'android:label="Flutter Starter Kit"',
          'android:label="O\'Brien"',
        )
        .replaceFirst(
          'android:scheme="flutter-starterkit"',
          'android:scheme="obrien"',
        ),
  );

  _copyFile(
    src,
    fixture.path,
    'android/app/build.gradle.kts',
    (c) => c
        .replaceAll(
          'namespace = "com.example.flutterstarterkit"',
          'namespace = "com.obrien.obrienapp"',
        )
        .replaceAll(
          'applicationId = "com.example.flutterstarterkit"',
          'applicationId = "com.obrien.obrienapp"',
        ),
  );

  _copyFile(
    src,
    fixture.path,
    'ios/Runner/Info.plist',
    (c) => c
        .replaceFirst(
          '<string>Flutter Starter Kit</string>',
          '<string>O\'Brien</string>',
        )
        .replaceFirst(
          '<string>flutter_starterkit</string>',
          '<string>obrien_app</string>',
        )
        .replaceFirst(
          '<string>flutter-starterkit</string>',
          '<string>obrien</string>',
        ),
  );

  _copyFile(
    src,
    fixture.path,
    'ios/Runner.xcodeproj/project.pbxproj',
    (c) => c
        .replaceAll(
          'com.example.flutterstarterkit.RunnerTests;',
          'com.obrien.obrienapp.RunnerTests;',
        )
        .replaceAll('com.example.flutterstarterkit;', 'com.obrien.obrienapp;'),
  );

  // Minimal Dart sources using the new package name so stale-import detection
  // does not fire on the fixture itself.
  _writeFile(
    fixture,
    'lib/main.dart',
    "import 'package:obrien_app/app/sample_app.dart';\n"
        'final sampleAppType = SampleApp;\n',
  );
  _writeFile(
    fixture,
    'test/widget_test.dart',
    "import 'package:flutter_test/flutter_test.dart';\n"
        "import 'package:obrien_app/app/sample_app.dart';\n"
        "void main() { test('t', () {}); }\n",
  );

  final oldMainActivity = File(
    '$src/android/app/src/main/kotlin/com/example/flutterstarterkit/MainActivity.kt',
  );
  final newMainActivityDir = Directory(
    '${fixture.path}/android/app/src/main/kotlin/com/obrien/obrienapp',
  );
  newMainActivityDir.createSync(recursive: true);
  File('${newMainActivityDir.path}/MainActivity.kt').writeAsStringSync(
    oldMainActivity.readAsStringSync().replaceFirst(
      'package com.example.flutterstarterkit',
      'package com.obrien.obrienapp',
    ),
  );

  return fixture;
}

void _copyFile(
  String srcRoot,
  String destRoot,
  String relativePath, [
  String Function(String)? transform,
]) {
  final src = File('$srcRoot/$relativePath');
  final dest = File('$destRoot/$relativePath');
  dest.parent.createSync(recursive: true);
  var content = src.readAsStringSync();
  if (transform != null) content = transform(content);
  dest.writeAsStringSync(content);
}

void _writeFile(Directory root, String relativePath, String content) {
  final file = File('${root.path}/$relativePath');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}

void _addArbLocale(Directory fixture, String locale, {String? appTitle}) {
  var content = File('${fixture.path}/lib/l10n/app_en.arb')
      .readAsStringSync()
      .replaceFirst('"@@locale": "en"', '"@@locale": "$locale"');
  if (appTitle == null) {
    content = content.replaceFirst(
      RegExp(r'^\s*"appTitle":\s*"[^"]*",\n', multiLine: true),
      '',
    );
  } else {
    content = content.replaceFirst(
      '"appTitle": "O\'Brien"',
      '"appTitle": "$appTitle"',
    );
  }
  _writeFile(fixture, 'lib/l10n/app_$locale.arb', content);
}
