import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('.github/workflows/flutter.yml').readAsStringSync();

  test('CI pins Flutter and formats only owned Dart source paths', () {
    expect(source, contains("flutter-version: '3.47.4'"));
    expect(source, contains('dart format --output=none --set-exit-if-changed'));
    expect(source, contains('packages/starterkit_connectivity/lib'));
    expect(source, contains('packages/starterkit_connectivity/test'));
    expect(source, contains('packages/starterkit_preferences/lib'));
    expect(source, contains('packages/starterkit_preferences/test'));
  });

  test('source and renamed consumer resolve and test the locked plugin', () {
    expect(source, contains('flutter pub get --enforce-lockfile'));
    expect(
      source,
      contains('working-directory: packages/starterkit_connectivity'),
    );
    expect(source, contains('flutter analyze --no-pub'));
    expect(source, contains('flutter test --no-pub'));
    expect(
      source,
      contains('working-directory: packages/starterkit_preferences'),
    );
    expect(source, contains('Resolve locked preferences package'));
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
      expect(
        source,
        contains(':app:dependencies --configuration "\$configuration"'),
      );
      expect(source, contains('./android/gradlew --project-dir android'));
      expect(source, contains('debugRuntimeClasspath releaseRuntimeClasspath'));
      expect(source, contains('if "\$apkanalyzer" manifest print "\$apk"'));
      expect(source, contains('if-no-files-found: warn'));
      expect(
        source,
        contains(
          'run: ./android/gradlew --project-dir android :starterkit_preferences:testDebugUnitTest',
        ),
      );
      expect(
        './android/gradlew --project-dir android :starterkit_preferences:testDebugUnitTest'
            .allMatches(source)
            .length,
        2,
      );
      expect(
        source,
        contains('build/app/outputs/flutter-apk/manifest-diagnostics/'),
      );
      expect(source, contains('build/ci-android-diagnostics/'));
      expect(source, isNot(contains('continue-on-error:')));

      final sourceDebugBuild = source.indexOf('id: android-debug-apk');
      final sourceFirstGradle = source.indexOf('./android/gradlew');
      final sourceReleaseBuild = source.indexOf(
        'id: android-release-apk',
        sourceDebugBuild,
      );
      final sourceManifestDump = source.indexOf(
        'name: Capture Android APK manifest XML',
        sourceReleaseBuild,
      );
      final sourceDebugGate = source.indexOf(
        'name: Verify debug APK Android baseline',
        sourceManifestDump,
      );
      final sourceReleaseGate = source.indexOf(
        'name: Verify release APK Android baseline',
        sourceDebugGate,
      );
      expect(sourceDebugBuild, isNonNegative);
      expect(sourceDebugBuild, lessThan(sourceFirstGradle));
      expect(sourceReleaseBuild, greaterThan(sourceDebugBuild));
      expect(sourceManifestDump, greaterThan(sourceReleaseBuild));
      expect(sourceDebugGate, greaterThan(sourceManifestDump));
      expect(sourceReleaseGate, greaterThan(sourceDebugGate));

      final renamedJob = source.indexOf('  renamed-copy:');
      final renamedDebugBuild = source.indexOf(
        'id: renamed-android-debug-apk',
        renamedJob,
      );
      final renamedFirstGradle = source.indexOf(
        './android/gradlew',
        renamedJob,
      );
      final renamedReleaseBuild = source.indexOf(
        'id: renamed-android-release-apk',
        renamedDebugBuild,
      );
      final renamedManifestDump = source.indexOf(
        'name: Capture renamed APK manifest XML',
        renamedReleaseBuild,
      );
      final renamedDebugGate = source.indexOf(
        'name: Verify renamed debug APK Android baseline',
        renamedManifestDump,
      );
      final renamedReleaseGate = source.indexOf(
        'name: Verify renamed release APK Android baseline',
        renamedDebugGate,
      );
      expect(renamedDebugBuild, greaterThan(renamedJob));
      expect(renamedDebugBuild, lessThan(renamedFirstGradle));
      expect(renamedReleaseBuild, greaterThan(renamedDebugBuild));
      expect(renamedManifestDump, greaterThan(renamedReleaseBuild));
      expect(renamedDebugGate, greaterThan(renamedManifestDump));
      expect(renamedReleaseGate, greaterThan(renamedDebugGate));
    },
  );

  test('macOS runs full source/renamed checks before unsigned iOS builds', () {
    expect(source, contains('runs-on: macos-latest'));
    expect(
      'swift test --package-path packages/starterkit_preferences/ios'
          .allMatches(source)
          .length,
      2,
    );
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

  test('Swift policy is an independent fast gate for iOS CI', () {
    expect(source, contains('  push:\n    branches: [main]'));
    expect(source, contains('  pull_request:\n  workflow_dispatch:'));

    final swiftStart = source.indexOf('  swift-policy:');
    final iosStart = source.indexOf('  ios-simulator:');
    expect(swiftStart, isNonNegative);
    expect(iosStart, greaterThan(swiftStart));
    final swiftJob = source.substring(swiftStart, iosStart);
    for (final package in [
      'starterkit_preferences',
      'starterkit_webview',
      'starterkit_platform',
    ]) {
      expect(
        swiftJob,
        contains('swift test --package-path packages/$package/ios'),
      );
    }
    expect(swiftJob, contains('runs-on: macos-latest'));
    expect(swiftJob, contains('actions/checkout@v4'));
    expect(swiftJob, isNot(contains('needs:')));
    expect(swiftJob, isNot(contains('flutter')));

    final iosJob = source.substring(iosStart);
    expect(iosJob, contains('needs: [verify, swift-policy]'));
    expect(
      iosJob,
      contains(
        "needs.verify.outputs.is_template != '' && needs.swift-policy.result == 'success'",
      ),
    );
    expect(iosJob, contains('Bootstrap fresh copy and iOS simulator build'));
    expect(iosJob, contains('flutter build ios --simulator --no-codesign'));
    expect(iosJob, contains('ios-built-plists-source'));
    expect(iosJob, contains('ios-built-plists-renamed'));

    final sourceStart = iosJob.indexOf(
      'name: Validate source and compile iOS targets',
    );
    final renamedStart = iosJob.indexOf(
      'name: Bootstrap fresh copy and iOS simulator build',
    );
    expect(sourceStart, isNonNegative);
    expect(renamedStart, greaterThan(sourceStart));
    final sourceChecks = iosJob.substring(sourceStart, renamedStart);
    final renamedChecks = iosJob.substring(renamedStart);
    final renamedBuild = renamedChecks.indexOf(
      'flutter build ios --simulator --no-codesign',
    );
    expect(renamedBuild, isNonNegative);
    for (final package in [
      'starterkit_preferences',
      'starterkit_webview',
      'starterkit_platform',
    ]) {
      final command = 'swift test --package-path packages/$package/ios';
      expect(sourceChecks, isNot(contains(command)));
      expect(command.allMatches(renamedChecks), hasLength(1));
      expect(renamedChecks.indexOf(command), lessThan(renamedBuild));
    }

    final iosBaselineCommands = iosJob
        .split('\n')
        .where((line) => line.contains('python3 tool/verify_ios_baseline.py'))
        .toList();
    expect(iosBaselineCommands, hasLength(4));
    expect(
      iosBaselineCommands.where((line) => line.contains('--variant debug')),
      hasLength(2),
    );
    expect(
      iosBaselineCommands.where((line) => line.contains('--variant release')),
      hasLength(2),
    );
  });

  test('iOS plist gate derives source identity and pins renamed identity', () {
    final sourceJob = source.indexOf(
      'name: Validate source and compile iOS targets',
    );
    final renamedJob = source.indexOf(
      'name: Bootstrap fresh copy and iOS simulator build',
    );
    expect(sourceJob, isNonNegative);
    expect(renamedJob, greaterThan(sourceJob));
    final sourceLane = source.substring(sourceJob, renamedJob);
    final renamedLane = source.substring(renamedJob);

    expect(sourceLane, contains('source_bundle_id_assertion=()'));
    expect(
      RegExp(
        r'if \[ "\$IS_TEMPLATE" = "true" \]; then\s+'
        r'source_bundle_id_assertion=\(--bundle-id '
        r'[a-z][a-z0-9]*(?:\.[a-z][a-z0-9]*)+\)\s+fi',
      ).hasMatch(sourceLane),
      isTrue,
    );
    final sourceGates = sourceLane
        .split('\n')
        .where((line) => line.contains('python3 tool/verify_ios_baseline.py'))
        .toList();
    expect(sourceGates, hasLength(2));
    for (final gate in sourceGates) {
      expect(
        gate,
        contains('--xcode-project ios/Runner.xcodeproj/project.pbxproj'),
      );
      expect(gate, contains('--minimum-os-version 15.0'));
      expect(gate, contains(r'"${source_bundle_id_assertion[@]}"'));
      expect(RegExp(r'--bundle-id(?:\s|=)').hasMatch(gate), isFalse);
    }
    expect(
      renamedLane,
      contains(
        '--bundle-id dev.example.sampleportable --minimum-os-version 15.0',
      ),
    );
    expect(renamedLane, isNot(contains('--xcode-project')));
  });
}
