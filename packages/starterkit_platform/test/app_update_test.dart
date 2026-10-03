import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:starterkit_platform/starterkit_platform.dart';

const _android = AppUpdateTarget.android(applicationId: 'dev.example.product');
const _ios = AppUpdateTarget.ios(storeId: '00123456789012345678');
const _androidUrl =
    'https://play.google.com/store/apps/details?id=dev.example.product';
const _iosUrl = 'https://apps.apple.com/app/id00123456789012345678';
const _candidate = AppUpdateCandidate(
  latestVersion: '2',
  storeUrl: _androidUrl,
);

void main() {
  test('constructors and disabled actions make zero port calls', () async {
    final reader = _Reader();
    final opener = _Opener();
    final enabled = _capability(reader, opener: opener);
    final disabled = StarterAppUpdateCapability(
      target: _android,
      reader: reader,
      opener: opener,
    );
    expect(enabled.enabled, isTrue);
    expect(reader.paths, isEmpty);
    expect(opener.uris, isEmpty);
    for (final capability in [disabled, const StarterAppUpdateCapability()]) {
      final checked = await capability.check(
        metadataPath: 'invalid',
        currentVersion: 'invalid',
      );
      expect(checked.kind, AppUpdateCheckKind.unavailable);
      expect(checked.code, 'update.disabled');
      expect(checked.candidate, isNull);
      final opened = await capability.openStore(
        const AppUpdateCandidate(latestVersion: '', storeUrl: ''),
      );
      expect(opened.kind, AppUpdateOpenKind.unavailable);
      expect(opened.code, 'update.disabled');
    }
    expect(reader.paths, isEmpty);
    expect(opener.uris, isEmpty);
  });

  test('typed target constructors preserve replaceable opaque identities', () {
    expect(_android.store, AppUpdateStore.android);
    expect(_android.applicationId, 'dev.example.product');
    expect(_android.storeId, isNull);
    expect(_ios.store, AppUpdateStore.ios);
    expect(_ios.storeId, '00123456789012345678');
    expect(_ios.applicationId, isNull);
    const invalid = AppUpdateTarget.ios(storeId: 'not configured yet');
    expect(invalid.storeId, 'not configured yet');
  });

  test(
    'missing target reader and opener are fixed unavailable outcomes',
    () async {
      final reader = _Reader();
      final opener = _Opener();
      final noTarget = StarterAppUpdateCapability(
        enabled: true,
        reader: reader,
        opener: opener,
      );
      expect((await _check(noTarget)).code, 'update.target_not_configured');
      expect(
        (await noTarget.openStore(_candidate)).code,
        'update.target_not_configured',
      );
      const noPorts = StarterAppUpdateCapability(
        enabled: true,
        target: _android,
      );
      final checked = await _check(noPorts);
      expect(checked.kind, AppUpdateCheckKind.unavailable);
      expect(checked.code, 'update.reader_not_configured');
      expect(checked.candidate, isNull);
      final opened = await noPorts.openStore(_candidate);
      expect(opened.kind, AppUpdateOpenKind.unavailable);
      expect(opened.code, 'update.opener_not_configured');
      expect(reader.paths, isEmpty);
      expect(opener.uris, isEmpty);
    },
  );

  test(
    'check never opens and open never reads or remembers a prior check',
    () async {
      final reader = _Reader();
      final opener = _Opener();
      final capability = _capability(reader, opener: opener);
      final opened = await capability.openStore(_candidate);
      expect(opened.kind, AppUpdateOpenKind.opened);
      expect(opened.code, 'update.opened');
      expect(reader.paths, isEmpty);
      expect(opener.uris.single.toString(), _androidUrl);
      final checked = await _check(capability);
      expect(checked.kind, AppUpdateCheckKind.updateAvailable);
      expect(checked.code, 'update.available');
      expect(checked.candidate!.latestVersion, '2');
      expect(checked.candidate!.storeUrl, _androidUrl);
      expect(reader.paths, ['/updates/current.json']);
      expect(opener.uris, hasLength(1));
      await _check(capability);
      expect(reader.paths, hasLength(2));
      expect(opener.uris, hasLength(1));
    },
  );

  test('invalid targets reject both actions before any I/O', () async {
    for (final target in [
      const AppUpdateTarget.android(applicationId: ''),
      const AppUpdateTarget.android(applicationId: 'single'),
      const AppUpdateTarget.android(applicationId: '.dev.example'),
      const AppUpdateTarget.android(applicationId: 'dev..example'),
      const AppUpdateTarget.android(applicationId: 'dev.example.'),
      const AppUpdateTarget.android(applicationId: 'dev.ex-ample'),
      const AppUpdateTarget.android(applicationId: 'dev.example\n'),
      const AppUpdateTarget.android(applicationId: 'dev.éxample'),
      AppUpdateTarget.android(applicationId: 'a.${'b' * 199}'),
      const AppUpdateTarget.ios(storeId: ''),
      const AppUpdateTarget.ios(storeId: '1a'),
      const AppUpdateTarget.ios(storeId: '+123'),
      const AppUpdateTarget.ios(storeId: '١٢٣'),
      const AppUpdateTarget.ios(storeId: '123\n'),
      AppUpdateTarget.ios(storeId: '1' * 21),
    ]) {
      final reader = _Reader();
      final opener = _Opener();
      final capability = _capability(reader, target: target, opener: opener);
      final checked = await _check(capability);
      expect(checked.kind, AppUpdateCheckKind.invalid);
      expect(checked.code, 'update.invalid_target');
      expect(checked.candidate, isNull);
      final opened = await capability.openStore(_candidate);
      expect(opened.kind, AppUpdateOpenKind.invalid);
      expect(opened.code, 'update.invalid_target');
      expect(reader.paths, isEmpty);
      expect(opener.uris, isEmpty);
    }
  });

  test(
    'Android 200-character and iOS 20-digit identities are accepted',
    () async {
      final appId = 'A_.${'b' * 197}';
      final storeId = '0' * 20;
      expect(appId.length, 200);
      for (final (target, url) in [
        (
          AppUpdateTarget.android(applicationId: appId),
          'https://play.google.com/store/apps/details?id=$appId',
        ),
        (
          AppUpdateTarget.ios(storeId: storeId),
          'https://apps.apple.com/app/id$storeId',
        ),
      ]) {
        final reader = _Reader(body: _body(url: url));
        final result = await _check(_capability(reader, target: target));
        expect(result.code, 'update.available');
        expect(result.candidate!.storeUrl, url);
      }
    },
  );

  test(
    'metadata paths reject unsafe inputs locally without transport',
    () async {
      final reader = _Reader();
      final capability = _capability(reader);
      for (final path in [
        '',
        'relative',
        'https://example.invalid/update',
        '//example.invalid/x',
        '/a?token=x',
        '/a#x',
        '/a%2fb',
        '/a%20b',
        '/a\\b',
        '/a/./b',
        '/a/../b',
        '/.',
        '/..',
        '/a b',
        '/a\t',
        '/a\n',
        '/a\u0000',
        '/a\u0085',
        '/a\u00a0b',
        '/\ud800',
        '/${'a' * 2048}',
        '/${'é' * 1024}',
      ]) {
        final result = await capability.check(
          metadataPath: path,
          currentVersion: '1',
        );
        expect(result.kind, AppUpdateCheckKind.invalid, reason: path);
        expect(result.code, 'update.invalid_path', reason: path);
        expect(result.candidate, isNull);
      }
      expect(reader.paths, isEmpty);
    },
  );

  test(
    'metadata paths use exact UTF8 byte bounds and remain root-relative',
    () async {
      final reader = _Reader();
      for (final path in [
        '/',
        '/v1/update.json',
        '/a/.../b',
        '/${'a' * 2047}',
        '/${'é' * 1023}a',
      ]) {
        expect(utf8.encode(path).length, lessThanOrEqualTo(2048));
        expect(
          (await _capability(
            reader,
          ).check(metadataPath: path, currentVersion: '1')).code,
          'update.available',
        );
        expect(reader.paths.last, path);
      }
    },
  );

  test('invalid local versions fail before transport', () async {
    final reader = _Reader();
    for (final version in _invalidVersions) {
      final result = await _capability(reader)
          .check(metadataPath: '/update', currentVersion: version);
      expect(result.code, 'update.invalid_version', reason: version);
      expect(result.candidate, isNull);
    }
    expect(reader.paths, isEmpty);
  });

  test(
    'numeric BigInt version ordering zero-pads and accepts leading zeros',
    () async {
      for (final (current, latest, available) in [
        ('1.9', '1.10', true),
        ('1.10', '1.9', false),
        ('1', '1.0.0.0', false),
        ('01.002', '1.2', false),
        ('1.2', '0001.0002.0000.0001', true),
        ('2', '1.999', false),
        ('0', '0.0.0.0', false),
        ('0.0.0.0', '0.0.0.1', true),
        ('900719925474099200', '900719925474099201', true),
        ('999999999999999999', '999999999999999998', false),
      ]) {
        final reader = _Reader(body: _body(version: latest));
        final result = await _capability(reader)
            .check(metadataPath: '/update', currentVersion: current);
        expect(
          result.kind,
          available
              ? AppUpdateCheckKind.updateAvailable
              : AppUpdateCheckKind.current,
        );
        expect(result.code, available ? 'update.available' : 'update.current');
        expect(result.candidate?.latestVersion, available ? latest : null);
      }
    },
  );

  test(
    'remote versions have strict numeric component and total bounds',
    () async {
      for (final version in _invalidVersions) {
        final result = await _check(
          _capability(_Reader(body: _body(version: version))),
        );
        expect(result.kind, AppUpdateCheckKind.invalid);
        expect(result.code, 'update.invalid_version', reason: version);
        expect(result.candidate, isNull);
      }
      final largest = '${'9' * 18}.${'9' * 18}.${'9' * 18}.${'9' * 7}';
      expect(largest.length, 64);
      final result = await _check(
        _capability(_Reader(body: _body(version: largest))),
      );
      expect(result.code, 'update.available');
      expect(result.candidate!.latestVersion, largest);
    },
  );

  test(
    'all 2xx status codes accept valid metadata; non2xx is network failure',
    () async {
      for (final status in [200, 201, 204, 206, 299]) {
        expect(
          (await _check(_capability(_Reader(status: status)))).code,
          'update.available',
        );
      }
      for (final status in [100, 199, 300, 301, 400, 401, 404, 500, 599]) {
        final result = await _check(
          _capability(_Reader(status: status, body: [])),
        );
        expect(result.kind, AppUpdateCheckKind.failure);
        expect(result.code, 'update.network_failed');
        expect(result.candidate, isNull);
      }
    },
  );

  test(
    'out-of-range typed HTTP status is invalid metadata not remote text',
    () async {
      for (final status in [-1, 0, 99, 600, 1000]) {
        final result = await _check(_capability(_Reader(status: status)));
        expect(result.kind, AppUpdateCheckKind.invalid);
        expect(result.code, 'update.invalid_metadata');
        expect(result.candidate, isNull);
      }
    },
  );

  test(
    'response snapshots its list and exposes no mutable byte alias',
    () async {
      final bytes = List<int>.of(_body());
      final response = AppUpdateMetadataResponse(statusCode: 200, body: bytes);
      final expected = List<int>.of(bytes);
      bytes.fillRange(0, bytes.length, 0);
      expect(response.body, expected);
      expect(() => response.body[0] = 0, throwsUnsupportedError);
      expect(() => response.body.add(0), throwsUnsupportedError);
      final pending = Completer<AppUpdateMetadataResponse>();
      final reader = _Reader()..action = (_) => pending.future;
      final checked = _check(_capability(reader));
      pending.complete(response);
      bytes.clear();
      expect((await checked).code, 'update.available');
    },
  );

  test(
    'body exact 16KiB boundary succeeds and one byte over is rejected',
    () async {
      final base = _body();
      final exact = [...base, ...List<int>.filled(16384 - base.length, 0x20)];
      expect(exact.length, 16384);
      expect(
        (await _check(_capability(_Reader(body: exact)))).code,
        'update.available',
      );
      final result = await _check(_capability(_Reader(body: [...exact, 0x20])));
      expect(result.kind, AppUpdateCheckKind.invalid);
      expect(result.code, 'update.response_too_large');
      expect(result.candidate, isNull);
    },
  );

  test('empty malformed UTF8 and nonbyte integer bodies fail closed', () async {
    for (final body in <List<int>>[
      [],
      [0xff],
      [0xc0, 0xaf],
      [0xed, 0xa0, 0x80],
      [-1],
      [256],
      [..._body(), -1],
      [..._body(), 256],
      utf8.encode('{'),
      utf8.encode('private backend error'),
    ]) {
      final result = await _check(_capability(_Reader(body: body)));
      expect(result.kind, AppUpdateCheckKind.invalid);
      expect(result.code, 'update.invalid_metadata');
      expect(result.candidate, isNull);
      expect(result.toString(), isNot(contains('private backend')));
    }
  });

  test('JSON must have exactly the two case-sensitive string fields', () async {
    for (final metadata in <Object?>[
      null,
      [],
      'text',
      1,
      true,
      {},
      {'version': '2'},
      {'storeURL': _androidUrl},
      {'version': 2, 'storeURL': _androidUrl},
      {'version': '2', 'storeURL': null},
      {'version': [], 'storeURL': _androidUrl},
      {'Version': '2', 'storeURL': _androidUrl},
      {'version': '2', 'storeUrl': _androidUrl},
      {'version': '2', 'storeURL': _androidUrl, 'token': 'private'},
    ]) {
      final result = await _check(
        _capability(_Reader(body: utf8.encode(jsonEncode(metadata)))),
      );
      expect(result.code, 'update.invalid_metadata');
      expect(result.candidate, isNull);
    }
  });

  test(
    'both canonical stores accept exact identity with optional 443',
    () async {
      for (final (target, url) in [(_android, _androidUrl), (_ios, _iosUrl)]) {
        for (final raw in [url, url.replaceFirst('.com/', '.com:443/')]) {
          final reader = _Reader(body: _body(url: raw));
          final opener = _Opener();
          final capability = _capability(
            reader,
            target: target,
            opener: opener,
          );
          final result = await _check(capability);
          expect(result.code, 'update.available');
          expect(result.candidate!.storeUrl, raw);
          expect(opener.uris, isEmpty);
          expect(
            (await capability.openStore(result.candidate!)).code,
            'update.opened',
          );
          expect(
            opener.uris.single.host,
            target.store == AppUpdateStore.android
                ? 'play.google.com'
                : 'apps.apple.com',
          );
          expect(opener.uris.single.port, 443);
          expect(reader.paths, hasLength(1));
        }
      }
    },
  );

  test(
    'canonical wrong identity is distinct and not numerically coerced',
    () async {
      for (final (target, url) in [
        (
          _android,
          _androidUrl.replaceFirst('dev.example.product', 'dev.other.product'),
        ),
        (
          _android,
          _androidUrl.replaceFirst(
            'dev.example.product',
            'Dev.example.product',
          ),
        ),
        (_ios, 'https://apps.apple.com/app/id123456789012345678'),
        (_ios, 'https://apps.apple.com/app/id00123456789012345679'),
      ]) {
        final opener = _Opener();
        final capability = _capability(
          _Reader(body: _body(url: url)),
          target: target,
          opener: opener,
        );
        final checked = await _check(capability);
        expect(checked.code, 'update.identity_mismatch');
        expect(checked.candidate, isNull);
        final opened = await capability.openStore(
          AppUpdateCandidate(latestVersion: '2', storeUrl: url),
        );
        expect(opened.kind, AppUpdateOpenKind.invalid);
        expect(opened.code, 'update.identity_mismatch');
        expect(opener.uris, isEmpty);
      }
    },
  );

  test(
    'unsafe Android raw URLs fail check and forged-candidate opening',
    () async {
      for (final url in [
        '',
        'http://play.google.com/store/apps/details?id=dev.example.product',
        'HTTPS://play.google.com/store/apps/details?id=dev.example.product',
        _androidUrl.replaceFirst('play.google.com', 'PLAY.google.com'),
        _androidUrl.replaceFirst('play.google.com', 'play.google.com.'),
        _androidUrl.replaceFirst(
          'play.google.com',
          'play.google.com.evil.invalid',
        ),
        _androidUrl.replaceFirst(
          'play.google.com',
          'user:password@play.google.com',
        ),
        _androidUrl.replaceFirst('play.google.com', 'play.google.com:444'),
        _androidUrl.replaceFirst('play.google.com', 'play.google.com:0443'),
        _androidUrl.replaceFirst('play.google.com', 'play%2egoogle.com'),
        _androidUrl.replaceFirst(
          'play.google.com',
          'play.google.com:%34%34%33',
        ),
        _androidUrl.replaceFirst('/store/', '/STORE/'),
        _androidUrl.replaceFirst('/store/', '/%73tore/'),
        _androidUrl.replaceFirst('/store/', '/a/../store/'),
        _androidUrl.replaceFirst('details?', 'details/?'),
        _androidUrl.replaceFirst('?id=', '?ID='),
        _androidUrl.replaceFirst('?id=', '?%69d='),
        _androidUrl.replaceFirst('dev.example', 'dev%2eexample'),
        '$_androidUrl&token=private',
        '$_androidUrl&id=dev.example.product',
        '$_androidUrl#',
        '$_androidUrl#secret',
        '$_androidUrl ',
        '$_androidUrl\n',
        '$_androidUrl\u0085',
        '$_androidUrl\ud800',
        '/store/apps/details?id=dev.example.product',
        'https://play.google.com/store/apps/details?id=a.${'b' * 199}',
        'https://play.google.com/store/apps/details?id=a.${'b' * 500}',
        _iosUrl,
      ]) {
        final reader = _Reader(body: _body(url: url));
        final opener = _Opener();
        final capability = _capability(reader, opener: opener);
        expect(
          (await _check(capability)).code,
          'update.invalid_store_url',
          reason: url,
        );
        expect(
          (await capability.openStore(
            AppUpdateCandidate(latestVersion: '2', storeUrl: url),
          )).code,
          'update.invalid_store_url',
          reason: url,
        );
        expect(reader.paths, hasLength(1));
        expect(opener.uris, isEmpty);
      }
    },
  );

  test(
    'iOS locale encoded path extra query and malformed IDs are unsafe',
    () async {
      for (final url in [
        _iosUrl.replaceFirst('/app/', '/us/app/'),
        _iosUrl.replaceFirst('/app/', '/app/example-name/'),
        _iosUrl.replaceFirst('/app/', '/APP/'),
        _iosUrl.replaceFirst('/app/', '/%61pp/'),
        _iosUrl.replaceFirst('id00', 'id%300'),
        _iosUrl.replaceFirst('apps.apple.com', 'apps.apple.com@evil.invalid'),
        _iosUrl.replaceFirst('apps.apple.com', 'apps.apple.com:80'),
        '$_iosUrl/',
        '$_iosUrl?mt=8',
        '$_iosUrl#fragment',
        'https://apps.apple.com/app/id',
        'https://apps.apple.com/app/id+123',
        'https://apps.apple.com/app/id${'1' * 21}',
        _androidUrl,
      ]) {
        final opener = _Opener();
        final capability = _capability(
          _Reader(body: _body(url: url)),
          target: _ios,
          opener: opener,
        );
        expect(
          (await _check(capability)).code,
          'update.invalid_store_url',
          reason: url,
        );
        expect(
          (await capability.openStore(
            AppUpdateCandidate(latestVersion: '2', storeUrl: url),
          )).code,
          'update.invalid_store_url',
          reason: url,
        );
        expect(opener.uris, isEmpty);
      }
    },
  );

  test('current outcome still validates metadata identity and URL', () async {
    for (final (url, code) in [
      (
        'https://play.google.com/store/apps/details?id=dev.other.product',
        'update.identity_mismatch',
      ),
      ('$_androidUrl&token=private', 'update.invalid_store_url'),
    ]) {
      final result = await _check(
        _capability(
          _Reader(
            body: _body(version: '0', url: url),
          ),
        ),
      );
      expect(result.code, code);
      expect(result.candidate, isNull);
    }
  });

  test(
    'opening revalidates forged versions and a candidate from another target',
    () async {
      final reader = _Reader();
      final opener = _Opener();
      final capability = _capability(reader, opener: opener);
      for (final version in _invalidVersions) {
        final result = await capability.openStore(
          AppUpdateCandidate(latestVersion: version, storeUrl: _androidUrl),
        );
        expect(result.code, 'update.invalid_version');
      }
      expect(reader.paths, isEmpty);
      expect(opener.uris, isEmpty);
      final candidate = (await _check(capability)).candidate!;
      final other = _capability(
        reader,
        target: const AppUpdateTarget.android(applicationId: 'org.another.app'),
        opener: opener,
      );
      expect(
        (await other.openStore(candidate)).code,
        'update.identity_mismatch',
      );
      expect(reader.paths, hasLength(1));
      expect(opener.uris, isEmpty);
    },
  );

  test(
    'reader sync async and response-factory exceptions use fixed failure',
    () async {
      for (final action in <Future<AppUpdateMetadataResponse> Function(String)>[
        (_) => throw StateError('private backend password'),
        (_) async => throw StateError('private backend password'),
        (_) async =>
            AppUpdateMetadataResponse(statusCode: 200, body: _ThrowingBytes()),
      ]) {
        final reader = _Reader()..action = action;
        final opener = _Opener();
        final result = await _check(_capability(reader, opener: opener));
        expect(result.kind, AppUpdateCheckKind.failure);
        expect(result.code, 'update.network_failed');
        expect(result.candidate, isNull);
        expect(result.toString(), isNot(contains('private')));
        expect(opener.uris, isEmpty);
      }
    },
  );

  test(
    'opener false is no handler and exceptions are fixed open failures',
    () async {
      final reader = _Reader();
      final noHandler = _Opener()..accepted = false;
      final result = await _capability(
        reader,
        opener: noHandler,
      ).openStore(_candidate);
      expect(result.kind, AppUpdateOpenKind.unavailable);
      expect(result.code, 'update.no_handler');
      for (final action in <Future<bool> Function(Uri)>[
        (_) => throw StateError('private opener details'),
        (_) async => throw StateError('private opener details'),
      ]) {
        final opener = _Opener()..action = action;
        final failed = await _capability(
          reader,
          opener: opener,
        ).openStore(_candidate);
        expect(failed.kind, AppUpdateOpenKind.failure);
        expect(failed.code, 'update.open_failed');
        expect(failed.toString(), isNot(contains('private')));
      }
      expect(reader.paths, isEmpty);
    },
  );
}

