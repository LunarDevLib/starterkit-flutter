import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final root = Directory.current;
  final release = args.contains('--release-readiness');
  final failures = <String>[];
  void requireFile(String path) {
    if (!File('${root.path}/$path').existsSync()) {
      failures.add('missing required artifact: $path');
    }
  }

  for (final path in [
    'pubspec.yaml',
    'pubspec.lock',
    'l10n.yaml',
    'lib/l10n/app_en.arb',
    'lib/l10n/app_ko.arb',
    'lib/main.dart',
    'lib/app/bootstrap/bootstrap.dart',
    'lib/app/sample_app.dart',
    'lib/app/routing/sample_router.dart',
    'lib/features/sample/application/sample_providers.dart',
    'lib/features/sample/data/in_memory_sample_repository.dart',
    'lib/features/sample/domain/sample_item.dart',
    'lib/features/sample/domain/sample_repository.dart',
    'lib/features/sample/presentation/sample_detail_page.dart',
    'lib/features/sample/presentation/sample_list_page.dart',
    'android/app/src/main/AndroidManifest.xml',
  ]) {
    requireFile(path);
  }

  final arbs = _loadArbs(root, failures);
  if (arbs.isNotEmpty) {
    final base = arbs.values.first.keys
        .where((k) => !k.startsWith('@'))
        .toSet();
    for (final entry in arbs.entries) {
      final keys = entry.value.keys.where((k) => !k.startsWith('@')).toSet();
      if (keys.difference(base).isNotEmpty ||
          base.difference(keys).isNotEmpty) {
        failures.add('ARB key parity mismatch: ${entry.key}');
      }
    }
    final placeholders = RegExp(r'\{(\w+)(?:,[^}]*)?\}');
    final expected = <String, Set<String>>{};
    for (final data in arbs.values) {
      for (final entry in data.entries) {
        if (!entry.key.startsWith('@') && entry.value is String) {
          expected.putIfAbsent(
            entry.key,
            () => placeholders
                .allMatches(entry.value as String)
                .map((m) => m.group(1)!)
                .toSet(),
          );
        }
      }
    }
    for (final data in arbs.values) {
      for (final entry in data.entries) {
        if (!entry.key.startsWith('@') &&
            entry.value is String &&
            expected[entry.key]!
                .difference(
                  placeholders
                      .allMatches(entry.value as String)
                      .map((m) => m.group(1)!)
                      .toSet(),
                )
                .isNotEmpty) {
          failures.add('placeholder mismatch: ${entry.key}');
        }
      }
    }
  }
  for (final file in _dartSources(root, 'lib')) {
    final content = file.readAsStringSync();
    for (final optionalPackage in const [
      'starterkit_webview',
      'starterkit_platform',
    ]) {
      if (content.contains('package:$optionalPackage/')) {
        failures.add(
          'default app must not import optional capability $optionalPackage: ${_relative(root, file)}',
        );
      }
    }
  }
  final pubspec = File('${root.path}/pubspec.yaml').readAsStringSync();
  final forbidden = RegExp(
    r'^\s{2}(firebase_|sentry|webview|geolocator|image_picker|camera|permission_handler|firebase_messaging)',
    multiLine: true,
  );
  if (forbidden.hasMatch(pubspec)) {
    failures.add('forbidden default integration/package is declared');
  }
  final manifest = File('${root.path}/android/app/src/main/AndroidManifest.xml')
      .readAsStringSync()
      .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
  final permissions = RegExp(r'<uses-permission[^>]+android:name="([^"]+)"')
      .allMatches(manifest)
      .map((m) => m.group(1))
      .toSet();
  if (permissions.isNotEmpty) {
    failures.add(
      'Android main manifest must not declare network or other permissions',
    );
  }
  if (!manifest.contains('android:allowBackup="false"')) {
    failures.add('Android application must disable backup');
  }
  if (release) {
    _checkReleaseReadiness(root, failures, pubspec, arbs);
  }
  if (failures.isEmpty) {
    stdout.writeln(
      'Template validation passed${release ? ' (release readiness)' : ''}.',
    );
  } else {
    for (final failure in failures) {
      stderr.writeln('ERROR: $failure');
    }
    exitCode = 1;
  }
}

Map<String, Map<String, dynamic>> _loadArbs(
  Directory root,
  List<String> failures,
) {
  final arbs = <String, Map<String, dynamic>>{};
  final dir = Directory('${root.path}/lib/l10n');
  if (!dir.existsSync()) return arbs;
  for (final file in dir.listSync().whereType<File>().where(
    (f) => f.path.endsWith('.arb'),
  )) {
    try {
      arbs[file.path] =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      failures.add('invalid ARB JSON: ${file.path}');
    }
  }
  return arbs;
}

