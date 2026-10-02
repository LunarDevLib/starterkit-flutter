import 'dart:convert';
import 'dart:io';

const _templatePackageName = 'flutter_starterkit';
const _templateAppName = 'Flutter Starter Kit';
const _templateBundleId = 'com.example.flutterstarterkit';
const _templateScheme = 'flutter-starterkit';

const _dartReservedWords = <String>{
  'assert',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'default',
  'do',
  'else',
  'enum',
  'extends',
  'false',
  'final',
  'finally',
  'for',
  'if',
  'in',
  'is',
  'new',
  'null',
  'rethrow',
  'return',
  'super',
  'switch',
  'this',
  'throw',
  'true',
  'try',
  'var',
  'void',
  'while',
  'with',
  'async',
  'await',
  'covariant',
  'deferrred',
  'dynamic',
  'export',
  'external',
  'factory',
  'function',
  'get',
  'implements',
  'import',
  'interface',
  'library',
  'mixin',
  'operator',
  'part',
  'set',
  'static',
  'sync',
  'yield',
};

const _kotlinJavaReservedWords = <String>{
  // Java keywords and literals.
  'abstract', 'assert', 'boolean', 'break', 'byte', 'case', 'catch', 'char',
  'class', 'const', 'continue', 'default', 'do', 'double', 'else', 'enum',
  'extends', 'false', 'final', 'finally', 'float', 'for', 'goto', 'if',
  'implements', 'import', 'instanceof', 'int', 'interface', 'long', 'native',
  'new', 'null', 'package', 'private', 'protected', 'public', 'return', 'short',
  'static', 'strictfp', 'super', 'switch', 'synchronized', 'this', 'throw',
  'throws', 'transient', 'try', 'true', 'void', 'volatile', 'while', '_',
  // Restricted Java identifiers are rejected as package segments as well.
  'exports', 'module', 'open', 'opens', 'permits', 'provides', 'record',
  'requires', 'sealed', 'to', 'transitive', 'uses', 'var', 'with', 'yield',
  // Kotlin hard keywords not already included above.
  'as', 'fun', 'in', 'is', 'object', 'typealias', 'typeof', 'val', 'when',
  // Kotlin contextual/soft keywords are also unsuitable package segments.
  'actual', 'by', 'companion', 'constructor', 'crossinline', 'data', 'expect',
  'external', 'field', 'file', 'get', 'init', 'inline', 'inner', 'internal',
  'it', 'lateinit', 'noinline', 'out', 'override', 'param', 'property',
  'receiver', 'reified', 'set', 'setparam', 'suspend', 'tailrec', 'where',
};

const _testFailureEnvironmentKey = 'BOOTSTRAP_PROJECT_TEST_FAIL_STAGE';
const _testFixtureMarker = '.bootstrap_project_test_fixture';

var _stageFileCounter = 0;

class _Options {
  _Options({
    required this.help,
    required this.dryRun,
    this.packageName,
    this.appName,
    this.bundleId,
    this.scheme,
  });

  final bool help;
  final bool dryRun;
  final String? packageName;
  final String? appName;
  final String? bundleId;
  final String? scheme;
}

class BootstrapException implements Exception {
  BootstrapException(this.message);
  final String message;
  @override
  String toString() => message;
}

_Options _parseArgs(List<String> args) {
  var help = false;
  var dryRun = false;
  String? packageName;
  String? appName;
  String? bundleId;
  String? scheme;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    String? value() {
      if (i + 1 >= args.length) {
        throw BootstrapException('Missing value for $arg');
      }
      return args[++i];
    }

    switch (arg) {
      case '--help' || '-h':
        if (help) throw BootstrapException('Duplicate option: $arg');
        help = true;
      case '--dry-run':
        if (dryRun) throw BootstrapException('Duplicate option: $arg');
        dryRun = true;
      case '--package-name':
        if (packageName != null) {
          throw BootstrapException('Duplicate option: $arg');
        }
        packageName = value();
      case '--app-name':
        if (appName != null) throw BootstrapException('Duplicate option: $arg');
        appName = value();
      case '--bundle-id':
        if (bundleId != null) {
          throw BootstrapException('Duplicate option: $arg');
        }
        bundleId = value();
      case '--scheme':
        if (scheme != null) throw BootstrapException('Duplicate option: $arg');
        scheme = value();
      default:
        throw BootstrapException('Unknown argument: $arg');
    }
  }

  return _Options(
    help: help,
    dryRun: dryRun,
    packageName: packageName,
    appName: appName,
    bundleId: bundleId,
    scheme: scheme,
  );
}

