import 'package:flutter_starterkit/core/deep_link/deep_link_parser.dart';
import 'package:flutter_starterkit/core/failure/app_failure.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Keep parser fixtures independent of the canonical consumer identity.
  final parser = DeepLinkParser(scheme: 'fixture-link');

  test('parses home and stable sample detail IDs plus internal returnTo', () {
    final home = parser.parse('fixture-link://app/');
    expect(home, isA<DeepLinkParsed>());
    expect((home as DeepLinkParsed).route.kind, DeepLinkRouteKind.home);

    final detail = parser.parse(
      'fixture-link://app/samples/stable_01?returnTo=%2F',
    );
    expect(detail, isA<DeepLinkParsed>());
    final route = (detail as DeepLinkParsed).route;
    expect(route.kind, DeepLinkRouteKind.sampleDetail);
    expect(route.id, 'stable_01');
    expect(route.returnTo, '/');
  });

  test('accepts only the internal return path allowlist', () {
    final accepted = parser.parse(
      'fixture-link://app/?returnTo=%2Fsamples%2Ffirst',
    ) as DeepLinkParsed;
    expect(accepted.route.returnTo, '/samples/first');

    for (final unsafe in [
      '//outside.test',
      '/samples/../outside',
      '/samples/%252e%252e',
      '/samples/a%2Fb',
      '/other',
      '/samples/',
    ]) {
      final result = parser.parse(
        'fixture-link://app/?returnTo=${Uri.encodeQueryComponent(unsafe)}',
      );
      expect(result, isA<DeepLinkRejected>(), reason: unsafe);
      expect((result as DeepLinkRejected).failure.kind, FailureKind.validation);
    }
  });

  test(
    'rejects malicious and malformed URI matrix without reflecting input',
    () {
      final tooLong = 'fixture-link://app/${'a' * 2048}';
      final invalid = <String>[
        'other://app/',
        'fixture-link://elsewhere/',
        'fixture-link://user@app/',
        'fixture-link://app:443/',
        'fixture-link://app/#fragment',
        'fixture-link://app/samples/a%2Fb',
        'fixture-link://app/samples/%2e%2e',
        'fixture-link://app/samples/a%ZZ',
        'fixture-link://app/samples/invalid.id',
        'fixture-link://app/samples/${'a' * 81}',
        'fixture-link://app/samples/a?unknown=value',
        'fixture-link://app/?returnTo=%2F&returnTo=%2F',
        'fixture-link://app/?access_token=private',
        'fixture-link://app/?returnTo=%2F%252Foutside',
        tooLong,
        'fixture-link://app/\n',
      ];
      for (final input in invalid) {
        final result = parser.parse(input);
        expect(result, isA<DeepLinkRejected>(), reason: input);
        final failure = (result as DeepLinkRejected).failure;
        expect(failure.kind, FailureKind.validation);
        expect(failure.toString(), isNot(contains('private')));
        expect(failure.toString(), isNot(contains(input)));
      }
    },
  );

  test('unknown well-formed route is a typed not-found failure', () {
    final result = parser.parse('fixture-link://app/elsewhere');
    expect(result, isA<DeepLinkRejected>());
    expect((result as DeepLinkRejected).failure.kind, FailureKind.notFound);
  });
}
