import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('CI pins a Dart-compatible Flutter SDK and strict formatting', () {
    final source = File('.github/workflows/flutter.yml').readAsStringSync();
    expect(source, contains("flutter-version: '3.47.4'"));
    expect(source, contains('dart format --output=none --set-exit-if-changed'));
  });
}