void _printUsage(IOSink sink) {
  sink.writeln(
    'Usage: dart tool/bootstrap_project.dart '
    '--package-name <name> --app-name <name> --bundle-id <id> --scheme <scheme> [--dry-run]',
  );
  sink.writeln('');
  sink.writeln('Replace template identity with product-specific values.');
  sink.writeln(
    'Run once with a single writer; concurrent filesystem changes can still race checks.',
  );
  sink.writeln('');
  sink.writeln('Options:');
  sink.writeln('  --package-name  Pub/package name (e.g. sample_app)');
  sink.writeln('  --app-name      Human-readable app name (e.g. "Sample App")');
  sink.writeln(
    '  --bundle-id     Reverse-domain bundle ID (e.g. dev.example.sampleapp)',
  );
  sink.writeln('  --scheme        Deep-link URL scheme (e.g. sample-app)');
  sink.writeln(
    '  --dry-run       Validate inputs and report planned changes without writing',
  );
  sink.writeln('  --help          Show this help');
}

void _validate(_Options options) {
  if (options.help) return;

  final missing = <String>[
    if (options.packageName == null) '--package-name',
    if (options.appName == null) '--app-name',
    if (options.bundleId == null) '--bundle-id',
    if (options.scheme == null) '--scheme',
  ];
  if (missing.isNotEmpty) {
    throw BootstrapException('Missing required options: ${missing.join(', ')}');
  }

  final packageName = options.packageName!;
  final appName = options.appName!;
  final bundleId = options.bundleId!;
  final scheme = options.scheme!;

  if (packageName.length > 30 ||
      !RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(packageName)) {
    throw BootstrapException(
      '--package-name must be lowercase, start with a letter, and contain only letters, digits, and underscores (max 30)',
    );
  }
  if (_dartReservedWords.contains(packageName)) {
    throw BootstrapException('--package-name must not be a Dart reserved word');
  }
  if (packageName == _templatePackageName) {
    throw BootstrapException(
      '--package-name must differ from the template name',
    );
  }
  if (packageName.contains(_templatePackageName)) {
    throw BootstrapException(
      '--package-name must not contain the template package name',
    );
  }

  if (appName.isEmpty || appName.trim().isEmpty) {
    throw BootstrapException('--app-name must not be empty');
  }
  if (!RegExp(r'^[\x20-\x7E]+$').hasMatch(appName)) {
    throw BootstrapException(
      '--app-name must be printable ASCII and must not contain control characters',
    );
  }
  const unsafe = r'<>{}&';
  for (final ch in unsafe.split('')) {
    if (appName.contains(ch)) {
      throw BootstrapException(
        '--app-name contains an unsupported character for XML/Dart escaping: $ch',
      );
    }
  }
  if (appName == _templateAppName) {
    throw BootstrapException('--app-name must differ from the template name');
  }
  if (appName.contains(_templateAppName)) {
    throw BootstrapException(
      '--app-name must not contain the template app name',
    );
  }

  if (!RegExp(r'^[a-z][a-z0-9]*(\.[a-z][a-z0-9]*)+$').hasMatch(bundleId)) {
    throw BootstrapException(
      '--bundle-id must be a reverse-domain identifier with lowercase segments (e.g. dev.example.sampleapp)',
    );
  }
  for (final segment in bundleId.split('.')) {
    if (_kotlinJavaReservedWords.contains(segment)) {
      throw BootstrapException(
        '--bundle-id segment "$segment" is a reserved Kotlin/Java keyword',
      );
    }
  }
  if (bundleId == _templateBundleId) {
    throw BootstrapException(
      '--bundle-id must differ from the template bundle ID',
    );
  }
  if (bundleId.contains(_templateBundleId)) {
    throw BootstrapException(
      '--bundle-id must not contain the template bundle ID',
    );
  }

  if (!RegExp(r'^[a-z][a-z0-9+.-]*$').hasMatch(scheme)) {
    throw BootstrapException(
      '--scheme must be a valid URL scheme starting with a letter (e.g. sample-app)',
    );
  }
  if (scheme == _templateScheme) {
    throw BootstrapException('--scheme must differ from the template scheme');
  }
  if (scheme.contains(_templateScheme)) {
    throw BootstrapException('--scheme must not contain the template scheme');
  }

  final values = {packageName, appName, bundleId, scheme};
  if (values.length != 4) {
    throw BootstrapException(
      'The four identity values must be distinct; got: ${values.toList()}',
    );
  }
}

