import 'dart:typed_data';

import 'package:flutter_starterkit/core/storage/stores.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Storage contracts', () {
    test('preference values are bounded UTF-8 strings', () {
      expect(copyPreferenceValue(null), isNull);
      expect(copyPreferenceValue('safe'), 'safe');
      expect(copyPreferenceValue('é' * 2048), 'é' * 2048);
      expect(() => copyPreferenceValue('é' * 2049), throwsArgumentError);
    });

    test('secure byte values are bounded and copied', () {
      final source = Uint8List.fromList([1, 2, 3]);
      final copied = copySecureValue(source);
      source[0] = 8;
      copied[1] = 9;
      expect(source, [8, 2, 3]);
      expect(copied, [1, 9, 3]);
      expect(
        () => copySecureValue(
          Uint8List(StoreValueLimits.maxSecureValueBytes + 1),
        ),
        throwsArgumentError,
      );
      expect(StoreValueLimits.maxPreferenceValueBytes, 4096);
      expect(StoreValueLimits.maxSecureValueBytes, 65536);
      expect(
        copySecureValue(Uint8List(StoreValueLimits.maxSecureValueBytes)).length,
        StoreValueLimits.maxSecureValueBytes,
      );
    });
  });
}