final _invalidVersions = [
  '',
  'v1',
  '1-beta',
  '1+build',
  '-1',
  '+1',
  '1.',
  '.1',
  '1..2',
  '1.2.3.4.5',
  '1 2',
  '1\n',
  '１',
  '١',
  '1\u0000',
  '1' * 19,
  '${'1' * 18}.${'1' * 18}.${'1' * 18}.${'1' * 8}',
];

List<int> _body({String version = '2', String url = _androidUrl}) =>
    utf8.encode(jsonEncode({'version': version, 'storeURL': url}));

Future<AppUpdateCheckResult> _check(StarterAppUpdateCapability capability) =>
    capability.check(
      metadataPath: '/updates/current.json',
      currentVersion: '1',
    );

StarterAppUpdateCapability _capability(
  _Reader reader, {
  AppUpdateTarget target = _android,
  _Opener? opener,
}) => StarterAppUpdateCapability(
  enabled: true,
  target: target,
  reader: reader,
  opener: opener,
);

final class _Reader implements AppUpdateMetadataReader {
  _Reader({this.status = 200, List<int>? body}) : body = body ?? _body();

  final int status;
  final List<int> body;
  final paths = <String>[];
  Future<AppUpdateMetadataResponse> Function(String)? action;

  @override
  Future<AppUpdateMetadataResponse> read(String path) {
    paths.add(path);
    return action?.call(path) ??
        Future.value(AppUpdateMetadataResponse(statusCode: status, body: body));
  }
}

final class _Opener implements AppUpdateStoreOpener {
  final uris = <Uri>[];
  bool accepted = true;
  Future<bool> Function(Uri)? action;

  @override
  Future<bool> open(Uri uri) {
    uris.add(uri);
    return action?.call(uri) ?? Future.value(accepted);
  }
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
