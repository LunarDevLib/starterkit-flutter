import 'package:flutter_starterkit/core/flags/feature_flags.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('makes an immutable copy and defaults unknown keys to false', () {
    final source = <String, bool>{'sample.enabled': true};
    final flags = FeatureFlags(source);
    source['sample.enabled'] = false;
    source['other.enabled'] = true;

    expect(flags.isEnabled('sample.enabled'), isTrue);
    expect(flags.isEnabled('other.enabled'), isFalse);
    expect(flags.isEnabled('bad key'), isFalse);
    expect(
      () => flags.values['sample.enabled'] = false,
      throwsUnsupportedError,
    );
  });

  test('rejects unsafe or overlong configured keys', () {
    expect(() => FeatureFlags({'UpperCase': true}), throwsArgumentError);
    expect(() => FeatureFlags({'a' * 65: true}), throwsArgumentError);
  });
}
