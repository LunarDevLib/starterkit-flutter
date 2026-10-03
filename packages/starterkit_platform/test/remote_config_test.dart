import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:starterkit_platform/starterkit_platform.dart';

const _host = 'config.example.test';
const _defaults = {
  'welcome': RemoteValue.text('local'),
  'badge': RemoteValue.boolean(false),
  'limit': RemoteValue.integer(3),
  'localOnly': RemoteValue.boolean(true),
};
const _schema = {
  'welcome': RemoteValueType.text,
  'badge': RemoteValueType.boolean,
  'limit': RemoteValueType.integer,
};

void main() {
  test('closed typed values and initial disabled service are inert', () async {
    const boolean = RemoteValue.boolean(true);
    const integer = RemoteValue.integer(2);
    const text = RemoteValue.text('hello');
    expect(boolean.type, RemoteValueType.boolean);
    expect(boolean.value, true);
    expect(integer.type, RemoteValueType.integer);
    expect(integer.value, 2);
    expect(text.type, RemoteValueType.text);
    expect(text.value, 'hello');
    final reader = _Reader();
    final clock = _Clock();
    final service = _service(reader, clock, enabled: false);
    expect(service.snapshot.version, 0);
    expect(service.snapshot.expiresAt, isNull);
    expect(service.snapshot.values, _defaults);
    expect(service.flags.value('welcome')!.value, 'local');
    expect(service.flags.value('missing'), isNull);
    expect((await service.fetch()).kind, RemoteConfigFetchKind.disabled);
    expect((await service.fetch()).code, 'remote.disabled');
    service.reset();
    expect(reader.getters, 0);
    expect(reader.paths, isEmpty);
    expect(clock.calls, 0);
    expect(StarterRemoteConfigService().snapshot.values, isEmpty);
  });

  test(
    'missing reader and enabled initial flags do not call the clock',
    () async {
      final clock = _Clock();
      final service = StarterRemoteConfigService(
        enabled: true,
        defaults: _defaults,
        now: clock.now,
      );
      expect(service.flags.value('badge')!.value, false);
      final result = await service.fetch();
      expect(result.kind, RemoteConfigFetchKind.unavailable);
      expect(result.code, 'remote.reader_not_configured');
      expect(result.snapshot, isNull);
      expect(clock.calls, 0);
    },
  );

  test(
    'successful exact schema applies typed immutable snapshot once',
    () async {
      final clock = _Clock();
      final reader = _Reader();
      reader.response = _payload(
        clock,
        values: {'welcome': 'remote', 'badge': true, 'limit': 8},
      );
      final service = _service(reader, clock);
      final original = service.snapshot;
      final result = await service.fetch();
      expect(result.kind, RemoteConfigFetchKind.applied);
      expect(result.code, 'remote.applied');
      expect(identical(result.snapshot, service.snapshot), true);
      expect(result.snapshot!.version, 1);
      expect(result.snapshot!.expiresAt!.isUtc, true);
      expect(result.snapshot!.values['welcome']!.value, 'remote');
      expect(result.snapshot!.values['badge']!.value, true);
      expect(result.snapshot!.values['limit']!.value, 8);
      expect(result.snapshot!.values['localOnly']!.value, true);
      expect(original.version, 0);
      expect(original.values, _defaults);
      expect(() => result.snapshot!.values.clear(), throwsUnsupportedError);
      expect(reader.getters, 1);
      expect(reader.paths, ['config/snapshot']);
      expect(clock.calls, 1);
    },
  );

  test('constructor snapshots defaults schema and host inputs', () async {
    final clock = _Clock();
    final reader = _Reader()..response = _payload(clock);
    final defaults = {..._defaults};
    final schema = {..._schema};
    final hosts = {_host};
    final service = _service(
      reader,
      clock,
      defaults: defaults,
      schema: schema,
      hosts: hosts,
    );
    defaults.clear();
    schema.clear();
    hosts.clear();
    expect(service.snapshot.values, _defaults);
    expect((await service.fetch()).kind, RemoteConfigFetchKind.applied);
    expect(service.flags.value('welcome')!.value, 'remote');
    service.reset();
    expect(service.snapshot.values, _defaults);
  });

  test('response and diagnostic snapshot defensively copy maps and bytes', () {
    final bytes = [1, 2, 3];
    final response = RemoteConfigResponse(statusCode: 200, body: bytes);
    bytes.clear();
    expect(response.body, [1, 2, 3]);
    expect(() => response.body[0] = 0, throwsUnsupportedError);
    final values = {..._defaults};
    final snapshot = RemoteConfigSnapshot(
      version: 9,
      expiresAt: DateTime.utc(2026),
      values: values,
    );
    values.clear();
    expect(snapshot.values, _defaults);
    expect(() => snapshot.values.clear(), throwsUnsupportedError);
  });

  test('unsafe raw relative endpoints fail locally with zero hooks', () async {
    for (final endpoint in [
      '',
      '/',
      '/config',
      'config/',
      'config//snapshot',
      '.',
      '..',
      'a/../b',
      'a/./b',
      '//evil.test/x',
      'https://evil.test/x',
      'config?',
      'config#',
      'config%2fsnapshot',
      'config\\snapshot',
      'config snapshot',
      'config\n',
      'é',
      'x' * 2049,
    ]) {
      final clock = _Clock();
      final reader = _Reader();
      final result = await _service(reader, clock, endpoint: endpoint).fetch();
      expect(result.kind, RemoteConfigFetchKind.invalid);
      expect(result.code, 'remote.invalid_configuration');
      expect(reader.getters, 0);
      expect(reader.paths, isEmpty);
      expect(clock.calls, 0);
    }
  });

  test(
    'invalid hosts keys defaults or overlapping schema fail before reader',
    () async {
      final configs =
          <
            ({
              Map<String, RemoteValue> defaults,
              Map<String, RemoteValueType> schema,
              Set<String> hosts,
            })
          >[
            (defaults: _defaults, schema: _schema, hosts: {}),
            for (final host in [
              '*',
              'UPPER.test',
              'a..test',
              '${'a' * 64}.test',
              'a' * 254,
            ])
              (defaults: _defaults, schema: _schema, hosts: {_host, host}),
            (
              defaults: _defaults,
              schema: _schema,
              hosts: {_host, for (var i = 0; i < 16; i++) 'host$i.test'},
            ),
            for (final key in ['1bad', 'bad/key', 'bad key', 'é', 'A' * 65])
              (
                defaults: {..._defaults, key: const RemoteValue.boolean(true)},
                schema: _schema,
                hosts: {_host},
              ),
            (
              defaults: {
                for (var i = 0; i < 65; i++)
                  'key$i': const RemoteValue.boolean(false),
              },
              schema: _schema,
              hosts: {_host},
            ),
            (
              defaults: _defaults,
              schema: {
                for (var i = 0; i < 65; i++) 'key$i': RemoteValueType.boolean,
              },
              hosts: {_host},
            ),
            (
              defaults: _defaults,
              schema: {'badge': RemoteValueType.text},
              hosts: {_host},
            ),
            (
              defaults: {..._defaults, 'welcome': RemoteValue.text('é' * 65)},
              schema: _schema,
              hosts: {_host},
            ),
            (
              defaults: {
                ..._defaults,
                'welcome': const RemoteValue.text('\ud800'),
              },
              schema: _schema,
              hosts: {_host},
            ),
          ];
      for (final config in configs) {
        final clock = _Clock();
        final reader = _Reader();
        final service = _service(
          reader,
          clock,
          defaults: config.defaults,
          schema: config.schema,
          hosts: config.hosts,
        );
        expect((await service.fetch()).code, 'remote.invalid_configuration');
        expect(service.snapshot.values, config.defaults);
        expect(reader.getters, 0);
        expect(reader.paths, isEmpty);
        expect(clock.calls, 0);
      }
    },
  );

  test(
    'protected schema names reject casing separators and substring bypasses',
    () async {
      for (final key in [
        'endpoint',
        'Host',
        'URL',
        'permission',
        'authorization',
        'auth',
        'token',
        'secret',
        'credential',
        'security',
        'trust',
        'certificate',
        'pinning',
        'tls',
        'new.en_d-po.Int',
        'UI.T-L_S.Mode',
        'preToKeNpost',
      ]) {
        final clock = _Clock();
        final reader = _Reader();
        final result = await _service(
          reader,
          clock,
          schema: {key: RemoteValueType.boolean},
        ).fetch();
        expect(result.code, 'remote.invalid_configuration');
        expect(reader.getters, 0);
        expect(reader.paths, isEmpty);
        expect(clock.calls, 0);
      }
    },
  );

  test('supplied raw base ambiguity credentials encoding and ports reject before read', () async {
    for (final raw in [
      'http://config.example.test/api/',
      'HTTPS://config.example.test/api/',
      'https://CONFIG.example.test/api/',
      'https://config.example.test./api/',
      'https://user:pass@config.example.test/api/',
      'https://config.example.test/api/?',
      'https://config.example.test/api/#',
      'https://config.example.test/%61pi/',
      'https://config.example.test/a/../api/',
      'https://config.example.test/a/./api/',
      'https://config.example.test//api/',
      'https://config.example.test/api//',
      'https://config.example.test/api\\x',
      'https://config.example.test:0/api/',
      'https://config.example.test:65536/api/',
      'https://config.example.test:123456/api/',
      'https://evil.test/api/',
      'https://config.example.test/é',
      'https://config.example.test/api/\n',
    ]) {
      final clock = _Clock();
      final reader = _Reader()..base = _RawUri(raw);
      expect(
        (await _service(reader, clock).fetch()).code,
        'remote.invalid_configuration',
      );
      expect(reader.getters, 1);
      expect(reader.paths, isEmpty);
      expect(clock.calls, 0);
    }
  });

  test('safe supplied base directory and endpoint bounds preserve relative request', () async {
    for (final raw in [
      'https://config.example.test',
      'https://config.example.test/',
      'https://config.example.test/api',
      'https://config.example.test/api/',
      'https://config.example.test:65535/api/',
    ]) {
      final clock = _Clock();
      final reader = _Reader()
        ..base = Uri.parse(raw)
        ..response = _payload(clock);
      expect(
        (await _service(
          reader,
          clock,
          endpoint: 'safe/nested-snapshot',
        ).fetch()).code,
        'remote.applied',
      );
      expect(reader.paths, ['safe/nested-snapshot']);
      expect(reader.getters, 1);
    }
    final clock = _Clock();
    final reader = _Reader()..response = _payload(clock);
    const prefix = 'https://$_host/api/';
    final endpoint = 'x' * (2048 - prefix.length);
    expect(
      (await _service(reader, clock, endpoint: endpoint).fetch()).code,
      'remote.applied',
    );
    final oversized = _Reader();
    expect(
      (await _service(oversized, clock, endpoint: '${endpoint}x').fetch()).code,
      'remote.invalid_configuration',
    );
    expect(oversized.paths, isEmpty);
  });

  test(
    'Uri supplied serialization cannot recover original normalized spelling',
    () async {
      final clock = _Clock();
      final reader = _Reader()
        ..base = Uri.parse('https://CONFIG.example.test/x/../api/')
        ..response = _payload(clock);
      expect(reader.base.toString(), 'https://$_host/api/');
      expect((await _service(reader, clock).fetch()).code, 'remote.applied');
    },
  );

  test(
    'HTTP status byte units UTF8 and malformed JSON return fixed failures',
    () async {
      for (final response in [
        for (final status in [0, 99, 600])
          RemoteConfigResponse(statusCode: status, body: []),
        for (final bytes in <List<int>>[
          [-1],
          [256],
          [0xff],
          [0xc0, 0xaf],
          [0xed, 0xa0, 0x80],
          [],
          utf8.encode('{'),
        ])
          RemoteConfigResponse(statusCode: 200, body: bytes),
      ]) {
        final clock = _Clock();
        final reader = _Reader()..response = response;
        final result = await _service(reader, clock).fetch();
        expect(result.kind, RemoteConfigFetchKind.failure);
        expect(result.code, 'remote.invalid_response');
        expect(result.snapshot, isNull);
        expect(reader.paths, hasLength(1));
        expect(clock.calls, 0);
      }
      for (final status in [100, 199, 300, 401, 500, 599]) {
        final clock = _Clock();
        final reader = _Reader()
          ..response = RemoteConfigResponse(statusCode: status, body: []);
        expect(
          (await _service(reader, clock).fetch()).code,
          'remote.transport_failed',
        );
        expect(reader.paths, hasLength(1));
      }
    },
  );

  test('16KiB exact response boundary passes and larger body fails', () async {
    final clock = _Clock();
    final bytes = _payload(clock).body;
    final exact = [...bytes, ...List<int>.filled(16384 - bytes.length, 0x20)];
    final reader = _Reader()
      ..response = RemoteConfigResponse(statusCode: 299, body: exact);
    final service = _service(reader, clock);
    expect((await service.fetch()).code, 'remote.applied');
    final prior = service.snapshot;
    reader.response = RemoteConfigResponse(
      statusCode: 200,
      body: [...exact, 0x20],
    );
    final result = await service.fetch();
    expect(result.kind, RemoteConfigFetchKind.failure);
    expect(result.code, 'remote.response_too_large');
    expect(identical(service.snapshot, prior), true);
  });

  test(
    'exact top-level schema refuses missing unknown or wrong fields',
    () async {
      final clock = _Clock();
      final expires = _seconds(clock.instant) + 60;
      for (final body in <Object?>[
        null,
        [],
        'text',
        {},
        {'version': 1, 'values': {}},
        {'version': 1, 'expires_at': expires},
        {'expires_at': expires, 'values': {}},
        {'version': 1, 'expires_at': expires, 'values': {}, 'extra': true},
        {'version': 1, 'expires_at': expires, 'values': []},
      ]) {
        final reader = _Reader()..response = _json(body);
        final service = _service(reader, clock);
        expect((await service.fetch()).code, 'remote.invalid_schema');
        expect(service.snapshot.version, 0);
        expect(clock.calls, 0);
      }
    },
  );

  test('positive signed64 version requires integer without coercion or rollback policy', () async {
    final clock = _Clock();
    final reader = _Reader();
    final service = _service(reader, clock);
    for (final version in [null, true, false, '1', 1.0, 0, -1]) {
      reader.response = _json({
        'version': version,
        'expires_at': _seconds(clock.instant) + 60,
        'values': {},
      });
      expect((await service.fetch()).code, 'remote.invalid_schema');
    }
    reader.response = _json({
      'version': 9223372036854775807,
      'expires_at': _seconds(clock.instant) + 60,
      'values': {},
    });
    expect((await service.fetch()).snapshot!.version, 9223372036854775807);
    reader.response = _payload(clock, version: 1);
    expect((await service.fetch()).snapshot!.version, 1);
    reader.response = _raw(
      '{"version":9223372036854775808,"expires_at":${_seconds(clock.instant) + 60},"values":{}}',
    );
    expect((await service.fetch()).code, 'remote.invalid_schema');
  });

  test('finite epoch seconds int or double and UTC conversion only', () async {
    final clock = _Clock();
    final reader = _Reader();
    for (final expiry in [
      null,
      true,
      false,
      '2026-01-01T00:00:00Z',
      '1700000060',
      [],
      {},
      1e300,
      -1e300,
    ]) {
      reader.response = _json({
        'version': 1,
        'expires_at': expiry,
        'values': {},
      });
      expect(
        (await _service(reader, clock).fetch()).code,
        'remote.invalid_schema',
      );
    }
    for (final raw in ['1e999', '-1e999']) {
      reader.response = _raw('{"version":1,"expires_at":$raw,"values":{}}');
      expect(
        (await _service(reader, clock).fetch()).code,
        'remote.invalid_schema',
      );
    }
    for (final expiry in [
      _seconds(clock.instant) + 60,
      _seconds(clock.instant) + 60.25,
    ]) {
      reader.response = _json({
        'version': 1,
        'expires_at': expiry,
        'values': {},
      });
      final result = await _service(reader, clock).fetch();
      expect(result.code, 'remote.applied');
      expect(result.snapshot!.expiresAt!.isUtc, true);
      expect(
        result.snapshot!.expiresAt!.microsecondsSinceEpoch,
        (expiry * 1000000).round(),
      );
    }
  });

  test(
    'expiry is strictly future and at most one year without duration overflow',
    () async {
      final clock = _Clock();
      final reader = _Reader();
      for (final seconds in [-1, 0, 31536000, 31536000.001]) {
        reader.response = _payload(clock, ttl: seconds);
        final result = await _service(reader, clock).fetch();
        expect(
          result.code,
          seconds <= 0
              ? 'remote.expired'
              : seconds == 31536000
              ? 'remote.applied'
              : 'remote.invalid_schema',
        );
      }
      clock.instant = DateTime.fromMicrosecondsSinceEpoch(
        -8640000000000000000,
        isUtc: true,
      );
      reader.response = _json({
        'version': 1,
        'expires_at': 8640000000000,
        'values': {},
      });
      expect(
        (await _service(reader, clock).fetch()).code,
        'remote.invalid_schema',
      );
    },
  );

  test('remote values use exact schema types with no coercion', () async {
    final clock = _Clock();
    final reader = _Reader();
    for (final values in [
      {'badge': 1},
      {'badge': 'true'},
      {'badge': null},
      {'limit': 1.0},
      {'limit': true},
      {'limit': '1'},
      {'welcome': 1},
      {'welcome': []},
      {
        'welcome': {'nested': 'x'},
      },
      {'welcome': null},
    ]) {
      reader.response = _payload(clock, values: values);
      expect(
        (await _service(reader, clock).fetch()).code,
        'remote.invalid_schema',
      );
    }
    for (final integer in [-9223372036854775808, 9223372036854775807]) {
      reader.response = _payload(clock, values: {'limit': integer});
      expect(
        (await _service(
          reader,
          clock,
        ).fetch()).snapshot!.values['limit']!.value,
        integer,
      );
    }
    reader.response = _raw(
      '{"version":1,"expires_at":${_seconds(clock.instant) + 60},"values":{"limit":-9223372036854775809}}',
    );
    expect(
      (await _service(reader, clock).fetch()).code,
      'remote.invalid_schema',
    );
  });

  test('text128 UTF8 controls and malformed Unicode are bounded', () async {
    final clock = _Clock();
    final reader = _Reader();
    for (final text in ['', 'x' * 128, 'é' * 64, '😀' * 32]) {
      reader.response = _payload(clock, values: {'welcome': text});
      expect(
        (await _service(
          reader,
          clock,
        ).fetch()).snapshot!.values['welcome']!.value,
        text,
      );
    }
    for (final text in [
      'x' * 129,
      'é' * 65,
      '😀' * 33,
      'a\n',
      '\u0000',
      '\u007f',
      '\u0085',
      '\ud800',
      '\udc00',
    ]) {
      reader.response = _payload(clock, values: {'welcome': text});
      expect(
        (await _service(reader, clock).fetch()).code,
        'remote.invalid_schema',
      );
    }
  });

  test('values cardinality keys unknown protected and decoded variants reject whole payload', () async {
    final clock = _Clock();
    final reader = _Reader();
    for (final key in [
      'missing',
      'localOnly',
      '1bad',
      'bad/key',
      'é',
      'A' * 65,
      'end.point',
      'TOK_EN',
      'preAuthPost',
    ]) {
      reader.response = _payload(
        clock,
        values: {'welcome': 'candidate', key: true},
      );
      final service = _service(reader, clock);
      expect((await service.fetch()).code, 'remote.invalid_schema');
      expect(service.flags.value('welcome')!.value, 'local');
    }
    reader.response = _raw(
      '{"version":1,"expires_at":${_seconds(clock.instant) + 60},"values":{"\\u0074oken":true}}',
    );
    expect(
      (await _service(reader, clock).fetch()).code,
      'remote.invalid_schema',
    );
    final schema = {
      for (var i = 0; i < 64; i++) 'key$i': RemoteValueType.boolean,
    };
    reader.response = _payload(
      clock,
      values: {for (var i = 0; i < 64; i++) 'key$i': true},
    );
    expect(
      (await _service(
        reader,
        clock,
        defaults: {},
        schema: schema,
      ).fetch()).snapshot!.values,
      hasLength(64),
    );
    reader.response = _payload(
      clock,
      values: {for (var i = 0; i < 65; i++) 'key$i': true},
    );
    expect(
      (await _service(
        reader,
        clock,
        defaults: {},
        schema: schema,
      ).fetch()).code,
      'remote.invalid_schema',
    );
  });

  test('malformed latest payload preserves entire prior snapshot not partial items', () async {
    final clock = _Clock();
    final reader = _Reader()..response = _payload(clock);
    final service = _service(reader, clock);
    await service.fetch();
    final prior = service.snapshot;
    reader.response = _payload(
      clock,
      values: {'welcome': 'partial', 'limit': 'wrong'},
    );
    final result = await service.fetch();
    expect(result.code, 'remote.invalid_schema');
    expect(result.snapshot, isNull);
    expect(identical(service.snapshot, prior), true);
    expect(service.flags.value('welcome')!.value, 'remote');
  });

  test('fresh replacement restores omitted original defaults not previous remote data', () async {
    final clock = _Clock();
    final reader = _Reader()
      ..response = _payload(clock, values: {'welcome': 'first', 'badge': true});
    final service = _service(reader, clock);
    final first = (await service.fetch()).snapshot!;
    reader.response = _payload(clock, version: 2, values: {'limit': 10});
    await service.fetch();
    expect(service.snapshot.values['welcome']!.value, 'local');
    expect(service.snapshot.values['badge']!.value, false);
    expect(service.snapshot.values['limit']!.value, 10);
    expect(first.values['welcome']!.value, 'first');
    reader.response = _payload(clock, values: {});
    await service.fetch();
    expect(service.snapshot.values, _defaults);
  });

  test(
    'flag reads fall back exactly at expiry retaining diagnostic snapshot',
    () async {
      final clock = _Clock();
      final reader = _Reader()..response = _payload(clock);
      final service = _service(reader, clock);
      await service.fetch();
      final stored = service.snapshot;
      clock.instant = stored.expiresAt!.subtract(
        const Duration(microseconds: 1),
      );
      expect(service.flags.value('welcome')!.value, 'remote');
      clock.instant = stored.expiresAt!;
      expect(service.flags.value('welcome')!.value, 'local');
      clock.instant = clock.instant.add(const Duration(days: 1));
      expect(service.flags.value('welcome')!.value, 'local');
      expect(service.flags.value('missing'), isNull);
      expect(identical(service.snapshot, stored), true);
      expect(stored.values['welcome']!.value, 'remote');
      expect(reader.paths, hasLength(1));
    },
  );

  test(
    'clock errors fail fetch and flag reads safely without raw prose',
    () async {
      final clock = _Clock();
      final reader = _Reader()..response = _payload(clock);
      final service = _service(reader, clock);
      await service.fetch();
      final prior = service.snapshot;
      clock.action = () => throw StateError('private clock details');
      expect(service.flags.value('welcome')!.value, 'local');
      final result = await service.fetch();
      expect(result.kind, RemoteConfigFetchKind.failure);
      expect(result.code, 'remote.clock_failed');
      expect(result.snapshot, isNull);
      expect(result.toString(), isNot(contains('private')));
      expect(identical(service.snapshot, prior), true);
    },
  );

  test('reader getter read sync async and response factory errors normalize with no retry', () async {
    final clock = _Clock();
    final getter = _Reader()
      ..getterAction = () => throw StateError('private base');
    expect(
      (await _service(getter, clock).fetch()).code,
      'remote.transport_failed',
    );
    expect(getter.paths, isEmpty);
    for (final asyncError in [false, true]) {
      final reader = _Reader()
        ..action = (_) => asyncError
            ? Future.error(StateError('private read'))
            : throw StateError('private read');
      final result = await _service(reader, clock).fetch();
      expect(result.code, 'remote.transport_failed');
      expect(result.snapshot, isNull);
      expect(result.toString(), isNot(contains('private')));
      expect(reader.paths, hasLength(1));
      expect(reader.getters, 1);
    }
    final factoryFailure = _Reader()
      ..action = (_) async =>
          RemoteConfigResponse(statusCode: 200, body: _ThrowingBytes());
    expect(
      (await _service(factoryFailure, clock).fetch()).code,
      'remote.transport_failed',
    );
    expect(factoryFailure.paths, hasLength(1));
    expect(clock.calls, 0);
  });

  test(
    'newest-started apply wins even when older success finishes last',
    () async {
      final clock = _Clock();
      final reader = _Reader();
      final pending = <Completer<RemoteConfigResponse>>[];
      reader.action = (_) {
        final c = Completer<RemoteConfigResponse>();
        pending.add(c);
        return c.future;
      };
      final service = _service(reader, clock);
      final older = service.fetch();
      final newer = service.fetch();
      pending[1].complete(_payload(clock, version: 2));
      expect((await newer).snapshot!.version, 2);
      final applied = service.snapshot;
      pending[0].complete(_payload(clock, version: 1));
      expect((await older).kind, RemoteConfigFetchKind.superseded);
      expect(identical(service.snapshot, applied), true);
      expect(clock.calls, 1);
      expect(reader.paths, hasLength(2));
    },
  );

  test('latest invalid or failure blocks older success and preserves prior until expiry', () async {
    for (final failure in ['schema', 'network', 'base']) {
      final clock = _Clock();
      final reader = _Reader()..response = _payload(clock);
      final service = _service(reader, clock);
      await service.fetch();
      final prior = service.snapshot;
      final old = Completer<RemoteConfigResponse>();
      reader.action = (_) => old.future;
      final older = service.fetch();
      reader.action = (_) => failure == 'network'
          ? Future.error(StateError('private'))
          : Future.value(_json({}));
      if (failure == 'base') reader.base = Uri.parse('https://evil.test/');
      final latest = await service.fetch();
      expect(
        latest.kind,
        failure == 'network'
            ? RemoteConfigFetchKind.failure
            : RemoteConfigFetchKind.invalid,
      );
      old.complete(_payload(clock, version: 99));
      expect((await older).code, 'remote.superseded');
      expect(identical(service.snapshot, prior), true);
      expect(service.flags.value('welcome')!.value, 'remote');
      clock.instant = prior.expiresAt!;
      expect(service.flags.value('welcome')!.value, 'local');
    }
  });

  test(
    'reset invalidates hung fetch without port or clock calls and late errors',
    () async {
      for (final error in [false, true]) {
        final clock = _Clock();
        final reader = _Reader()..response = _payload(clock);
        final service = _service(reader, clock);
        await service.fetch();
        final pending = Completer<RemoteConfigResponse>();
        reader.action = (_) => pending.future;
        final fetch = service.fetch();
        final calls = clock.calls;
        final getters = reader.getters;
        final reads = reader.paths.length;
        service.reset();
        expect(service.snapshot.version, 0);
        expect(service.snapshot.expiresAt, isNull);
        expect(service.flags.value('welcome')!.value, 'local');
        expect(clock.calls, calls);
        expect(reader.getters, getters);
        expect(reader.paths, hasLength(reads));
        var completed = false;
        fetch.then((_) => completed = true);
        await Future<void>.value();
        expect(completed, false);
        reader.action = null;
        reader.response = _payload(clock, version: 2);
        expect((await service.fetch()).code, 'remote.applied');
        final newer = service.snapshot;
        if (error) {
          pending.completeError(StateError('private late error'));
        } else {
          pending.complete(_payload(clock));
        }
        expect((await fetch).code, 'remote.superseded');
        expect(identical(service.snapshot, newer), true);
        expect(service.snapshot.version, 2);
      }
    },
  );

  test(
    'synchronous base getter and read reentrant fetch publish only newest',
    () async {
      for (final phase in ['getter', 'read']) {
        final clock = _Clock();
        final reader = _Reader()..response = _payload(clock, version: 2);
        late StarterRemoteConfigService service;
        Future<RemoteConfigFetchResult>? inner;
        reader.getterAction = () {
          if (phase == 'getter') {
            reader.getterAction = null;
            inner = service.fetch();
          }
          return Uri.parse('https://$_host/api/');
        };
        reader.action = (_) {
          reader.action = null;
          if (phase == 'read') inner = service.fetch();
          return Future.value(_payload(clock, version: 1));
        };
        if (phase == 'getter') reader.action = null;
        service = _service(reader, clock);
        final outer = service.fetch();
        expect((await outer).code, 'remote.superseded');
        expect((await inner!).code, 'remote.applied');
        expect(service.snapshot.version, 2);
        expect(reader.paths, hasLength(phase == 'getter' ? 1 : 2));
      }
    },
  );

  test('getter or read reset and reentrant exceptions cannot revive stale generation', () async {
    for (final phase in ['getter', 'read']) {
      final clock = _Clock();
      final reader = _Reader();
      late StarterRemoteConfigService service;
      reader.getterAction = () {
        if (phase == 'getter') {
          service.reset();
          throw StateError('private');
        }
        return Uri.parse('https://$_host/api/');
      };
      reader.action = (_) {
        service.reset();
        throw StateError('private');
      };
      service = _service(reader, clock);
      expect((await service.fetch()).code, 'remote.superseded');
      expect(service.snapshot.version, 0);
      expect(clock.calls, 0);
    }
  });

  test(
    'clock reentrant fetch reset and error fence publication after hook',
    () async {
      for (final action in ['fetch', 'reset', 'reset-error']) {
        final clock = _Clock();
        final reader = _Reader()..response = _payload(clock, version: 2);
        late StarterRemoteConfigService service;
        Future<RemoteConfigFetchResult>? inner;
        clock.action = () {
          clock.action = null;
          if (action == 'fetch') {
            inner = service.fetch();
          } else {
            service.reset();
          }
          if (action == 'reset-error') throw StateError('private clock');
          return clock.instant;
        };
        service = _service(reader, clock);
        expect((await service.fetch()).code, 'remote.superseded');
        if (inner != null) {
          expect((await inner!).code, 'remote.applied');
          expect(service.snapshot.version, 2);
        } else {
          expect(service.snapshot.version, 0);
        }
      }
    },
  );

  test(
    'custom supplied Uri serialization hook cannot publish an old fetch',
    () async {
      final clock = _Clock();
      final reader = _Reader();
      late StarterRemoteConfigService service;
      reader.base = _HookUri(() {
        service.reset();
        return 'https://$_host/api/';
      });
      service = _service(reader, clock);
      expect((await service.fetch()).code, 'remote.superseded');
      expect(service.snapshot.version, 0);
      expect(reader.paths, isEmpty);
      expect(clock.calls, 0);
    },
  );

  test(
    'flag-read clock reset selects current defaults not stale captured values',
    () async {
      final clock = _Clock();
      final reader = _Reader()..response = _payload(clock);
      final service = _service(reader, clock);
      await service.fetch();
      clock.action = () {
        clock.action = null;
        service.reset();
        return clock.instant;
      };
      expect(service.flags.value('welcome')!.value, 'local');
      expect(service.snapshot.version, 0);
      final calls = clock.calls;
      expect(service.flags.value('badge')!.value, false);
      expect(clock.calls, calls);
    },
  );
}

