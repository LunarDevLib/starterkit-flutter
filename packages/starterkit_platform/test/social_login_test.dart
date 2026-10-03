import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:starterkit_platform/starterkit_platform.dart';

const _auth = 'https://login.example.test/authorize';
const _tokenEndpoint = 'https://tokens.example.test/api/token';
const _redirect = 'product-login://oauth.example/callback';
const _base = 'https://tokens.example.test/api/';
const _hosts = {'login.example.test', 'tokens.example.test'};

void main() {
  test('PKCE matches RFC7636 S256 vector and has immutable values', () {
    const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
    final pkce = OAuthPKCE.fromVerifier(verifier);
    expect(pkce.verifier, verifier);
    expect(pkce.challenge, 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
    for (final value in ['a' * 43, 'a' * 128, '${'a' * 39}-._~']) {
      expect(OAuthPKCE.fromVerifier(value).challenge.length, 43);
    }
  });

  test('PKCE refuses invalid verifiers without reflecting the input', () {
    for (final verifier in [
      '',
      'a' * 42,
      'a' * 129,
      '${'a' * 42} ',
      '${'a' * 42}\n',
      '${'a' * 42}é',
      '${'a' * 42}%',
      '${'a' * 42}\ud800',
    ]) {
      try {
        OAuthPKCE.fromVerifier(verifier);
        fail('invalid verifier accepted');
      } on ArgumentError catch (error) {
        expect(error.message, 'Invalid PKCE verifier.');
        expect(error.invalidValue, isNull);
      }
    }
  });

  test('construction disabled and missing ports make zero calls', () async {
    final browser = _Browser();
    final transport = _Transport();
    final disabled = StarterSocialLoginService(
      configuration: _config(),
      browser: browser,
      transport: transport,
    );
    _service(browser, transport);
    expect(transport.getters, 0);
    expect(browser.authorizations, isEmpty);
    expect((await disabled.signIn()).code, 'social.disabled');
    expect((await disabled.cancel()).kind, SocialLoginCancelKind.idle);
    expect(
      (await StarterSocialLoginService(
        enabled: true,
        browser: browser,
        transport: transport,
      ).signIn()).code,
      'social.configuration_not_configured',
    );
    expect(
      (await StarterSocialLoginService(
        enabled: true,
        configuration: _config(),
        transport: transport,
      ).signIn()).code,
      'social.browser_not_configured',
    );
    expect(
      (await StarterSocialLoginService(
        enabled: true,
        configuration: _config(),
        browser: browser,
      ).signIn()).code,
      'social.transport_not_configured',
    );
    expect(transport.getters, 0);
    expect(transport.requests, isEmpty);
    expect(browser.authorizations, isEmpty);
    expect(browser.cancels, 0);
  });

  test(
    'raw authorization and token configurations reject unsafe forms locally',
    () async {
      for (final raw in [
        'http://login.example.test/path',
        'HTTPS://login.example.test/path',
        'https://LOGIN.example.test/path',
        'https://login.example.test./path',
        'https://user:password@login.example.test/path',
        'https://login.example.test/path?',
        'https://login.example.test/path#',
        'https://login.example.test/path?token=private',
        'https://login.example.test/path#private',
        'https://login.example.test/%70ath',
        'https://%6cogin.example.test/path',
        'https://login.example.test/a/../path',
        'https://login.example.test/a/%2e%2e/path',
        'https://login.example.test/path\\next',
        'https://login.example.test:0/path',
        'https://login.example.test:65536/path',
        'https://login.example.test:%34%34%33/path',
        'https://evil.invalid/path',
        'https://login.example.test/path ',
        'https://login.example.test/é',
        'https://login.example.test/${'a' * 2048}',
      ]) {
        for (final config in [
          _config(authorization: raw),
          _config(tokenEndpoint: raw),
        ]) {
          final browser = _Browser();
          final transport = _Transport();
          final result = await _service(
            browser,
            transport,
            config: config,
          ).signIn();
          expect(result.kind, SocialLoginKind.invalid);
          expect(result.code, 'social.invalid_configuration');
          expect(result.token, isNull);
          expect(transport.getters, 0);
          expect(browser.authorizations, isEmpty);
        }
      }
    },
  );

  test(
    'redirect is raw exact custom scheme authority path without normalization',
    () async {
      for (final redirect in [
        'https://oauth.example/callback',
        'http://oauth.example/callback',
        'Product-login://oauth.example/callback',
        'product-login://OAUTH.example/callback',
        'product-login://user@oauth.example/callback',
        'product-login://oauth.example:443/callback',
        'product-login://oauth.example/callback?',
        'product-login://oauth.example/callback#',
        'product-login://oauth.example/a/../callback',
        'product-login://oauth.example/%63allback',
        'product-login://oauth.example/a/%2e%2e/callback',
        'product-login://oauth.example/callback\\x',
        'product-login://oauth.example/é',
        'product-login://oauth.example',
        'product-login://oauth.example/callback\n',
        'product-login://oauth.example/${'a' * 2048}',
      ]) {
        final browser = _Browser();
        final transport = _Transport();
        expect(
          (await _service(
            browser,
            transport,
            config: _config(redirect: redirect),
          ).signIn()).code,
          'social.invalid_configuration',
        );
        expect(transport.getters, 0);
        expect(browser.authorizations, isEmpty);
      }
    },
  );

  test(
    'host lists client identifiers and return paths are bounded snapshots',
    () async {
      for (final config in [
        _config(hosts: {}),
        _config(hosts: {..._hosts, '*'}),
        _config(hosts: {..._hosts, 'UPPER.example.test'}),
        _config(hosts: {..._hosts, 'bad..example.test'}),
        _config(hosts: {..._hosts, '${'a' * 64}.example.test'}),
        _config(hosts: {..._hosts, 'a' * 254}),
        _config(
          hosts: {
            ..._hosts,
            for (var i = 0; i < 15; i++) 'host$i.example.test',
          },
        ),
        for (final id in ['', 'a' * 129, 'é' * 65, 'id\n', '\ud800'])
          _config(clientId: id),
        for (final path in [
          'relative',
          '//evil.invalid/path',
          '/a/../b',
          '/a%2fb',
          '/a?',
          '/a#',
          '/a\\b',
          '/a b',
          '/${'a' * 128}',
        ])
          _config(returnPath: path),
      ]) {
        final browser = _Browser();
        final transport = _Transport();
        expect(
          (await _service(browser, transport, config: config).signIn()).code,
          'social.invalid_configuration',
        );
        expect(transport.getters, 0);
        expect(browser.authorizations, isEmpty);
      }
      final hosts = {..._hosts};
      final config = _config(hosts: hosts);
      hosts.clear();
      expect(config.allowedHosts, _hosts);
      expect(() => config.allowedHosts.clear(), throwsUnsupportedError);
    },
  );

  test(
    'generated32byte state verifier and exact S256 exchange vary per attempt',
    () async {
      final browser = _Browser()..action = (uri, _) async => _callback(uri);
      final transport = _Transport();
      final service = _service(browser, transport);
      for (var attempt = 0; attempt < 2; attempt++) {
        final result = await service.signIn();
        expect(result.kind, SocialLoginKind.authenticated);
        expect(result.code, 'social.authenticated');
        final uri = browser.authorizations.last;
        final query = uri.queryParameters;
        expect(
          query.keys,
          unorderedEquals([
            'response_type',
            'client_id',
            'redirect_uri',
            'state',
            'code_challenge',
            'code_challenge_method',
          ]),
        );
        expect(query['response_type'], 'code');
        expect(query['client_id'], 'public-client');
        expect(query['redirect_uri'], _redirect);
        expect(query['code_challenge_method'], 'S256');
        expect(browser.schemes.last, 'product-login');
        expect(query['state'], matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
        expect(base64Url.decode('${query['state']}='), hasLength(32));
        final request = transport.requests.last;
        expect(request.path, 'token');
        expect(request.method, 'POST');
        expect(request.contentType, 'application/x-www-form-urlencoded');
        expect(request.accept, 'application/json');
        final form = _form(request);
        expect(
          form.keys,
          unorderedEquals([
            'grant_type',
            'client_id',
            'code',
            'redirect_uri',
            'code_verifier',
          ]),
        );
        expect(form['grant_type'], 'authorization_code');
        expect(form['client_id'], 'public-client');
        expect(form['code'], 'unit-code');
        expect(form['redirect_uri'], _redirect);
        final verifier = form['code_verifier']!;
        expect(base64Url.decode('$verifier='), hasLength(32));
        expect(verifier, isNot(query['state']));
        expect(
          OAuthPKCE.fromVerifier(verifier).challenge,
          query['code_challenge'],
        );
        expect(request.body.length, lessThanOrEqualTo(8192));
      }
      expect(
        browser.authorizations[0].queryParameters['state'],
        isNot(browser.authorizations[1].queryParameters['state']),
      );
      expect(
        browser.authorizations[0].queryParameters['code_challenge'],
        isNot(browser.authorizations[1].queryParameters['code_challenge']),
      );
      expect(transport.getters, 4);
      expect(transport.requests, hasLength(2));
      expect(browser.cancels, 0);
    },
  );

  test(
    'optional return path and Unicode client identifier encode exactly',
    () async {
      final browser = _Browser()
        ..action = (uri, _) async => _callback(uri, code: 'code +=é');
      final transport = _Transport();
      final result = await _service(
        browser,
        transport,
        config: _config(clientId: 'é' * 64, returnPath: '/${'a' * 127}'),
      ).signIn();
      expect(result.code, 'social.authenticated');
      expect(
        browser.authorizations.single.queryParameters['return_path'],
        '/${'a' * 127}',
      );
      expect(_form(transport.requests.single)['client_id'], 'é' * 64);
      expect(_form(transport.requests.single)['code'], 'code +=é');
    },
  );

  test(
    'raw callback scheme authority path and fragment tampering never exchange',
    () async {
      for (final prefix in [
        'Product-login://oauth.example/callback',
        'product-login://OAUTH.example/callback',
        'product-login://oauth.example:443/callback',
        'product-login://user@oauth.example/callback',
        'product-login://oauth.example/other',
        'product-login://oauth.example/a/../callback',
        'product-login://oauth.example/%63allback',
        'product-login://oauth.example/callback/',
        'product-login://oauth.example./callback',
        'https://oauth.example/callback',
      ]) {
        final browser = _Browser()
          ..action = (uri, _) async =>
              '$prefix?code=x&state=${uri.queryParameters['state']}';
        final transport = _Transport();
        expect(
          (await _service(browser, transport).signIn()).code,
          'social.invalid_callback',
        );
        expect(transport.requests, isEmpty);
      }
      for (final suffix in ['#', '#private', '\n', '\u0085', '\ud800']) {
        final browser = _Browser()
          ..action = (uri, _) async => '${_callback(uri)}$suffix';
        final transport = _Transport();
        expect(
          (await _service(browser, transport).signIn()).code,
          'social.invalid_callback',
        );
        expect(transport.requests, isEmpty);
      }
    },
  );

  test('callback query rejects decoded duplicates unknown names and malformed UTF8', () async {
    for (final query in [
      'code=x&state=STATE&state=STATE',
      'code=x&state=STATE&%73tate=STATE',
      'code=x&%63ode=y&state=STATE',
      'code=x&state=STATE&unknown=x',
      'code=x&state=STATE&STATE=x',
      'code=x&state=STATE&',
      'code=x&state=STATE&x=1&y=2&z=3',
      'code=x&state',
      'code=x',
      'state=STATE',
      'code=&state=STATE',
      'code=x&state=STATE&error_description=x',
      'code=x&state=STATE&error=access_denied',
      'error=&state=STATE',
      'code=%&state=STATE',
      'code=%0&state=STATE',
      'code=%GG&state=STATE',
      'code=%C0%AF&state=STATE',
      'code=%FF&state=STATE',
      'code=%ED%A0%80&state=STATE',
      'code=%00&state=STATE',
      'code=%7f&state=STATE',
      'code=x&state=STATE&error_description=%FF',
      '=x&state=STATE',
      '',
    ]) {
      final browser = _Browser()
        ..action = (uri, _) async =>
            '$_redirect?${query.replaceAll('STATE', uri.queryParameters['state']!)}';
      final transport = _Transport();
      final result = await _service(browser, transport).signIn();
      expect(result.code, 'social.invalid_callback');
      expect(result.token, isNull);
      expect(transport.requests, isEmpty);
    }
  });

  test('single percent-decoded names and values are forwarded without recursive decoding', () async {
    final browser = _Browser()
      ..action = (uri, _) async =>
          '$_redirect?%63ode=a%2520b%3D%2B&%73tate=${uri.queryParameters['state']}';
    final transport = _Transport();
    expect(
      (await _service(browser, transport).signIn()).code,
      'social.authenticated',
    );
    expect(_form(transport.requests.single)['code'], 'a%20b=+');
  });

  test(
    'state mismatches always precede authorization error or exchange',
    () async {
      for (final state in ['', 'a' * 42, 'a' * 43, 'a' * 44]) {
        for (final fields in [
          'code=x',
          'error=access_denied&error_description=private',
        ]) {
          final browser = _Browser()
            ..action = (_, _) async => '$_redirect?$fields&state=$state';
          final transport = _Transport();
          final result = await _service(browser, transport).signIn();
          expect(result.kind, SocialLoginKind.invalid);
          expect(result.code, 'social.state_mismatch');
          expect(transport.requests, isEmpty);
        }
      }
    },
  );

  test('valid-state authorization errors expose only fixed outcome', () async {
    final browser = _Browser()
      ..action = (uri, _) async =>
          '$_redirect?state=${uri.queryParameters['state']}&error=access_denied&error_description=private+provider+prose';
    final transport = _Transport();
    final result = await _service(browser, transport).signIn();
    expect(result.kind, SocialLoginKind.failure);
    expect(result.code, 'social.authorization_rejected');
    expect(result.token, isNull);
    expect(result.toString(), isNot(contains('private')));
    expect(transport.requests, isEmpty);
  });

  test(
    'code2048 callback4096 and form8192 limits reject before execute',
    () async {
      final accepted = _Browser()
        ..action = (uri, _) async => _callback(uri, code: 'x' * 2048);
      final transport = _Transport();
      expect(
        (await _service(accepted, transport).signIn()).code,
        'social.authenticated',
      );
      expect(_form(transport.requests.single)['code']!.length, 2048);
      for (final code in ['x' * 2049, 'x' * 4096]) {
        final browser = _Browser()
          ..action = (uri, _) async => _callback(uri, code: code);
        final rejected = _Transport();
        expect(
          (await _service(browser, rejected).signIn()).code,
          'social.invalid_callback',
        );
        expect(rejected.requests, isEmpty);
      }
      final redirect = 'product-login://oauth.example${'/a' * 500}';
      final browser = _Browser()
        ..action = (uri, _) async =>
            '$redirect?code=${'€' * 666}&state=${uri.queryParameters['state']}';
      final large = _Transport();
      expect(
        (await _service(
          browser,
          large,
          config: _config(redirect: redirect, clientId: 'é' * 64),
        ).signIn()).code,
        'social.invalid_callback',
      );
      expect(large.requests, isEmpty);
    },
  );

  test('callback4096 exact UTF8 boundary accepts only within bound', () async {
    for (final size in [4096, 4097]) {
      final browser = _Browser()
        ..action = (uri, _) async {
          final start =
              '$_redirect?state=${uri.queryParameters['state']}&error=denied&error_description=';
          return '$start${'x' * (size - utf8.encode(start).length)}';
        };
      final transport = _Transport();
      expect(
        (await _service(browser, transport).signIn()).code,
        size == 4096
            ? 'social.authorization_rejected'
            : 'social.invalid_callback',
      );
      expect(transport.requests, isEmpty);
    }
  });

  test('final authorization URL over4096 never starts browser', () async {
    final redirect = 'product-login://oauth.example${'/a' * 950}';
    expect(redirect.length, lessThanOrEqualTo(2048));
    final browser = _Browser();
    final transport = _Transport();
    final result = await _service(
      browser,
      transport,
      config: _config(
        redirect: redirect,
        clientId: 'é' * 64,
        returnPath: '/${'a' * 127}',
      ),
    ).signIn();
    expect(result.code, 'social.invalid_configuration');
    expect(browser.authorizations, isEmpty);
    expect(transport.requests, isEmpty);
  });

  test(
    'base origin and segment boundary must exactly reproduce token target',
    () async {
      for (final raw in [
        'https://login.example.test/api/',
        'https://tokens.example.test:8443/api/',
        'https://tokens.example.test/ap',
        'https://tokens.example.test/apix/',
        'https://tokens.example.test/api/token/',
        'https://tokens.example.test/api/?',
        'https://tokens.example.test/api/#',
        'https://user@tokens.example.test/api/',
        'https://tokens.example.test/%61pi/',
        'https://tokens.example.test/x/../api/',
      ]) {
        final browser = _Browser();
        final transport = _Transport()..base = _RawUri(raw);
        expect(
          (await _service(browser, transport).signIn()).code,
          'social.invalid_configuration',
        );
        expect(transport.getters, 1);
        expect(browser.authorizations, isEmpty);
        expect(transport.requests, isEmpty);
      }
      final browser = _Browser()..action = (uri, _) async => _callback(uri);
      final transport = _Transport()
        ..base = Uri.parse('https://tokens.example.test/api');
      expect(
        (await _service(
          browser,
          transport,
          config: _config(
            tokenEndpoint: 'https://tokens.example.test/api/nested/token',
          ),
        ).signIn()).code,
        'social.authenticated',
      );
      expect(transport.requests.single.path, 'nested/token');
    },
  );

  test(
    'supplied Uri serialization cannot recover prior normalization',
    () async {
      // Raw config is rejected above. Product Uri parsing can erase provenance;
      // this test establishes only the supplied serialization boundary.
      final parsed = Uri.parse('https://TOKENS.example.test/x/../api/');
      expect(parsed.toString(), _base);
      final browser = _Browser()..action = (uri, _) async => _callback(uri);
      final transport = _Transport()..base = parsed;
      expect(
        (await _service(browser, transport).signIn()).code,
        'social.authenticated',
      );
      expect(transport.requests.single.path, 'token');
    },
  );

  test(
    'fresh base check before exchange rejects hopping configuration',
    () async {
      for (final second in [
        'https://login.example.test/api/',
        'https://tokens.example.test/apix/',
      ]) {
        final browser = _Browser()..action = (uri, _) async => _callback(uri);
        final transport = _Transport();
        transport.getterAction = () =>
            Uri.parse(transport.getters == 1 ? _base : second);
        expect(
          (await _service(browser, transport).signIn()).code,
          'social.invalid_configuration',
        );
        expect(transport.getters, 2);
        expect(browser.authorizations, hasLength(1));
        expect(transport.requests, isEmpty);
      }
    },
  );

  test(
    'token JSON permits required2 optional1 and canonicalizes Bearer',
    () async {
      for (final expires in [null, 1, 31536000]) {
        final browser = _Browser()..action = (uri, _) async => _callback(uri);
        final transport = _Transport()
          ..response = _response({
            'access_token': 'synthetic-unit-token',
            'token_type': 'bEaReR',
            if (expires != null) 'expires_in': expires,
          });
        final result = await _service(browser, transport).signIn();
        expect(result.kind, SocialLoginKind.authenticated);
        expect(result.token!.accessToken, 'synthetic-unit-token');
        expect(result.token!.tokenType, 'Bearer');
        expect(result.token!.expiresIn, expires);
        expect(
          result.token.toString(),
          isNot(contains('synthetic-unit-token')),
        );
        expect(result.toString(), isNot(contains('synthetic-unit-token')));
        expect(transport.requests, hasLength(1));
      }
    },
  );

  test('token schemas types expiry controls and extras fail closed', () async {
    for (final json in <Object?>[
      null,
      [],
      'private',
      {},
      {'access_token': 'x'},
      {'token_type': 'Bearer'},
      {'access_token': '', 'token_type': 'Bearer'},
      {'access_token': 1, 'token_type': 'Bearer'},
      {'access_token': 'x', 'token_type': 1},
      {'access_token': 'x', 'token_type': 'Basic'},
      {'access_token': 'x', 'token_type': 'Bearer '},
      {'access_token': 'x\n', 'token_type': 'Bearer'},
      {'access_token': '\ud800', 'token_type': 'Bearer'},
      {'access_token': 'x', 'token_type': 'Bearer', 'refresh_token': 'private'},
      {
        'access_token': 'x',
        'token_type': 'Bearer',
        'expires_in': 1,
        'extra': 'private',
      },
      for (final expiry in [null, false, true, 1.0, '1', 0, -1, 31536001])
        {'access_token': 'x', 'token_type': 'Bearer', 'expires_in': expiry},
    ]) {
      final browser = _Browser()..action = (uri, _) async => _callback(uri);
      final transport = _Transport()..response = _response(json);
      final result = await _service(browser, transport).signIn();
      expect(result.kind, SocialLoginKind.failure);
      expect(result.code, 'social.token_response_invalid');
      expect(result.token, isNull);
      expect(transport.requests, hasLength(1));
    }
  });

  test(
    'token8192 UTF8 and response16KiB exact boundaries are enforced',
    () async {
      final browser = _Browser()..action = (uri, _) async => _callback(uri);
      final transport = _Transport();
      for (final token in ['x' * 8192, 'é' * 4096]) {
        transport.response = _response({
          'access_token': token,
          'token_type': 'Bearer',
        });
        expect(
          (await _service(browser, transport).signIn()).token!.accessToken,
          token,
        );
      }
      transport.response = _response({
        'access_token': 'x' * 8193,
        'token_type': 'Bearer',
      });
      expect(
        (await _service(browser, transport).signIn()).code,
        'social.token_response_invalid',
      );
      final bytes = _response({'access_token': 'x', 'token_type': 'Bearer'})
          .body;
      final exact = [...bytes, ...List<int>.filled(16384 - bytes.length, 0x20)];
      expect(exact.length, 16384);
      transport.response = OAuthTokenResponse(statusCode: 200, body: exact);
      expect(
        (await _service(browser, transport).signIn()).code,
        'social.authenticated',
      );
      transport.response = OAuthTokenResponse(
        statusCode: 200,
        body: [...exact, 0x20],
      );
      expect(
        (await _service(browser, transport).signIn()).code,
        'social.token_response_invalid',
      );
    },
  );

  test(
    'strict token UTF8 byte units and status are bounded fixed errors',
    () async {
      for (final response in [
        for (final body in <List<int>>[
          [],
          [0xff],
          [0xc0, 0xaf],
          [0xed, 0xa0, 0x80],
          [-1],
          [256],
          utf8.encode('{'),
        ])
          OAuthTokenResponse(statusCode: 200, body: body),
        for (final status in [0, 99, 600])
          OAuthTokenResponse(statusCode: status, body: []),
      ]) {
        final browser = _Browser()..action = (uri, _) async => _callback(uri);
        final transport = _Transport()..response = response;
        expect(
          (await _service(browser, transport).signIn()).code,
          'social.token_response_invalid',
        );
        expect(transport.requests, hasLength(1));
      }
      for (final status in [100, 199, 300, 401, 500, 599]) {
        final browser = _Browser()..action = (uri, _) async => _callback(uri);
        final transport = _Transport()
          ..response = OAuthTokenResponse(statusCode: status, body: []);
        expect(
          (await _service(browser, transport).signIn()).code,
          'social.transport_failed',
        );
        expect(transport.requests, hasLength(1));
      }
    },
  );

  test(
    'configuration request response maps and bytes snapshot mutable inputs',
    () {
      final hosts = {..._hosts};
      final config = _config(hosts: hosts);
      hosts.clear();
      expect(config.allowedHosts, _hosts);
      expect(
        () => config.allowedHosts.add('evil.invalid'),
        throwsUnsupportedError,
      );
      final bytes = [1, 2, 3];
      final request = OAuthTokenRequest(path: 'token', body: bytes);
      final response = OAuthTokenResponse(statusCode: 200, body: bytes);
      bytes.clear();
      expect(request.body, [1, 2, 3]);
      expect(response.body, [1, 2, 3]);
      expect(() => request.body.clear(), throwsUnsupportedError);
      expect(() => response.body[0] = 0, throwsUnsupportedError);
    },
  );

  test(
    'browser and transport getter sync async exceptions are fixed',
    () async {
      for (final asyncFailure in [false, true]) {
        final browser = _Browser()
          ..action = (_, _) => asyncFailure
              ? Future.error(StateError('private provider prose'))
              : throw StateError('private provider prose');
        final transport = _Transport();
        final result = await _service(browser, transport).signIn();
        expect(result.code, 'social.browser_failed');
        expect(result.token, isNull);
        expect(result.toString(), isNot(contains('private')));
        expect(transport.requests, isEmpty);
      }
      for (final at in [1, 2]) {
        final browser = _Browser()..action = (uri, _) async => _callback(uri);
        final transport = _Transport()
          ..getterAction = () => throw StateError('private base');
        if (at == 2) {
          transport.getterAction = () {
            if (transport.getters == 2) throw StateError('private base');
            return Uri.parse(_base);
          };
        }
        expect(
          (await _service(browser, transport).signIn()).code,
          'social.transport_failed',
        );
        expect(transport.requests, isEmpty);
      }
    },
  );

  test(
    'transport sync async and response-factory errors make only one exchange',
    () async {
      for (final action
          in <Future<OAuthTokenResponse> Function(OAuthTokenRequest)>[
            (_) => throw StateError('private transport details'),
            (_) async => throw StateError('private transport details'),
            (_) async =>
                OAuthTokenResponse(statusCode: 200, body: _ThrowingBytes()),
          ]) {
        final browser = _Browser()..action = (uri, _) async => _callback(uri);
        final transport = _Transport()..action = action;
        final result = await _service(browser, transport).signIn();
        expect(result.code, 'social.transport_failed');
        expect(result.token, isNull);
        expect(result.toString(), isNot(contains('private')));
        expect(transport.requests, hasLength(1));
        expect(transport.getters, 2);
      }
    },
  );

  test('published guard blocks synchronous reentry from getter browser and exchange', () async {
    for (final phase in ['getter', 'browser', 'exchange']) {
      final browser = _Browser();
      final transport = _Transport();
      late StarterSocialLoginService service;
      Future<SocialLoginResult>? reentered;
      transport.getterAction = () {
        if (phase == 'getter' && transport.getters == 1) {
          reentered = service.signIn();
        }
        return Uri.parse(_base);
      };
      browser.action = (uri, _) {
        if (phase == 'browser') reentered = service.signIn();
        return Future.value(_callback(uri));
      };
      transport.action = (_) {
        if (phase == 'exchange') reentered = service.signIn();
        return Future.value(transport.response);
      };
      service = _service(browser, transport);
      expect((await service.signIn()).code, 'social.authenticated');
      expect((await reentered!).kind, SocialLoginKind.inProgress);
      expect(browser.authorizations, hasLength(1));
      expect(transport.requests, hasLength(1));
    }
  });

  test(
    'concurrent attempt is rejected without getters and idle cancel is inert',
    () async {
      final browser = _Browser();
      final transport = _Transport();
      final service = _service(browser, transport);
      expect((await service.cancel()).code, 'social.idle');
      final first = service.signIn();
      expect((await service.signIn()).code, 'social.in_progress');
      expect(transport.getters, 1);
      expect(browser.authorizations, hasLength(1));
      browser.pending.single.complete(_callback(browser.authorizations.single));
      expect((await first).code, 'social.authenticated');
      expect((await service.cancel()).code, 'social.idle');
      expect(browser.cancels, 0);
    },
  );

  test('cancellation publishes one shared future before synchronous reentrant cleanup', () async {
    final browser = _Browser();
    final transport = _Transport();
    final service = _service(browser, transport);
    final cleanup = Completer<void>();
    Future<SocialLoginCancelResult>? reentered;
    browser.cancelAction = () {
      reentered = service.cancel();
      return cleanup.future;
    };
    final signIn = service.signIn();
    final first = service.cancel();
    final second = service.cancel();
    expect(identical(first, second), isTrue);
    expect(identical(first, reentered), isTrue);
    expect(browser.cancels, 1);
    expect((await signIn).kind, SocialLoginKind.cancelled);
    expect((await service.signIn()).kind, SocialLoginKind.inProgress);
    var acknowledged = false;
    first.then((_) => acknowledged = true);
    await Future<void>.value();
    expect(acknowledged, isFalse);
    browser.pending.single.complete(_callback(browser.authorizations.single));
    await Future<void>.value();
    expect((await service.signIn()).kind, SocialLoginKind.inProgress);
    expect(identical(first, service.cancel()), isTrue);
    expect(browser.cancels, 1);
    expect(transport.requests, isEmpty);
    cleanup.complete();
    expect((await first).kind, SocialLoginCancelKind.cancelled);
    expect((await service.cancel()).kind, SocialLoginCancelKind.idle);
  });

  test(
    'synchronous cancellation at either getter prevents browser or exchange',
    () async {
      for (final at in [1, 2]) {
        final browser = _Browser()..action = (uri, _) async => _callback(uri);
        final transport = _Transport();
        late StarterSocialLoginService service;
        Future<SocialLoginCancelResult>? cancelled;
        transport.getterAction = () {
          if (transport.getters == at) cancelled = service.cancel();
          return Uri.parse(_base);
        };
        service = _service(browser, transport);
        expect((await service.signIn()).code, 'social.cancelled');
        expect((await cancelled!).code, 'social.cancelled');
        expect(browser.authorizations, hasLength(at == 1 ? 0 : 1));
        expect(browser.cancels, 1);
        expect(transport.requests, isEmpty);
      }
    },
  );

  test(
    'synchronous browser or execute cancellation cannot publish a token',
    () async {
      for (final phase in ['browser', 'execute']) {
        final browser = _Browser();
        final transport = _Transport();
        late StarterSocialLoginService service;
        Future<SocialLoginCancelResult>? cancelled;
        browser.action = (uri, _) {
          if (phase == 'browser') cancelled = service.cancel();
          return Future.value(_callback(uri));
        };
        transport.action = (_) {
          cancelled = service.cancel();
          return Future.value(transport.response);
        };
        service = _service(browser, transport);
        final result = await service.signIn();
        expect(result.kind, SocialLoginKind.cancelled);
        expect(result.token, isNull);
        expect((await cancelled!).kind, SocialLoginCancelKind.cancelled);
        expect(transport.requests, hasLength(phase == 'browser' ? 0 : 1));
      }
    },
  );

  test(
    'late cancelled callback or failure cannot release a newer generation',
    () async {
      for (final error in [false, true]) {
        final browser = _Browser();
        final transport = _Transport();
        final service = _service(browser, transport);
        final old = service.signIn();
        await service.cancel();
        expect((await old).code, 'social.cancelled');
        final current = service.signIn();
        if (error) {
          browser.pending[0].completeError(
            StateError('private late browser error'),
          );
        } else {
          browser.pending[0].complete(
            _callback(browser.authorizations[0], code: 'old-code'),
          );
        }
        await Future<void>.value();
        expect((await service.signIn()).code, 'social.in_progress');
        expect(transport.requests, isEmpty);
        browser.pending[1].complete(
          _callback(browser.authorizations[1], code: 'new-code'),
        );
        expect((await current).code, 'social.authenticated');
        expect(_form(transport.requests.single)['code'], 'new-code');
      }
    },
  );

  test(
    'late cancelled token response or failure cannot clear a newer attempt',
    () async {
      for (final error in [false, true]) {
        final browser = _Browser();
        final transport = _Transport();
        final service = _service(browser, transport);
        final started = Completer<void>();
        final pending = Completer<OAuthTokenResponse>();
        transport.action = (_) {
          if (transport.requests.length == 1) {
            started.complete();
            return pending.future;
          }
          return Future.value(
            _response({
              'access_token': 'new-unit-token',
              'token_type': 'Bearer',
            }),
          );
        };
        final old = service.signIn();
        browser.pending[0].complete(_callback(browser.authorizations[0]));
        await started.future;
        await service.cancel();
        expect((await old).token, isNull);
        final current = service.signIn();
        if (error) {
          pending.completeError(StateError('private late transport failure'));
        } else {
          pending.complete(
            _response({
              'access_token': 'old-unit-token',
              'token_type': 'Bearer',
            }),
          );
        }
        await Future<void>.value();
        expect((await service.signIn()).code, 'social.in_progress');
        browser.pending[1].complete(_callback(browser.authorizations[1]));
        final result = await current;
        expect(result.token!.accessToken, 'new-unit-token');
        expect(transport.requests, hasLength(2));
        expect(browser.cancels, 1);
      }
    },
  );

  test(
    'cleanup sync or async failure permanently fences the instance',
    () async {
      for (final asyncFailure in [false, true]) {
        final browser = _Browser()
          ..cancelAction = () => asyncFailure
              ? Future.error(StateError('private cleanup failure'))
              : throw StateError('private cleanup failure');
        final transport = _Transport();
        final service = _service(browser, transport);
        final result = service.signIn();
        final cancelled = await service.cancel();
        expect(cancelled.kind, SocialLoginCancelKind.failure);
        expect(cancelled.code, 'social.cleanup_failed');
        expect((await result).code, 'social.cancelled');
        final retry = await service.signIn();
        expect(retry.kind, SocialLoginKind.unavailable);
        expect(retry.code, 'social.cleanup_failed');
        expect((await service.cancel()).kind, SocialLoginCancelKind.idle);
        expect(browser.cancels, 1);
        expect(browser.authorizations, hasLength(1));
        expect(transport.requests, isEmpty);
      }
    },
  );

  test(
    'normal failures clear the guard and permit a fresh explicit attempt',
    () async {
      final browser = _Browser()
        ..action = (_, _) async => throw StateError('private browser');
      final transport = _Transport();
      final service = _service(browser, transport);
      expect((await service.signIn()).code, 'social.browser_failed');
      browser.action = (uri, _) async => _callback(uri);
      expect((await service.signIn()).code, 'social.authenticated');
      expect(browser.authorizations, hasLength(2));
      expect(transport.requests, hasLength(1));
    },
  );
}

OAuthConfiguration _config({
  String authorization = _auth,
  String tokenEndpoint = _tokenEndpoint,
  String redirect = _redirect,
  String clientId = 'public-client',
  Set<String> hosts = _hosts,
  String returnPath = '',
}) => OAuthConfiguration(
  authorizationEndpoint: authorization,
  tokenEndpoint: tokenEndpoint,
  redirectUri: redirect,
  clientId: clientId,
  allowedHosts: hosts,
  returnPath: returnPath,
);

StarterSocialLoginService _service(
  _Browser browser,
  _Transport transport, {
  OAuthConfiguration? config,
}) => StarterSocialLoginService(
  enabled: true,
  configuration: config ?? _config(),
  browser: browser,
  transport: transport,
);

String _callback(Uri uri, {String code = 'unit-code'}) =>
    '${uri.queryParameters['redirect_uri']}?code=${Uri.encodeQueryComponent(code)}&state=${uri.queryParameters['state']}';

Map<String, String> _form(OAuthTokenRequest request) =>
    Uri.splitQueryString(utf8.decode(request.body));
OAuthTokenResponse _response(Object? value) =>
    OAuthTokenResponse(statusCode: 200, body: utf8.encode(jsonEncode(value)));

final class _Browser implements OAuthBrowserAuthentication {
  final authorizations = <Uri>[];
  final schemes = <String>[];
  final pending = <Completer<String>>[];
  int cancels = 0;
  Future<String> Function(Uri, String)? action;
  Future<void> Function()? cancelAction;

  @override
  Future<String> authenticate(Uri uri, String scheme) {
    authorizations.add(uri);
    schemes.add(scheme);
    final configured = action;
    if (configured != null) return configured(uri, scheme);
    final completion = Completer<String>();
    pending.add(completion);
    return completion.future;
  }

  @override
  Future<void> cancel() {
    cancels++;
    return cancelAction?.call() ?? Future.value();
  }
}

final class _Transport implements OAuthTokenTransport {
  Uri base = Uri.parse(_base);
  int getters = 0;
  final requests = <OAuthTokenRequest>[];
  OAuthTokenResponse response = _response({
    'access_token': 'unit-token',
    'token_type': 'Bearer',
  });
  Uri Function()? getterAction;
  Future<OAuthTokenResponse> Function(OAuthTokenRequest)? action;

  @override
  Uri get baseEndpoint {
    getters++;
    return getterAction?.call() ?? base;
  }

  @override
  Future<OAuthTokenResponse> execute(OAuthTokenRequest request) {
    requests.add(request);
    return action?.call(request) ?? Future.value(response);
  }
}

final class _RawUri implements Uri {
  _RawUri(this.raw);
  final String raw;
  @override
  String toString() => raw;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ThrowingBytes extends ListBase<int> {
  @override
  int get length => 1;
  @override
  set length(int value) => throw UnsupportedError('test-only');
  @override
  int operator [](int index) => throw StateError('private response bytes');
  @override
  void operator []=(int index, int value) =>
      throw UnsupportedError('test-only');
}
