import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../failure/app_failure.dart';
import 'stores.dart';

typedef LogoutMarkerRename = void Function(File staged, String destination);

/// A single-writer, single-isolate logout marker in an existing app-private
/// directory. It guarantees ordinary process-restart persistence after the
/// flushed same-filesystem rename completes, not parent-directory fsync or
/// abrupt-power-loss durability. Directory confinement is not a defense
/// against a hostile process with the same UID racing path operations.
final class FileLogoutIntentStore implements LogoutIntentStore {
  factory FileLogoutIntentStore({
    required Directory directory,
    @visibleForTesting LogoutMarkerRename? renameStageForTesting,
  }) => FileLogoutIntentStore._(directory, renameStageForTesting);

  FileLogoutIntentStore._(this._directory, this._renameStageForTesting);

  static const String markerFileName = '.starterkit_logout_intent_v1';
  static const String _markerContents = 'starterkit-logout-intent.v1\n';
  static final Uint8List _markerBytes = Uint8List.fromList(
    _markerContents.codeUnits,
  );
  static int _stageCounter = 0;

  final Directory _directory;
  final LogoutMarkerRename? _renameStageForTesting;

  @override
  Future<bool> readPending() async {
    try {
      final root = _validateDirectory();
      final marker = File('$root${Platform.pathSeparator}$markerFileName');
      final markerType = FileSystemEntity.typeSync(
        marker.path,
        followLinks: false,
      );
      if (markerType == FileSystemEntityType.notFound) return false;
      if (markerType != FileSystemEntityType.file) {
        throw _invalidMarker();
      }

      final handle = await marker.open(mode: FileMode.read);
      late final Uint8List bytes;
      try {
        bytes = await handle.read(_markerBytes.length + 1);
      } finally {
        await handle.close();
      }
      if (!_sameBytes(bytes, _markerBytes)) throw _invalidMarker();
      return true;
    } on AppFailure {
      rethrow;
    } on Object catch (error) {
      throw _mapFileError(error);
    }
  }

  @override
  Future<void> markPending() async {
    File? staged;
    RandomAccessFile? handle;
    try {
      final root = _validateDirectory();
      final markerPath = '$root${Platform.pathSeparator}$markerFileName';
      _validateReplaceableMarker(markerPath);
      staged = _createStage(root);
      handle = staged.openSync(mode: FileMode.write);
      handle.writeFromSync(_markerBytes);
      handle.flushSync();
      handle.closeSync();
      handle = null;

      if (_validateDirectory() != root) throw _invalidMarker();
      _validateReplaceableMarker(markerPath);
      final rename = _renameStageForTesting;
      if (rename == null) {
        staged.renameSync(markerPath);
      } else {
        rename(staged, markerPath);
      }
      staged = null;
    } on AppFailure {
      rethrow;
    } on Object catch (error) {
      throw _mapFileError(error);
    } finally {
      if (handle != null) {
        try {
          handle.closeSync();
        } on Object {
          // Preserve the primary operation failure.
        }
      }
      _cleanupOwnedStage(staged);
    }
  }

  @override
  Future<void> clear() async {
    try {
      final root = _validateDirectory();
      final marker = File('$root${Platform.pathSeparator}$markerFileName');
      final type = FileSystemEntity.typeSync(marker.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) return;
      if (type != FileSystemEntityType.file) throw _invalidMarker();
      try {
        await marker.delete();
      } on FileSystemException {
        if (FileSystemEntity.typeSync(marker.path, followLinks: false) ==
            FileSystemEntityType.notFound) {
          return;
        }
        rethrow;
      }
    } on AppFailure {
      rethrow;
    } on Object catch (error) {
      throw _mapFileError(error);
    }
  }

  String _validateDirectory() {
    final absolute = _directory.absolute.path;
    final separator = Platform.pathSeparator;
    final isRooted = absolute.startsWith(separator);
    final parts = absolute
        .split(separator)
        .where((part) => part.isNotEmpty && part != '.')
        .toList();
    if (parts.isEmpty) throw _invalidMarker();

    var current = Directory(isRooted ? separator : parts.first);
    final segments = isRooted ? parts : parts.skip(1).toList();
    if (!isRooted && parts.length == 1) {
      current = Directory(parts.first);
    }
    for (var index = 0; index < segments.length; index++) {
      current = Directory(
        current.path == separator
            ? '${current.path}${segments[index]}'
            : '${current.path}$separator${segments[index]}',
      );
      final type = FileSystemEntity.typeSync(current.path, followLinks: false);
      if (type == FileSystemEntityType.link ||
          type == FileSystemEntityType.notFound ||
          (index < segments.length - 1 &&
              type != FileSystemEntityType.directory)) {
        throw _invalidMarker();
      }
    }
    if (FileSystemEntity.typeSync(current.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw _invalidMarker();
    }
    final canonical = _directory.resolveSymbolicLinksSync();
    if (canonical != absolute) throw _invalidMarker();
    return canonical;
  }

  static File _createStage(String root) {
    for (var attempt = 0; attempt < 32; attempt++) {
      final nonce =
          '${pid}_${DateTime.now().microsecondsSinceEpoch}_'
          '${_stageCounter++}_${Random.secure().nextInt(1 << 32)}';
      final stage = File(
        '$root${Platform.pathSeparator}$markerFileName.stage.$nonce',
      );
      try {
        stage.createSync(exclusive: true);
        return stage;
      } on FileSystemException {
        if (FileSystemEntity.typeSync(stage.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          continue;
        }
        rethrow;
      }
    }
    throw const FileSystemException('Unable to allocate logout marker stage.');
  }

  static void _validateReplaceableMarker(String markerPath) {
    final type = FileSystemEntity.typeSync(markerPath, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw _invalidMarker();
    }
  }

  static void _cleanupOwnedStage(File? stage) {
    if (stage == null) return;
    try {
      if (FileSystemEntity.typeSync(stage.path, followLinks: false) ==
          FileSystemEntityType.file) {
        stage.deleteSync();
      }
    } on Object {
      // A stale stage is ignored; cleanup never follows or recursively deletes.
    }
  }

  static bool _sameBytes(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  static AppFailure _invalidMarker() => AppFailure(
    FailureKind.validation,
    code: 'storage.logout_marker_invalid',
    localizationKey: 'failure.validation',
  );

  static AppFailure _mapFileError(Object error) {
    if (error is AppFailure) return error;
    return AppFailure(
      FailureKind.unavailable,
      code: 'storage.logout_marker_unavailable',
      localizationKey: 'failure.unavailable',
    );
  }
}