StarterRemoteConfigService _service(
  _Reader reader,
  _Clock clock, {
  bool enabled = true,
  String endpoint = 'config/snapshot',
  Set<String> hosts = const {_host},
  Map<String, RemoteValue> defaults = _defaults,
  Map<String, RemoteValueType> schema = _schema,
}) => StarterRemoteConfigService(
  enabled: enabled,
  reader: reader,
  endpoint: endpoint,
  allowedHosts: hosts,
  defaults: defaults,
  allowedSchema: schema,
  now: clock.now,
);

num _seconds(DateTime value) =>
    value.microsecondsSinceEpoch ~/ Duration.microsecondsPerSecond;
RemoteConfigResponse _payload(
  _Clock clock, {
  int version = 1,
  num ttl = 60,
  Map<String, Object?> values = const {'welcome': 'remote'},
}) => _json({
  'version': version,
  'expires_at': _seconds(clock.instant) + ttl,
  'values': values,
});
RemoteConfigResponse _json(Object? value) => _raw(jsonEncode(value));
RemoteConfigResponse _raw(String value) =>
    RemoteConfigResponse(statusCode: 200, body: utf8.encode(value));

final class _Clock {
  DateTime instant = DateTime.fromMillisecondsSinceEpoch(
    1700000000000,
    isUtc: true,
  );
  int calls = 0;
  DateTime Function()? action;
  DateTime now() {
    calls++;
    return action?.call() ?? instant;
  }
}

final class _Reader implements RemoteConfigReader {
  Uri base = Uri.parse('https://$_host/api/');
  int getters = 0;
  final paths = <String>[];
  RemoteConfigResponse response = _json({});
  Uri Function()? getterAction;
  Future<RemoteConfigResponse> Function(String)? action;
  @override
  Uri get baseEndpoint {
    getters++;
    return getterAction?.call() ?? base;
  }

  @override
  Future<RemoteConfigResponse> read(String path) {
    paths.add(path);
    return action?.call(path) ?? Future.value(response);
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

final class _HookUri implements Uri {
  _HookUri(this.serialize);
  final String Function() serialize;
  @override
  String toString() => serialize();
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
