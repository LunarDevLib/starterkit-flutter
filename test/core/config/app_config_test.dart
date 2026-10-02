import 'package:flutter_starterkit/core/config/app_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppConfig', () {
    test('parses explicit environment keys and allows no endpoint', () {
      final config = AppConfig.fromEnvironment({
        'environment': 'development',
        'useMock': 'false',
      });
      expect(config.environment, AppEnvironment.development);
      expect(config.baseEndpoint, isNull);
      expect(config.useMock, isFalse);
    });

    test('requires a valid environment and parses booleans explicitly', () {
      expect(() => AppConfig.fromEnvironment({}), throwsFormatException);
      expect(
        () => AppConfig.fromEnvironment({
          'environment': 'test',
          'useMock': 'false',
        }),
        throwsFormatException,
      );
      expect(
        () => AppConfig.fromEnvironment({
          'environment': 'development',
          'useMock': 'yes',
        }),
        throwsFormatException,
      );
    });

    test('production requires HTTPS and never permits mock behavior', () {
      expect(
        () => AppConfig.fromEnvironment({
          'environment': 'production',
          'useMock': 'true',
        }),
        throwsFormatException,
      );
      expect(
        () => AppConfig.fromEnvironment({
          'environment': 'production',
          'baseEndpoint': 'http://api.example.test',
        }),
        throwsFormatException,
      );
      expect(
        AppConfig.fromEnvironment({
          'environment': 'production',
          'baseEndpoint': 'https://api.example.test/v1',
        }).baseEndpoint,
        Uri.parse('https://api.example.test/v1'),
      );
    });

    test(
      'mock requires explicit mock mode and unsafe endpoint components fail',
      () {
        expect(
          () => AppConfig.fromEnvironment({'environment': 'mock'}),
          throwsFormatException,
        );
        for (final endpoint in [
          'https://user:password@api.example.test',
          'https://api.example.test?token=secret',
          'https://api.example.test/#fragment',
        ]) {
          expect(
            () => AppConfig.fromEnvironment({
              'environment': 'staging',
              'baseEndpoint': endpoint,
            }),
            throwsFormatException,
            reason: endpoint,
          );
        }
      },
    );
  });
}