String _escapeXmlAttr(String value) {
  return value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}

class _PlannedFile {
  _PlannedFile(this.file, this.originalBytes, this.original, this.next);
  final File file;
  final List<int> originalBytes;
  final String original;
  final String next;
}

class _PlannedMove {
  _PlannedMove(
    this.source,
    this.destination,
    this.originalBytes,
    this.originalContent,
    this.nextContent,
  );
  final File source;
  final File destination;
  final List<int> originalBytes;
  final String originalContent;
  final String nextContent;
}

class _StagedFile {
  _StagedFile({
    required this.target,
    required this.replacement,
    required this.backup,
    required this.expectedOriginalBytes,
    required this.replacementBytes,
  });

  final File target;
  final File replacement;
  final File backup;
  final List<int> expectedOriginalBytes;
  final List<int> replacementBytes;
}

class _StagedEdit extends _StagedFile {
  _StagedEdit(this.edit, File replacement, File backup)
    : super(
        target: edit.file,
        replacement: replacement,
        backup: backup,
        expectedOriginalBytes: edit.originalBytes,
        replacementBytes: utf8.encode(edit.next),
      );

  final _PlannedFile edit;
}

class _StagedMove extends _StagedFile {
  _StagedMove(this.move, File replacement, File backup)
    : super(
        target: move.source,
        replacement: replacement,
        backup: backup,
        expectedOriginalBytes: move.originalBytes,
        replacementBytes: utf8.encode(move.nextContent),
      );

  final _PlannedMove move;
}

class _Plan {
  _Plan({
    required this.packageName,
    required this.appName,
    required this.bundleId,
    required this.scheme,
    required this.dryRun,
    required this.edits,
    required this.moves,
  });

  final String packageName;
  final String appName;
  final String bundleId;
  final String scheme;
  final bool dryRun;
  final List<_PlannedFile> edits;
  final List<_PlannedMove> moves;
}

void _assertPlanPostconditions(_Plan plan, Directory root) {
  final oldPatterns = [
    _templatePackageName,
    _templateAppName,
    _templateBundleId,
    _templateScheme,
  ];
  for (final edit in plan.edits) {
    for (final pattern in oldPatterns) {
      if (edit.next.contains(pattern)) {
        throw BootstrapException(
          'Postcondition failed: planned edit for ${edit.file.path} still contains "$pattern"',
        );
      }
    }
  }
  for (final move in plan.moves) {
    for (final pattern in oldPatterns) {
      if (move.nextContent.contains(pattern)) {
        throw BootstrapException(
          'Postcondition failed: planned Kotlin move target still contains "$pattern"',
        );
      }
    }
  }

  // Ensure no managed Dart source still carries an old identity substring.
  final edited = <String, String>{
    for (final edit in plan.edits) edit.file.path: edit.next,
  };
  final dartFiles = <File>[
    ..._dartSources(root, 'lib'),
    ..._dartSources(
      root,
      'test',
    ).where((f) => !f.path.split(Platform.pathSeparator).contains('tool')),
  ];
  for (final file in dartFiles) {
    final content = edited[file.path] ?? file.readAsStringSync();
    for (final pattern in oldPatterns) {
      if (content.contains(pattern)) {
        throw BootstrapException(
          'Postcondition failed: ${file.path} still contains "$pattern"',
        );
      }
    }
  }
}

void _expectCount(String path, String content, String needle, int expected) {
  var count = 0;
  var start = 0;
  while (true) {
    final index = content.indexOf(needle, start);
    if (index == -1) break;
    count++;
    start = index + needle.length;
  }
  if (count != expected) {
    throw BootstrapException(
      'Anchor mismatch in $path: expected $expected occurrence(s) of "$needle", found $count',
    );
  }
}

List<File> _dartSources(Directory root, String dir) {
  final directory = Directory('${root.path}/$dir');
  _assertNoSymlinkInPath(root, directory.path);
  if (!directory.existsSync()) return <File>[];
  final files = <File>[];
  for (final entity in directory.listSync(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is Link) {
      throw BootstrapException('Symlink found in managed tree: ${entity.path}');
    }
    if (entity is! File) continue;
    if (!entity.path.endsWith('.dart')) continue;
    if (entity.path
        .split(Platform.pathSeparator)
        .any((s) => s == '.dart_tool')) {
      continue;
    }
    if (_isGeneratedLocalization(entity.path)) continue;
    _assertNoSymlinkInPath(root, entity.path);
    files.add(entity);
  }
  return files;
}

