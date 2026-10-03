import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _workflowJob(String source, String name) {
  final match = RegExp(
    '^  ${RegExp.escape(name)}:\\n'
    r'.*?(?=^  [\w-]+:|(?![\s\S]))',
    multiLine: true,
    dotAll: true,
  ).firstMatch(source);
  if (match == null) throw StateError('Missing workflow job: $name');
  return match.group(0)!;
}

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
    final iosJob = _workflowJob(source, 'ios-simulator');
    final swiftJob = _workflowJob(source, 'swift-policy');
    expect(iosJob, contains('runs-on: macos-latest'));
    expect(
      'swift test --package-path packages/starterkit_preferences/ios'
          .allMatches('$swiftJob$iosJob')
          .length,
      2,
    );
    expect(iosJob, contains('flutter gen-l10n'));
    expect(iosJob, contains('dart run tool/validate_template.dart'));
    expect(iosJob, contains('flutter build ios --simulator --no-codesign'));
    expect(iosJob, contains('flutter build ios --release --no-codesign'));
    expect(
      iosJob.indexOf('flutter analyze\n'),
      lessThan(iosJob.indexOf('flutter build ios --simulator --no-codesign')),
    );
    final renamedStart = iosJob.indexOf(
      'Bootstrap fresh copy and iOS simulator build',
    );
    final renamedBuild = iosJob.indexOf(
      'flutter build ios --simulator --no-codesign',
      renamedStart,
    );
    expect(renamedStart, isNonNegative);
    expect(
      iosJob.indexOf(
        'dart run tool/validate_template.dart --release-readiness',
        renamedStart,
      ),
      lessThan(renamedBuild),
    );
    expect(
      iosJob.indexOf('flutter analyze', renamedStart),
      lessThan(renamedBuild),
    );
    expect(
      iosJob.indexOf('flutter test --exclude-tags template-only', renamedStart),
      lessThan(renamedBuild),
    );
    final sourceStart = iosJob.indexOf(
      'name: Validate source and compile iOS targets',
    );
    expect(sourceStart, isNonNegative);
    expect(renamedStart, greaterThan(sourceStart));
    for (final (checks, testCommand) in [
      (iosJob.substring(sourceStart, renamedStart), 'flutter test\n'),
      (
        iosJob.substring(renamedStart),
        'flutter test --exclude-tags template-only',
      ),
    ]) {
      final build = checks.indexOf(
        'flutter build ios --simulator --no-codesign',
      );
      expect(build, isNonNegative);
      for (final command in [
        'flutter pub get --enforce-lockfile',
        'flutter gen-l10n',
        'dart run tool/validate_template.dart',
        'dart format --output=none --set-exit-if-changed',
        'flutter analyze\n',
        testCommand,
        'python3 -m unittest discover -s test/tool',
      ]) {
        final check = checks.indexOf(command);
        expect(check, isNonNegative, reason: command);
        expect(check, lessThan(build), reason: command);
      }
    }
  });

  test('Swift policy is an independent fast gate for iOS CI', () {
    expect(source, contains('  push:\n    branches: [main]'));
    expect(source, contains('  pull_request:\n  workflow_dispatch:'));

    final swiftStart = source.indexOf('  swift-policy:');
    final iosStart = source.indexOf('  ios-simulator:');
    expect(swiftStart, isNonNegative);
    expect(iosStart, greaterThan(swiftStart));
    final swiftJob = _workflowJob(source, 'swift-policy');
    for (final package in [
      'starterkit_preferences',
      'starterkit_webview',
      'starterkit_platform',
      'starterkit_qr_barcode',
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

    final iosJob = _workflowJob(source, 'ios-simulator');
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
    final iosJob = _workflowJob(source, 'ios-simulator');
    final sourceJob = iosJob.indexOf(
      'name: Validate source and compile iOS targets',
    );
    final renamedJob = iosJob.indexOf(
      'name: Bootstrap fresh copy and iOS simulator build',
    );
    expect(sourceJob, isNonNegative);
    expect(renamedJob, greaterThan(sourceJob));
    final sourceLane = iosJob.substring(sourceJob, renamedJob);
    final renamedLane = iosJob.substring(renamedJob);

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

  test(
    'QR opt-in iOS gate is separate and depends on verified baseline jobs',
    () {
      final qrJob = _workflowJob(source, 'qr-opt-in-ios');
      expect(qrJob, contains('runs-on: macos-latest'));
      expect(qrJob, contains('needs: [verify, swift-policy, ios-simulator]'));
      expect(qrJob, contains("needs.verify.outputs.is_template == 'true'"));
      expect(qrJob, contains("needs.swift-policy.result == 'success'"));
      expect(qrJob, contains("needs.ios-simulator.result == 'success'"));
      expect(qrJob, contains('dart run tool/validate_template.dart'));
      expect(
        qrJob,
        contains('dart run tool/validate_template.dart --release-readiness'),
      );
      expect(
        qrJob,
        contains(
          'flutter analyze --no-pub test/tool/fixtures/qr_consumer/main.dart',
        ),
      );
      expect(
        '--target test/tool/fixtures/qr_consumer/main.dart'.allMatches(qrJob),
        hasLength(4),
      );
      expect(qrJob, contains('flutter build ios --simulator --no-codesign'));
      expect(qrJob, contains('flutter build ios --release --no-codesign'));
    },
  );
}