List<File> _dartSources(Directory root, String dirName) {
  final dir = Directory('${root.path}/$dirName');
  if (!dir.existsSync()) return <File>[];
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .where(
        (f) =>
            f.path.endsWith('.dart') &&
            !f.path
                .split(Platform.pathSeparator)
                .any((s) => s == '.dart_tool') &&
            !_isGeneratedLocalization(f.path),
      )
      .toList();
}

bool _isGeneratedLocalization(String path) {
  final parts = path.split(Platform.pathSeparator);
  final name = parts.isNotEmpty ? parts.last : '';
  return parts.contains('l10n') && name.startsWith('app_localizations');
}

({String? value, int count}) _extractStringField(
  String content,
  RegExp pattern,
) {
  final matches = pattern.allMatches(content).toList();
  if (matches.isEmpty) return (value: null, count: 0);
  return (value: matches.first.group(1), count: matches.length);
}

String _unescapeXml(String value) {
  const named = {'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'"};
  return value.replaceAllMapped(
    RegExp(r'&(?:#(\d+)|#x([0-9a-fA-F]+)|([a-zA-Z][a-zA-Z0-9]*));'),
    (m) {
      if (m.group(1) != null) {
        final code = int.tryParse(m.group(1)!);
        if (code != null) return String.fromCharCode(code);
      } else if (m.group(2) != null) {
        final code = int.tryParse(m.group(2)!, radix: 16);
        if (code != null) return String.fromCharCode(code);
      } else if (m.group(3) != null) {
        final replacement = named[m.group(3)!];
        if (replacement != null) return replacement;
      }
      return m.group(0)!;
    },
  );
}

String _basename(String path) => path.split(Platform.pathSeparator).last;

void _checkReleaseReadiness(
  Directory root,
  List<String> failures,
  String pubspec,
  Map<String, Map<String, dynamic>> arbs,
) {
  // Pubspec package name
  final nameMatch = RegExp(
    r'^name:\s*(\S+)',
    multiLine: true,
  ).firstMatch(pubspec);
  final packageName = nameMatch?.group(1);
  if (packageName == null) {
    failures.add('pubspec.yaml missing name');
  } else if (packageName == 'flutter_starterkit') {
    failures.add('pubspec name is still the template default');
  }

  // Dart imports in lib/ and test/ (exclude tool tests/fixtures)
  for (final dirName in ['lib', 'test']) {
    for (final file in _dartSources(root, dirName)) {
      if (file.path.split(Platform.pathSeparator).contains('tool')) continue;
      final content = file.readAsStringSync();
      if (content.contains('package:flutter_starterkit/')) {
        failures.add(
          'stale package:flutter_starterkit/ import in ${_relative(root, file)}',
        );
      }
    }
  }

  final appTitles = <String>{};
  // ARB appTitle parity is independent of any removed config/provider layer.
  final baseArbNames = {'app_en.arb', 'app_ko.arb'};
  final seenArbNames = <String>[];
  String? baseAppTitle;
  for (final entry in arbs.entries) {
    final title = entry.value['appTitle'];
    final name = _basename(entry.key);
    seenArbNames.add(name);
    if (title == null) {
      failures.add('$name missing appTitle');
      continue;
    }
    if (title is! String) {
      failures.add('$name appTitle is not a string');
      continue;
    }
    appTitles.add(title);
    if (baseArbNames.contains(name)) {
      if (baseAppTitle == null) {
        baseAppTitle = title;
      } else if (baseAppTitle != title) {
        failures.add('ARB appTitle values are inconsistent across locales');
      }
    } else if (baseAppTitle != null && title != baseAppTitle) {
      failures.add('$name appTitle does not match base locale');
    }
  }
  for (final name in baseArbNames) {
    if (!seenArbNames.contains(name)) {
      failures.add('missing required ARB file: $name');
    }
  }
  if (appTitles.length > 1) {
    failures.add('ARB appTitle values are inconsistent across locales');
  }
  if (baseAppTitle == null) {
    failures.add('appTitle missing in one or more base ARB files');
  } else if (baseAppTitle == 'Flutter Starter Kit') {
    failures.add('ARB appTitle still uses the template default');
  }

  // Android identity
  final androidBuildFile = File('${root.path}/android/app/build.gradle.kts');
  String? androidApplicationId;
  String? androidNamespace;
  if (!androidBuildFile.existsSync()) {
    failures.add('android/app/build.gradle.kts missing');
  } else {
    final androidBuild = androidBuildFile.readAsStringSync();
    final namespace = _extractStringField(
      androidBuild,
      RegExp(r'namespace\s*=\s*"([^"]*)"'),
    );
    if (namespace.value == null) {
      failures.add('Android namespace missing');
    } else if (namespace.count > 1) {
      failures.add('Android namespace declared more than once');
    } else {
      androidNamespace = namespace.value;
    }

    final appId = _extractStringField(
      androidBuild,
      RegExp(r'applicationId\s*=\s*"([^"]*)"'),
    );
    if (appId.value == null) {
      failures.add('Android applicationId missing');
    } else if (appId.count > 1) {
      failures.add('Android applicationId declared more than once');
    } else {
      androidApplicationId = appId.value;
    }

    if (androidNamespace == 'com.example.flutterstarterkit') {
      failures.add('Android namespace is still the template default');
    }
    if (androidApplicationId == 'com.example.flutterstarterkit') {
      failures.add('Android applicationId is still the template default');
    }
    if (androidNamespace != null &&
        androidApplicationId != null &&
        androidNamespace != androidApplicationId) {
      failures.add('Android namespace and applicationId do not match');
    }
  }

  final manifestFile = File(
    '${root.path}/android/app/src/main/AndroidManifest.xml',
  );
  String? manifestLabel;
  String? manifestScheme;
  if (!manifestFile.existsSync()) {
    failures.add('android/app/src/main/AndroidManifest.xml missing');
  } else {
    final manifest = manifestFile.readAsStringSync().replaceAll(
      RegExp(r'<!--.*?-->', dotAll: true),
      '',
    );
    final label = _extractStringField(
      manifest,
      RegExp(r'android:label="([^"]*)"'),
    );
    if (label.value == null) {
      failures.add('Android manifest label missing');
    } else if (label.count > 1) {
      failures.add('Android manifest label declared more than once');
    } else {
      manifestLabel = _unescapeXml(label.value!);
    }

    final scheme = _extractStringField(
      manifest,
      RegExp(r'android:scheme="([^"]*)"'),
    );
    if (scheme.value == null) {
      failures.add('Android manifest deep-link scheme missing');
    } else if (scheme.count > 1) {
      failures.add('Android manifest deep-link scheme declared more than once');
    } else {
      manifestScheme = scheme.value;
    }

    if (manifestLabel == 'Flutter Starter Kit') {
      failures.add('Android manifest label is still the template default');
    }
    if (manifestScheme == 'flutter-starterkit') {
      failures.add(
        'Android manifest deep-link scheme is still the template default',
      );
    }
  }

  // Kotlin package and path
  if (androidNamespace != null) {
    final mainActivity = File(
      '${root.path}/android/app/src/main/kotlin/${androidNamespace.replaceAll('.', '/')}/MainActivity.kt',
    );
    if (!mainActivity.existsSync()) {
      failures.add(
        'Kotlin MainActivity.kt not found at expected path for Android namespace',
      );
    } else {
      final kotlinContent = mainActivity.readAsStringSync();
      final package = _extractStringField(
        kotlinContent,
        RegExp(r'^package\s+([^\s]+)', multiLine: true),
      );
      if (package.value == null) {
        failures.add('Kotlin package declaration missing');
      } else if (package.count > 1) {
        failures.add('Kotlin package declaration appears more than once');
      } else if (package.value != androidNamespace) {
        failures.add(
          'Kotlin package declaration does not match Android namespace',
        );
      }
    }
  }

  // iOS identity
  final infoPlistFile = File('${root.path}/ios/Runner/Info.plist');
  String? iosDisplayName;
  String? iosBundleName;
  String? iosScheme;
  if (!infoPlistFile.existsSync()) {
    failures.add('iOS Info.plist missing');
  } else {
    final infoPlist = infoPlistFile.readAsStringSync();
    final display = _extractStringField(
      infoPlist,
      RegExp(r'<key>CFBundleDisplayName</key>\s*<string>([^<]*)</string>'),
    );
    if (display.value == null) {
      failures.add('iOS Info.plist CFBundleDisplayName missing');
    } else if (display.count > 1) {
      failures.add(
        'iOS Info.plist CFBundleDisplayName declared more than once',
      );
    } else {
      iosDisplayName = _unescapeXml(display.value!);
    }

    final bundleName = _extractStringField(
      infoPlist,
      RegExp(r'<key>CFBundleName</key>\s*<string>([^<]*)</string>'),
    );
    if (bundleName.value == null) {
      failures.add('iOS Info.plist CFBundleName missing');
    } else if (bundleName.count > 1) {
      failures.add('iOS Info.plist CFBundleName declared more than once');
    } else {
      iosBundleName = _unescapeXml(bundleName.value!);
    }

    final scheme = _extractStringField(
      infoPlist,
      RegExp(
        r'<key>CFBundleURLSchemes</key>\s*<array>\s*<string>([^<]*)</string>',
      ),
    );
    if (scheme.value == null) {
      failures.add('iOS Info.plist CFBundleURLSchemes missing');
    } else if (scheme.count > 1) {
      failures.add('iOS Info.plist CFBundleURLSchemes declared more than once');
    } else {
      iosScheme = _unescapeXml(scheme.value!);
    }

    if (iosDisplayName == 'Flutter Starter Kit') {
      failures.add('iOS Info.plist display name is still the template default');
    }
    if (iosBundleName == 'flutter_starterkit') {
      failures.add('iOS Info.plist bundle name is still the template default');
    }
    if (iosScheme == 'flutter-starterkit') {
      failures.add('iOS URL scheme is still the template default');
    }
    if (packageName != null &&
        iosBundleName != null &&
        iosBundleName != packageName) {
      failures.add(
        'iOS Info.plist CFBundleName ($iosBundleName) does not match pubspec name ($packageName)',
      );
    }
  }

  // Xcode bundle identifiers
  final pbxprojFile = File('${root.path}/ios/Runner.xcodeproj/project.pbxproj');
  String? iosBaseBundleId;
  if (!pbxprojFile.existsSync()) {
    failures.add('iOS project.pbxproj missing');
  } else {
    final pbxproj = pbxprojFile.readAsStringSync();
    final bundleIds = RegExp(r'PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);')
        .allMatches(pbxproj)
        .map((m) => m.group(1)!)
        .toList();
    final appIds = bundleIds
        .where((id) => !id.endsWith('.RunnerTests'))
        .toList();
    final testIds = bundleIds
        .where((id) => id.endsWith('.RunnerTests'))
        .toList();

    if (appIds.length != 3) {
      failures.add(
        'iOS app bundle identifier expected exactly 3 occurrences, found ${appIds.length}',
      );
    }
    if (testIds.length != 3) {
      failures.add(
        'iOS test bundle identifier expected exactly 3 occurrences, found ${testIds.length}',
      );
    }
    if (appIds.contains('com.example.flutterstarterkit')) {
      failures.add('iOS app bundle identifier is still the template default');
    }
    if (testIds.contains('com.example.flutterstarterkit.RunnerTests')) {
      failures.add('iOS test bundle identifier is still the template default');
    }
    if (appIds.toSet().length > 1) {
      failures.add(
        'iOS app bundle identifiers are inconsistent across build configurations',
      );
    }
    if (testIds.toSet().length > 1) {
      failures.add(
        'iOS test bundle identifiers are inconsistent across build configurations',
      );
    }
    if (appIds.isNotEmpty) {
      iosBaseBundleId = appIds.first;
      final expectedTestId = '$iosBaseBundleId.RunnerTests';
      if (testIds.isNotEmpty && testIds.any((id) => id != expectedTestId)) {
        failures.add(
          'iOS test bundle identifiers do not match app bundle identifier ($expectedTestId)',
        );
      }
    }
  }

  // Cross-platform consistency
  if (androidApplicationId != null &&
      iosBaseBundleId != null &&
      androidApplicationId != iosBaseBundleId) {
    failures.add(
      'Android applicationId ($androidApplicationId) does not match iOS base bundle ID ($iosBaseBundleId)',
    );
  }
  if (manifestScheme != null &&
      iosScheme != null &&
      manifestScheme != iosScheme) {
    failures.add(
      'Android deep-link scheme ($manifestScheme) does not match iOS URL scheme ($iosScheme)',
    );
  }

  // Native display names must match the localized app title.
  final displayNameSources = <String, String>{};
  void trackDisplayName(String? value, String source) {
    if (value == null) return;
    displayNameSources[value] = source;
  }

  for (final title in appTitles) {
    trackDisplayName(title, 'ARB appTitle');
  }
  trackDisplayName(manifestLabel, 'Android manifest label');
  trackDisplayName(iosDisplayName, 'iOS Info.plist CFBundleDisplayName');

  if (displayNameSources.length > 1) {
    failures.add(
      'native display names drift: ${displayNameSources.entries.map((e) => '${e.key} (${e.value})').join(', ')}',
    );
  }
  if (baseAppTitle != null &&
      manifestLabel != null &&
      manifestLabel != baseAppTitle) {
    failures.add('Android manifest label does not match ARB appTitle');
  }
  if (baseAppTitle != null &&
      iosDisplayName != null &&
      iosDisplayName != baseAppTitle) {
    failures.add('iOS display name does not match ARB appTitle');
  }
}

String _relative(Directory root, File file) {
  return file.path.substring(root.path.length + 1);
}
