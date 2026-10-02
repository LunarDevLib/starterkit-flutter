import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('.github/workflows/flutter.yml').readAsStringSync();

  test('CI pins Flutter and formats only owned Dart source paths', () {
    expect(source, contains("flutter-version: '3.47.4'"));
    expect(source, contains('dart format --output=none --set-exit-if-changed'));
    expect(source, contains('packages/starterkit_connectivity/lib'));
    expect(source, contains('packages/starterkit_connectivity/test'));
  });

  test('source and renamed consumer resolve and test the locked plugin', () {
    expect(source, contains('flutter pub get --enforce-lockfile'));
    expect(
      source,
      contains('working-directory: packages/starterkit_connectivity'),
    );
    expect(source, contains('flutter analyze --no-pub'));
    expect(source, contains('flutter test --no-pub'));
    expect(source, contains('python3 -m unittest discover -s test/tool'));
    expect(source, contains("flutter test --exclude-tags template-only"));
  });

  test(
    'Android source and renamed APKs receive actual manifest verification',
    () {
      expect(source, contains('flutter build apk --debug'));
      expect(source, contains('flutter build apk --release'));
      expect(source, contains('tool/verify_android_baseline.py'));
      expect(source, contains('--variant debug'));
      expect(source, contains('--variant release'));
      expect(source, contains('android-apks-source'));
      expect(source, contains('android-apks-renamed'));
    },
  );

  test('macOS runs full source/renamed checks before unsigned iOS builds', () {
    expect(source, contains('runs-on: macos-latest'));
    expect(source, contains('flutter gen-l10n'));
    expect(source, contains('dart run tool/validate_template.dart'));
    expect(source, contains('flutter build ios --simulator --no-codesign'));
    expect(source, contains('flutter build ios --release --no-codesign'));
    expect(
      source.indexOf(
        'flutter analyze\n',
        source.indexOf('runs-on: macos-latest'),
      ),
      lessThan(
        source.indexOf(
          'flutter build ios --simulator --no-codesign',
          source.indexOf('runs-on: macos-latest'),
        ),
      ),
    );
    final renamedStart = source.indexOf(
      'Bootstrap fresh copy and iOS simulator build',
    );
    final renamedBuild = source.indexOf(
      'flutter build ios --simulator --no-codesign',
      renamedStart,
    );
    expect(renamedStart, isNonNegative);
    expect(
      source.indexOf(
        'dart run tool/validate_template.dart --release-readiness',
        renamedStart,
      ),
      lessThan(renamedBuild),
    );
    expect(
      source.indexOf('flutter analyze', renamedStart),
      lessThan(renamedBuild),
    );
    expect(
      source.indexOf('flutter test --exclude-tags template-only', renamedStart),
      lessThan(renamedBuild),
    );
  });
}
