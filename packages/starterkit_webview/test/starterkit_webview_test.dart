import 'package:flutter_test/flutter_test.dart';
import 'package:starterkit_webview/starterkit_webview.dart';

void main() {
  group('TrustedOrigin', () {
    test('accepts exact HTTPS origins and normalizes default port', () {
      expect(
        TrustedOrigin.parse('https://example.com').rule,
        'https://example.com',
      );
      expect(
        TrustedOrigin.parse('https://example.com:8443').rule,
        'https://example.com:8443',
      );
    });

    test('rejects authority and path ambiguity', () {
      for (final value in [
        'http://example.com',
        ' https://example.com',
        'https://user@example.com',
        'https://example.com/path',
        'https://example.com?',
        'https://example.com#fragment',
        'https://example.com:',
        'https://example%2ecom',
      ]) {
        expect(TrustedOrigin.tryParse(value), isNull, reason: value);
      }
    });

    test('matches paths only on the configured origin', () {
      final origin = TrustedOrigin.parse('https://example.com:8443');
      expect(origin.matches(Uri.parse('https://example.com:8443/a')), isTrue);
      expect(origin.matches(Uri.parse('https://example.com/a')), isFalse);
      expect(origin.matches(Uri.parse('https://other.example/a')), isFalse);
    });
  });

  group('StarterWebViewNavigationPolicy', () {
    final policy = StarterWebViewNavigationPolicy(
      trustedOrigin: TrustedOrigin.parse('https://example.com'),
      allowedExternalSchemes: const ['mailto'],
    );

    test('keeps only trusted HTTPS internal', () {
      expect(
        policy.decide('https://example.com/path'),
        StarterWebViewNavigationDecision.internal,
      );
      expect(
        policy.decide(
          'http://example.com/path',
          mainFrame: true,
          userGesture: true,
        ),
        StarterWebViewNavigationDecision.blocked,
      );
    });

    test('externalizes only explicit main-frame user actions', () {
      expect(
        policy.decide(
          'https://outside.example',
          mainFrame: true,
          userGesture: true,
        ),
        StarterWebViewNavigationDecision.externalBrowser,
      );
      expect(
        policy.decide(
          'https://outside.example',
          mainFrame: false,
          userGesture: true,
        ),
        StarterWebViewNavigationDecision.blocked,
      );
      expect(
        policy.decide(
          'mailto:test@example.com',
          mainFrame: true,
          userGesture: true,
        ),
        StarterWebViewNavigationDecision.externalApp,
      );
    });

    test('allows only the isolated local namespace', () {
      expect(
        policy.decide(
          '$starterWebViewBundledLocalOrigin/starterkit-webview/index.html',
        ),
        StarterWebViewNavigationDecision.localAsset,
      );
      expect(
        policy.decide('$starterWebViewBundledLocalOrigin/other/index.html'),
        StarterWebViewNavigationDecision.externalBrowser,
      );
    });
  });

  group('StarterWebViewConfiguration', () {
    test('defaults to disconnected bridge and bundled local page', () {
      final configuration = StarterWebViewConfiguration(
        trustedOrigin: 'https://example.com',
      );
      expect(configuration.bridgeEnabled, isFalse);
      expect(configuration.usesBundledLocalStart, isTrue);
    });

    test('remote start must match trusted origin', () {
      expect(
        () => StarterWebViewConfiguration(
          trustedOrigin: 'https://example.com',
          startUrl: 'https://other.example/start',
        ),
        throwsArgumentError,
      );
    });

    test('rejects dangerous external schemes', () {
      expect(
        () => StarterWebViewConfiguration(
          trustedOrigin: 'https://example.com',
          allowedExternalSchemes: const ['javascript'],
        ),
        throwsArgumentError,
      );
    });
  });
}