bool _isGeneratedLocalization(String path) {
  final parts = path.split(Platform.pathSeparator);
  final name = parts.isNotEmpty ? parts.last : '';
  return parts.contains('l10n') && name.startsWith('app_localizations');
}

void _assertNoSymlinkInPath(Directory root, String path) {
  if (FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.link) {
    throw BootstrapException('Symlink found in managed path: $path');
  }
  var current = Directory(path);
  while (current.path != root.path &&
      current.path.startsWith('${root.path}${Platform.pathSeparator}')) {
    if (FileSystemEntity.typeSync(current.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw BootstrapException('Symlink ancestor found: ${current.path}');
    }
    final parent = current.parent;
    if (parent.path == current.path) break;
    current = parent;
  }
}

_Plan _plan(Directory root, _Options options) {
  final edits = <_PlannedFile>[];
  _PlannedFile planFile(String relativePath, String Function(String) rewrite) {
    final file = File('${root.path}/$relativePath');
    if (!file.existsSync()) {
      throw BootstrapException('Required file missing: $relativePath');
    }
    _assertNoSymlinkInPath(root, file.path);
    final originalBytes = file.readAsBytesSync();
    final original = utf8.decode(originalBytes);
    final next = rewrite(original);
    final planned = _PlannedFile(file, originalBytes, original, next);
    edits.add(planned);
    return planned;
  }

  // pubspec.yaml
  planFile('pubspec.yaml', (content) {
    _expectCount('pubspec.yaml', content, 'name: $_templatePackageName', 1);
    return content.replaceFirst(
      'name: $_templatePackageName',
      'name: ${options.packageName}',
    );
  });

  // Dart imports in lib/ and test/
  final dartFiles = <File>[
    ..._dartSources(root, 'lib'),
    ..._dartSources(
      root,
      'test',
    ).where((f) => !f.path.split(Platform.pathSeparator).contains('tool')),
  ];
  const importNeedle = 'package:$_templatePackageName/';
  var importCount = 0;
  for (final file in dartFiles) {
    final originalBytes = file.readAsBytesSync();
    final original = utf8.decode(originalBytes);
    final count = importNeedle.allMatches(original).length;
    if (count > 0) {
      importCount += count;
      edits.add(
        _PlannedFile(
          file,
          originalBytes,
          original,
          original.replaceAll(importNeedle, 'package:${options.packageName}/'),
        ),
      );
    }
  }
  if (importCount == 0) {
    throw BootstrapException(
      'No package:$_templatePackageName/ imports found in lib/ or test/',
    );
  }

  // ARB appTitle
  for (final arb in ['lib/l10n/app_en.arb', 'lib/l10n/app_ko.arb']) {
    planFile(arb, (content) {
      _expectCount(arb, content, '"appTitle": "$_templateAppName"', 1);
      return content.replaceAll(
        '"appTitle": "$_templateAppName"',
        '"appTitle": ${jsonEncode(options.appName)}',
      );
    });
  }

  // Android build.gradle.kts
  planFile('android/app/build.gradle.kts', (content) {
    _expectCount('android/app/build.gradle.kts', content, _templateBundleId, 2);
    return content.replaceAll(_templateBundleId, options.bundleId!);
  });

  // AndroidManifest.xml
  planFile('android/app/src/main/AndroidManifest.xml', (content) {
    _expectCount(
      'android/app/src/main/AndroidManifest.xml',
      content,
      'android:label="$_templateAppName"',
      1,
    );
    _expectCount(
      'android/app/src/main/AndroidManifest.xml',
      content,
      'android:scheme="$_templateScheme"',
      1,
    );
    return content
        .replaceAll(
          'android:label="$_templateAppName"',
          'android:label="${_escapeXmlAttr(options.appName!)}"',
        )
        .replaceAll(
          'android:scheme="$_templateScheme"',
          'android:scheme="${options.scheme}"',
        );
  });

  // Kotlin MainActivity package + path
  final ktSource = File(
    '${root.path}/android/app/src/main/kotlin/${_templateBundleId.replaceAll('.', '/')}/MainActivity.kt',
  );
  if (!ktSource.existsSync()) {
    throw BootstrapException(
      'Kotlin MainActivity.kt not found at the template path',
    );
  }
  final ktOriginalBytes = ktSource.readAsBytesSync();
  final ktOriginal = utf8.decode(ktOriginalBytes);
  _expectCount(ktSource.path, ktOriginal, 'package $_templateBundleId', 1);
  final ktNext = ktOriginal.replaceAll(
    'package $_templateBundleId',
    'package ${options.bundleId}',
  );
  final ktDestination = File(
    '${root.path}/android/app/src/main/kotlin/${options.bundleId!.replaceAll('.', '/')}/MainActivity.kt',
  );

  // iOS Info.plist
  planFile('ios/Runner/Info.plist', (content) {
    _expectCount(
      'ios/Runner/Info.plist',
      content,
      '<string>$_templateAppName</string>',
      1,
    );
    _expectCount(
      'ios/Runner/Info.plist',
      content,
      '<string>$_templatePackageName</string>',
      1,
    );
    _expectCount(
      'ios/Runner/Info.plist',
      content,
      '<string>$_templateScheme</string>',
      1,
    );
    return content
        .replaceAll(
          '<string>$_templateAppName</string>',
          '<string>${_escapeXmlAttr(options.appName!)}</string>',
        )
        .replaceAll(
          '<string>$_templatePackageName</string>',
          '<string>${options.packageName}</string>',
        )
        .replaceAll(
          '<string>$_templateScheme</string>',
          '<string>${options.scheme}</string>',
        );
  });

  // Xcode project
  planFile('ios/Runner.xcodeproj/project.pbxproj', (content) {
    _expectCount(
      'ios/Runner.xcodeproj/project.pbxproj',
      content,
      _templateBundleId,
      6,
    );
    return content.replaceAll(_templateBundleId, options.bundleId!);
  });

  // Symlink and destination checks for Kotlin move
  _assertNoSymlinkInPath(Directory('${root.path}/android'), ktSource.path);
  _assertNoSymlinkInPath(Directory('${root.path}/android'), ktDestination.path);
  if (ktDestination.existsSync()) {
    throw BootstrapException(
      'Destination already exists: ${ktDestination.path}',
    );
  }
  final ktDestinationDir = ktDestination.parent;
  if (ktDestinationDir.existsSync() && ktDestinationDir.listSync().isNotEmpty) {
    throw BootstrapException(
      'Kotlin destination directory already contains files: ${ktDestinationDir.path}',
    );
  }

  final moves = <_PlannedMove>[
    _PlannedMove(ktSource, ktDestination, ktOriginalBytes, ktOriginal, ktNext),
  ];

  final plan = _Plan(
    packageName: options.packageName!,
    appName: options.appName!,
    bundleId: options.bundleId!,
    scheme: options.scheme!,
    dryRun: options.dryRun,
    edits: edits,
    moves: moves,
  );
  _assertPlanPostconditions(plan, root);
  return plan;
}

void _reportPlan(_Plan plan) {
  stdout.writeln('Dry run: the following changes would be made:');
  for (final edit in plan.edits) {
    stdout.writeln('  ${edit.file.path}');
  }
  for (final move in plan.moves) {
    stdout.writeln('  ${move.source.path} -> ${move.destination.path}');
  }
}

void _execute(_Plan plan, {String? testFailureStage}) {
  final stagedEdits = <_StagedEdit>[];
  final stagedMoves = <_StagedMove>[];
  final attemptedEdits = <_StagedEdit>[];
  final attemptedMoves = <_StagedMove>[];
  final createdDirectories = <Directory>[];

  try {
    // Prepare every replacement before changing any original file.
    for (final edit in plan.edits) {
      final replacement = _createSiblingStageFile(edit.file);
      final backup = File('${replacement.path}.original');
      if (FileSystemEntity.typeSync(backup.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        replacement.deleteSync();
        throw FileSystemException(
          'Staging backup path already exists',
          backup.path,
        );
      }
      final staged = _StagedEdit(edit, replacement, backup);
      stagedEdits.add(staged);
      replacement.writeAsStringSync(edit.next);
    }
    for (final move in plan.moves) {
      final replacement = _createSiblingStageFile(move.source);
      final backup = File('${replacement.path}.original');
      if (FileSystemEntity.typeSync(backup.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        replacement.deleteSync();
        throw FileSystemException(
          'Staging backup path already exists',
          backup.path,
        );
      }
      final staged = _StagedMove(move, replacement, backup);
      stagedMoves.add(staged);
      replacement.writeAsStringSync(move.nextContent);
    }

    for (var index = 0; index < stagedEdits.length; index++) {
      final staged = stagedEdits[index];
      if (testFailureStage == 'conflict-during-second-edit' && index == 1) {
        const userContent = '// bootstrap test user edit\n';
        stagedEdits.first.target.writeAsStringSync(userContent);
        staged.target.writeAsStringSync(userContent);
      }
      if (!_fileHasBytes(staged.target, staged.expectedOriginalBytes)) {
        throw BootstrapException(
          'Conflict: ${staged.target.path} changed since planning; refusing to overwrite it',
        );
      }

      // Record the attempt before the first filesystem mutation.
      attemptedEdits.add(staged);
      staged.target.renameSync(staged.backup.path);
      if (!_fileHasBytes(staged.backup, staged.expectedOriginalBytes)) {
        _restoreBackupIfTargetAbsent(staged);
        throw BootstrapException(
          'Conflict: ${staged.target.path} changed while being staged; refusing to install replacement',
        );
      }
      if (testFailureStage == 'after-first-edit-backup' &&
          attemptedEdits.length == 1) {
        throw BootstrapException(
          'Injected execution-phase failure after original backup',
        );
      }
      if (!_pathIsAbsent(staged.target.path)) {
        throw BootstrapException(
          'Conflict: ${staged.target.path} was occupied before replacement; preserving it',
        );
      }
      staged.replacement.renameSync(staged.target.path);
    }

    if (testFailureStage == 'occupy-kotlin-destination' &&
        stagedMoves.isNotEmpty) {
      final destination = stagedMoves.first.move.destination;
      if (!_pathIsAbsent(destination.path)) {
        throw BootstrapException('Test fixture destination was not absent');
      }
      final userFile = destination..createSync(exclusive: true);
      userFile.writeAsStringSync('// bootstrap test occupied destination\n');
    }

    for (final staged in stagedMoves) {
      if (!_pathIsAbsent(staged.move.destination.path)) {
        throw BootstrapException(
          'Conflict: Kotlin destination ${staged.move.destination.path} is occupied; preserving it',
        );
      }
      _createDirectoriesTracked(
        staged.move.destination.parent,
        createdDirectories,
      );
      if (!_pathIsAbsent(staged.move.destination.path)) {
        throw BootstrapException(
          'Conflict: Kotlin destination ${staged.move.destination.path} became occupied; preserving it',
        );
      }
      if (!_fileHasBytes(staged.target, staged.expectedOriginalBytes)) {
        throw BootstrapException(
          'Conflict: Kotlin source ${staged.target.path} changed since planning; refusing to move it',
        );
      }
      // Record the attempt before moving the original Kotlin source.
      attemptedMoves.add(staged);
      staged.target.renameSync(staged.backup.path);
      if (!_fileHasBytes(staged.backup, staged.expectedOriginalBytes)) {
        _restoreBackupIfTargetAbsent(staged);
        throw BootstrapException(
          'Conflict: Kotlin source ${staged.target.path} changed while being staged; refusing to install replacement',
        );
      }
      if (!_pathIsAbsent(staged.move.destination.path)) {
        throw BootstrapException(
          'Conflict: Kotlin destination ${staged.move.destination.path} became occupied; preserving it',
        );
      }
      staged.replacement.renameSync(staged.move.destination.path);
    }

    if (testFailureStage == 'after-kotlin-move' && stagedMoves.isNotEmpty) {
      throw BootstrapException(
        'Injected execution-phase failure after Kotlin move',
      );
    }

    _verifyNoResidue(plan);
  } catch (e) {
    stderr.writeln('ERROR during bootstrap: $e');
    stderr.writeln('Rolling back completed changes (best effort)...');
    for (final staged in attemptedMoves.reversed) {
      try {
        _rollbackMoveSafely(staged);
      } catch (rollbackError) {
        stderr.writeln(
          'Rollback failed for ${staged.move.destination.path}: $rollbackError',
        );
      }
    }
    for (final staged in attemptedEdits.reversed) {
      try {
        _rollbackFileSafely(staged);
      } catch (rollbackError) {
        stderr.writeln(
          'Rollback failed for ${staged.target.path}: $rollbackError',
        );
      }
    }
    _removeCreatedDirectories(createdDirectories);
    _cleanupStagedFiles([...stagedEdits, ...stagedMoves], deleteBackups: false);
    exitCode = 1;
    return;
  }

  _cleanupStagedFiles([...stagedEdits, ...stagedMoves]);
}

bool _fileHasBytes(File file, List<int> expected) {
  if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    return false;
  }
  try {
    return _bytesEqual(file.readAsBytesSync(), expected);
  } on FileSystemException {
    return false;
  }
}

bool _bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool _pathIsAbsent(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false) ==
    FileSystemEntityType.notFound;

void _restoreBackupIfTargetAbsent(_StagedFile staged) {
  if (_pathIsAbsent(staged.target.path) && staged.backup.existsSync()) {
    staged.backup.renameSync(staged.target.path);
  } else if (staged.backup.existsSync()) {
    stderr.writeln(
      'Manual reconciliation required: preserving conflicting target ${staged.target.path} and backup ${staged.backup.path}',
    );
  }
}

void _rollbackFileSafely(_StagedEdit staged) {
  if (!staged.backup.existsSync()) return;
  if (_pathIsAbsent(staged.target.path)) {
    staged.backup.renameSync(staged.target.path);
    return;
  }
  if (!_fileHasBytes(staged.target, staged.replacementBytes)) {
    stderr.writeln(
      'Manual reconciliation required: preserving conflicting target ${staged.target.path} and backup ${staged.backup.path}',
    );
    return;
  }
  if (!_fileHasBytes(staged.backup, staged.expectedOriginalBytes)) {
    stderr.writeln(
      'Manual reconciliation required: preserving changed backup ${staged.backup.path} and target ${staged.target.path}',
    );
    return;
  }
  staged.target.deleteSync();
  if (_pathIsAbsent(staged.target.path)) {
    staged.backup.renameSync(staged.target.path);
  } else {
    stderr.writeln(
      'Manual reconciliation required: target ${staged.target.path} became occupied; backup retained at ${staged.backup.path}',
    );
  }
}

void _rollbackMoveSafely(_StagedMove staged) {
  if (!staged.backup.existsSync()) return;
  final destination = staged.move.destination;
  if (!_pathIsAbsent(destination.path) &&
      !_fileHasBytes(destination, staged.replacementBytes)) {
    stderr.writeln(
      'Manual reconciliation required: preserving Kotlin destination ${destination.path} and backup ${staged.backup.path}',
    );
    return;
  }
  if (!_pathIsAbsent(staged.target.path)) {
    stderr.writeln(
      'Manual reconciliation required: preserving occupied Kotlin source ${staged.target.path} and backup ${staged.backup.path}',
    );
    return;
  }
  if (!_pathIsAbsent(destination.path)) destination.deleteSync();
  staged.backup.renameSync(staged.target.path);
}

File _createSiblingStageFile(File target) {
  final parent = target.parent;
  for (var attempt = 0; attempt < 100; attempt++) {
    final suffix =
        '${pid}_${DateTime.now().microsecondsSinceEpoch}_${_stageFileCounter++}';
    final file = File(
      '${parent.path}${Platform.pathSeparator}.bootstrap_project_stage_$suffix',
    );
    try {
      file.createSync(exclusive: true);
      return file;
    } on FileSystemException {
      if (!file.existsSync()) rethrow;
    }
  }
  throw FileSystemException('Could not allocate a staging file', target.path);
}

void _createDirectoriesTracked(Directory directory, List<Directory> created) {
  final missing = <Directory>[];
  var current = directory;
  while (!current.existsSync()) {
    missing.add(current);
    final parent = current.parent;
    if (parent.path == current.path) break;
    current = parent;
  }
  for (final item in missing.reversed) {
    try {
      item.createSync();
      created.add(item);
    } on FileSystemException {
      if (!item.existsSync()) rethrow;
    }
  }
}

void _removeCreatedDirectories(List<Directory> directories) {
  for (final directory in directories.reversed) {
    try {
      if (directory.existsSync() && directory.listSync().isEmpty) {
        directory.deleteSync();
      }
    } on FileSystemException catch (error) {
      stderr.writeln(
        'Rollback directory cleanup failed for ${directory.path}: $error',
      );
    }
  }
}

void _cleanupStagedFiles(
  List<_StagedFile> stagedFiles, {
  bool deleteBackups = true,
}) {
  for (final staged in stagedFiles) {
    final files = deleteBackups
        ? [staged.replacement, staged.backup]
        : [staged.replacement];
    for (final file in files) {
      try {
        if (file.existsSync()) file.deleteSync();
      } on FileSystemException catch (error) {
        stderr.writeln('Staging cleanup failed for ${file.path}: $error');
      }
    }
  }
}

String? _testFailureRequested(Directory root) {
  final stage = Platform.environment[_testFailureEnvironmentKey];
  if (stage != 'after-first-edit-backup' &&
      stage != 'after-kotlin-move' &&
      stage != 'conflict-during-second-edit' &&
      stage != 'occupy-kotlin-destination') {
    return null;
  }
  try {
    final rootPath = root.resolveSymbolicLinksSync();
    final tempPath = Directory.systemTemp.resolveSymbolicLinksSync();
    if (!rootPath.startsWith('$tempPath${Platform.pathSeparator}')) {
      return null;
    }
    final marker = File('${root.path}/$_testFixtureMarker');
    if (marker.existsSync() &&
        marker.readAsStringSync() == 'bootstrap-project-test-fixture') {
      return stage;
    }
    return null;
  } on FileSystemException {
    return null;
  }
}

void _verifyNoResidue(_Plan plan) {
  final root = plan.edits.first.file.parent;
  // Walk up to project root from any planned edit.
  var projectRoot = root;
  while (!File('${projectRoot.path}/pubspec.yaml').existsSync()) {
    final parent = projectRoot.parent;
    if (parent.path == projectRoot.path) break;
    projectRoot = parent;
  }

  final checks = <(String path, String needle, String label)>[
    ('pubspec.yaml', 'name: $_templatePackageName', 'pubspec name'),
    (
      'lib/l10n/app_en.arb',
      '"appTitle": "$_templateAppName"',
      'en ARB appTitle',
    ),
    (
      'lib/l10n/app_ko.arb',
      '"appTitle": "$_templateAppName"',
      'ko ARB appTitle',
    ),
    (
      'android/app/build.gradle.kts',
      _templateBundleId,
      'Android namespace/applicationId',
    ),
    (
      'android/app/src/main/AndroidManifest.xml',
      'android:label="$_templateAppName"',
      'Android manifest label',
    ),
    (
      'android/app/src/main/AndroidManifest.xml',
      'android:scheme="$_templateScheme"',
      'Android manifest scheme',
    ),
    (
      'ios/Runner/Info.plist',
      '<string>$_templateAppName</string>',
      'iOS display name',
    ),
    (
      'ios/Runner/Info.plist',
      '<string>$_templatePackageName</string>',
      'iOS bundle name',
    ),
    (
      'ios/Runner/Info.plist',
      '<string>$_templateScheme</string>',
      'iOS URL scheme',
    ),
    (
      'ios/Runner.xcodeproj/project.pbxproj',
      _templateBundleId,
      'iOS bundle identifiers',
    ),
  ];

  final stale = <String>[];
  for (final (relativePath, needle, label) in checks) {
    final file = File('${projectRoot.path}/$relativePath');
    if (file.existsSync() && file.readAsStringSync().contains(needle)) {
      stale.add(label);
    }
  }

  final dartFiles = <File>[
    ..._dartSources(projectRoot, 'lib'),
    ..._dartSources(
      projectRoot,
      'test',
    ).where((f) => !f.path.split(Platform.pathSeparator).contains('tool')),
  ];
  for (final file in dartFiles) {
    if (file.readAsStringSync().contains('package:$_templatePackageName/')) {
      stale.add('stale import in ${_relative(projectRoot, file)}');
    }
  }

  if (stale.isNotEmpty) {
    throw BootstrapException(
      'Bootstrap finished but template residue remains:\n  - ${stale.join('\n  - ')}',
    );
  }
}

String _relative(Directory root, File file) {
  return file.path.substring(root.path.length + 1);
}

void main(List<String> args) {
  final options = _parseArgs(args);
  if (options.help) {
    _printUsage(stdout);
    return;
  }

  try {
    _validate(options);
    final root = Directory.current;
    final plan = _plan(root, options);
    if (options.dryRun) {
      _reportPlan(plan);
      stdout.writeln('Dry run completed; no files were modified.');
      return;
    }
    _execute(plan, testFailureStage: _testFailureRequested(root));
    if (exitCode == 0) {
      stdout.writeln('Bootstrap completed:');
      stdout.writeln('  package name: ${plan.packageName}');
      stdout.writeln('  app name:     ${plan.appName}');
      stdout.writeln('  bundle id:    ${plan.bundleId}');
      stdout.writeln('  scheme:       ${plan.scheme}');
      stdout.writeln(
        '  Note: one-time single-writer operation; concurrent changes may race filesystem checks.',
      );
    }
  } on BootstrapException catch (e) {
    stderr.writeln('ERROR: ${e.message}');
    exitCode = 1;
  }
}
