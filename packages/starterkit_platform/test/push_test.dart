import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:starterkit_platform/push.dart';
import 'package:starterkit_platform/starterkit_platform.dart';

const _channel = MethodChannel('starterkit/platform/push');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => _mock(null));

  test(
    'construction and disabled actions are inert even with a provider',
    () async {
      var calls = 0;
      _mock((call) async {
        calls++;
        return null;
      });
      final provider = _Provider(_LateStream());
      final enabled = StarterPushCapability(enabled: true, provider: provider);
      final disabled = StarterPushCapability(provider: provider);
      const defaultDisabled = StarterPushCapability();
      expect(enabled.enabled, isTrue);
      expect(provider.registerCalls, 0);
      expect(provider.messageReads, 0);
      for (final capability in [disabled, defaultDisabled]) {
        expect((await capability.permissionStatus()).code, 'push.disabled');
        expect((await capability.requestPermission()).code, 'push.disabled');
        expect((await capability.register()).code, 'push.disabled');
        final handle = capability.activateMessages(
          onMessage: (_) => fail('disabled'),
        );
        expect(handle.kind, PushMessageActivationKind.unavailable);
        expect(handle.code, 'push.disabled');
        await handle.close();
        await handle.close();
      }
      expect(calls, 0);
      expect(provider.registerCalls, 0);
      expect(provider.messageReads, 0);
    },
  );

  test(
    'permission calls use null arguments and do not register or subscribe',
    () async {
      final methods = <String>[];
      _mock((call) async {
        methods.add(call.method);
        expect(call.arguments, isNull);
        return {'kind': 'granted', 'code': 'push.permission_granted'};
      });
      final provider = _Provider(_LateStream());
      final capability = StarterPushCapability(
        enabled: true,
        provider: provider,
      );
      expect(
        (await capability.permissionStatus()).kind,
        PushPermissionKind.granted,
      );
      expect(
        (await capability.requestPermission()).kind,
        PushPermissionKind.granted,
      );
      expect(methods, ['permissionStatus', 'requestPermission']);
      expect(provider.registerCalls, 0);
      expect(provider.messageReads, 0);
    },
  );

  test(
    'every exact native permission pair is preserved in both methods',
    () async {
      const capability = StarterPushCapability(enabled: true);
      for (final (kind, code) in const [
        ('granted', 'push.permission_granted'),
        ('notDetermined', 'push.permission_not_determined'),
        ('denied', 'push.permission_denied'),
        ('restricted', 'push.permission_restricted'),
        ('unavailable', 'push.permission_not_configured'),
        ('unavailable', 'push.activity_unavailable'),
        ('unavailable', 'push.platform_unavailable'),
        ('conflict', 'push.operation_in_progress'),
        ('invalid', 'push.invalid_arguments'),
        ('failure', 'push.permission_failed'),
        ('failure', 'push.engine_detached'),
        ('failure', 'push.activity_detached'),
        ('failure', 'push.dispatch_failed'),
      ]) {
        _mock((call) async => {'kind': kind, 'code': code});
        for (final result in [
          await capability.permissionStatus(),
          await capability.requestPermission(),
        ]) {
          expect(result.kind.name, kind);
          expect(result.code, code);
        }
      }
    },
  );

  test(
    'permission schema refuses extra keys, unknown types and mismatched pairs',
    () async {
      const capability = StarterPushCapability(enabled: true);
      for (final raw in <Object?>[
        null,
        [],
        {'kind': 'granted'},
        {'code': 'push.permission_granted'},
        {'kind': 1, 'code': 'push.permission_granted'},
        {'kind': 'granted', 'code': 1},
        {'kind': 'unknown', 'code': 'push.permission_granted'},
        {'kind': 'denied', 'code': 'push.permission_granted'},
        {'kind': 'granted', 'code': 'private provider details'},
        {
          'kind': 'granted',
          'code': 'push.permission_granted',
          'extra': 'private',
        },
        {1: 'granted', 'code': 'push.permission_granted'},
        {'kind': 'unavailable', 'code': 'push.disabled'},
        {'kind': 'failure', 'code': 'push.invalid_native_response'},
      ]) {
        _mock((call) async => raw);
        for (final result in [
          await capability.permissionStatus(),
          await capability.requestPermission(),
        ]) {
          expect(result.kind, PushPermissionKind.failure);
          expect(result.code, 'push.invalid_native_response');
          expect(result.toString(), isNot(contains('private')));
        }
      }
    },
  );

  test(
    'missing plugin and transport errors return fixed permission outcomes',
    () async {
      const capability = StarterPushCapability(enabled: true);
      expect(
        (await capability.permissionStatus()).code,
        'push.platform_unavailable',
      );
      expect(
        (await capability.requestPermission()).code,
        'push.platform_unavailable',
      );
      _mock(
        (call) async =>
            throw PlatformException(code: 'secret SDK error', details: 'token'),
      );
      expect(
        (await capability.permissionStatus()).code,
        'push.permission_failed',
      );
      expect(
        (await capability.requestPermission()).code,
        'push.permission_failed',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler(_channel.name, (_) async => ByteData(0));
      expect(
        (await capability.permissionStatus()).code,
        'push.permission_failed',
      );
    },
  );

  test(
    'missing provider does not prevent explicit native permission status',
    () async {
      var calls = 0;
      _mock((call) async {
        calls++;
        return {
          'kind': 'unavailable',
          'code': 'push.permission_not_configured',
        };
      });
      const capability = StarterPushCapability(enabled: true);
      expect(
        (await capability.register()).code,
        'push.provider_not_configured',
      );
      final handle = capability.activateMessages(
        onMessage: (_) => fail('missing provider'),
      );
      expect(handle.kind, PushMessageActivationKind.unavailable);
      expect(handle.code, 'push.provider_not_configured');
      expect(calls, 0);
      expect(
        (await capability.permissionStatus()).code,
        'push.permission_not_configured',
      );
      expect(calls, 1);
    },
  );

  test('registration only calls provider and preserves opaque token case and spaces', () async {
    var calls = 0;
    _mock((call) async {
      calls++;
      return null;
    });
    final provider = _Provider(_LateStream())
      ..result = const PushProviderRegistration(
        PushProviderRegistrationKind.registered,
        token: '  AbCd-Generic-é😀  ',
      );
    final result = await StarterPushCapability(
      enabled: true,
      provider: provider,
    ).register();
    expect(result.kind, PushRegistrationKind.registered);
    expect(result.code, 'push.registered');
    expect(result.token, '  AbCd-Generic-é😀  ');
    expect(result.toString(), isNot(contains('AbCd')));
    expect(provider.registerCalls, 1);
    expect(provider.messageReads, 0);
    expect(calls, 0);
  });

  test('registration token Unicode byte boundary and malformed results fail closed', () async {
    final provider = _Provider(_LateStream());
    final capability = StarterPushCapability(enabled: true, provider: provider);
    for (final token in ['a' * 4096, '😀' * 1024]) {
      provider.result = PushProviderRegistration(
        PushProviderRegistrationKind.registered,
        token: token,
      );
      expect((await capability.register()).token, token);
    }
    for (final token in <String?>[
      null,
      '',
      '   ',
      'a' * 4097,
      '😀' * 1025,
      'é' * 2049,
      'a\u0000b',
      'a\nb',
      'a\u007fb',
      'a\u009fb',
      String.fromCharCode(0xd800),
      String.fromCharCode(0xdc00),
    ]) {
      provider.result = PushProviderRegistration(
        PushProviderRegistrationKind.registered,
        token: token,
      );
      final result = await capability.register();
      expect(result.kind, PushRegistrationKind.invalid);
      expect(result.code, 'push.invalid_provider_result');
      expect(result.token, isNull);
    }
    provider.result = const PushProviderRegistration(
      PushProviderRegistrationKind.denied,
      token: 'unexpected',
    );
    expect((await capability.register()).code, 'push.invalid_provider_result');
    expect(provider.messageReads, 0);
  });

  test('provider denial unavailability cancellation and failure use fixed outcomes', () async {
    final provider = _Provider(_LateStream());
    final capability = StarterPushCapability(enabled: true, provider: provider);
    for (final (kind, code) in const [
      (PushProviderRegistrationKind.denied, 'push.registration_denied'),
      (PushProviderRegistrationKind.unavailable, 'push.provider_unavailable'),
      (PushProviderRegistrationKind.cancelled, 'push.registration_cancelled'),
      (PushProviderRegistrationKind.failure, 'push.registration_failed'),
    ]) {
      provider.result = PushProviderRegistration(kind);
      final result = await capability.register();
      expect(result.kind.name, kind.name);
      expect(result.code, code);
      expect(result.token, isNull);
    }
    provider.registrationError = StateError('private token SDK details');
    final result = await capability.register();
    expect(result.kind, PushRegistrationKind.failure);
    expect(result.code, 'push.registration_failed');
    expect(result.token, isNull);
    expect(result.toString(), isNot(contains('private')));
  });

  test('explicit activation snapshots payload without native calls or registration', () async {
    var calls = 0;
    _mock((call) async {
      calls++;
      return null;
    });
    final stream = _LateStream();
    final provider = _Provider(stream);
    final received = <PushMessage>[];
    final handle = StarterPushCapability(
      enabled: true,
      provider: provider,
    ).activateMessages(onMessage: received.add);
    expect(handle.kind, PushMessageActivationKind.active);
    expect(handle.code, 'push.messages_active');
    final data = {'topic': 'Value'};
    final raw = {'title': '  Exact é 😀  ', 'body': 'Body', 'data': data};
    stream.send(raw);
    raw['title'] = 'changed';
    data['topic'] = 'changed';
    final message = received.single;
    expect(message.title, '  Exact é 😀  ');
    expect(message.body, 'Body');
    expect(message.data, {'topic': 'Value'});
    expect(() => message.data['topic'] = 'bad', throwsUnsupportedError);
    expect(() => (message as dynamic).body = 'bad', throwsNoSuchMethodError);
    expect(provider.messageReads, 1);
    expect(provider.registerCalls, 0);
    expect(stream.listens, 1);
    expect(calls, 0);
    await handle.close();
  });

  test(
    'message exact UTF8 and data entry bounds are accepted unchanged',
    () async {
      final stream = _LateStream();
      final received = <PushMessage>[];
      final handle = StarterPushCapability(
        enabled: true,
        provider: _Provider(stream),
      ).activateMessages(onMessage: received.add);
      stream.send({
        'title': '😀' * 64,
        'body': '😀' * 512,
        'data': {for (var i = 0; i < 32; i++) 'label$i': 'é' * 256},
      });
      stream.send({
        'title': '',
        'body': 'body',
        'data': {'é' * 32: ''},
      });
      stream.send({'title': 'title'});
      expect(received.length, 3);
      expect(received.first.data.length, 32);
      expect(received[1].title, '');
      expect(received[2].body, isNull);
      expect(received[2].data, isEmpty);
      expect(handle.kind, PushMessageActivationKind.active);
      await handle.close();
    },
  );

  test('malformed or oversized messages drop with fixed failure and stop listening', () async {
    for (final raw in <Object?>[
      null,
      [],
      {},
      {'title': ' '},
      {'body': ' '},
      {'title': 'valid', 'url': 'https://example.com'},
      {'title': null, 'body': 'valid'},
      {'title': 1},
      {'body': 'valid', 'data': null},
      {'title': 'valid', 'data': []},
      {'title': 'é' * 129},
      {'body': '😀' * 513},
      {'title': 'a\u0000b'},
      {'body': 'a\u0080b'},
      {'title': String.fromCharCode(0xd800)},
      {
        'title': 'valid',
        'data': {1: 'value'},
      },
      {
        'title': 'valid',
        'data': {'label': 1},
      },
      {
        'title': 'valid',
        'data': {' ': 'value'},
      },
      {
        'title': 'valid',
        'data': {'a' * 65: 'value'},
      },
      {
        'title': 'valid',
        'data': {'label': 'é' * 257},
      },
      {
        'title': 'valid',
        'data': {'la\nbel': 'value'},
      },
      {
        'title': 'valid',
        'data': {'label': 'a\u009fb'},
      },
      {
        'title': 'valid',
        'data': {for (var i = 0; i < 33; i++) 'label$i': 'value'},
      },
    ]) {
      final stream = _LateStream();
      var received = 0;
      final handle = StarterPushCapability(
        enabled: true,
        provider: _Provider(stream),
      ).activateMessages(onMessage: (_) => received++);
      stream.send(raw);
      expect(handle.kind, PushMessageActivationKind.failure);
      expect(handle.code, 'push.invalid_message');
      stream.send({'title': 'late'});
      await handle.close();
      expect(received, 0);
      expect(stream.subscription.cancels, 1);
      expect(handle.code, 'push.invalid_message');
    }
  });

  test(
    'scoped secret keys are normalized ASCII letters without exposing payload',
    () async {
      for (final key in [
        'password',
        'secret',
        'token',
        'authorization',
        'credential',
        'api_key',
        'Private-Key',
        'PREFIX_ToKeN_suffix',
        'a.p.i.1.K.E.Y',
      ]) {
        final stream = _LateStream();
        final handle = StarterPushCapability(
          enabled: true,
          provider: _Provider(stream),
        ).activateMessages(onMessage: (_) => fail('secret message accepted'));
        stream.send({
          'title': 'title',
          'data': {key: 'private payload'},
        });
        expect(handle.code, 'push.invalid_message');
        expect(handle.toString(), isNot(contains('private')));
        await handle.close();
      }
    },
  );

  test('close is idempotent and fences even provider callbacks delivered after cancellation', () async {
    final stream = _LateStream();
    var received = 0;
    final handle = StarterPushCapability(
      enabled: true,
      provider: _Provider(stream),
    ).activateMessages(onMessage: (_) => received++);
    stream.send({'title': 'first'});
    final first = handle.close();
    final second = handle.close();
    expect(identical(first, second), isTrue);
    stream.send({'title': 'late'});
    stream.error(StateError('late private error'));
    await first;
    expect(received, 1);
    expect(stream.subscription.cancels, 1);
    expect(handle.kind, PushMessageActivationKind.closed);
    expect(handle.code, 'push.messages_closed');
  });

  test('reentrant provider cleanup shares one cancellation future and fences callbacks', () async {
    for (final fails in [false, true]) {
      final stream = _LateStream();
      var received = 0;
      final handle = StarterPushCapability(
        enabled: true,
        provider: _Provider(stream),
      ).activateMessages(onMessage: (_) => received++);
      Future<void>? nested;
      stream.subscription.duringCancel = () {
        nested = handle.close(); // Cleanup reenters, but does not await itself.
        stream.send({'title': 'late cleanup callback'});
      };
      if (fails) {
        stream.subscription.cancelError = StateError('private cleanup');
      }
      stream.send({'title': 'first'});
      final first = handle.close();
      expect(
        {
          'cancels': stream.subscription.cancels,
          'shared': identical(first, nested),
        },
        {'cancels': 1, 'shared': true},
      );
      expect(identical(first, handle.close()), isTrue);
      await first;
      stream.send({'title': 'late after completion'});
      expect(received, 1);
      expect(stream.subscription.cancels, 1);
      expect(
        handle.kind,
        fails
            ? PushMessageActivationKind.failure
            : PushMessageActivationKind.closed,
      );
      expect(
        handle.code,
        fails ? 'push.message_failed' : 'push.messages_closed',
      );
    }
  });

  test(
    'ordinary provider stream errors are handled with fixed terminal failure',
    () async {
      final controller = StreamController<Object?>(sync: true);
      var received = 0;
      final handle = StarterPushCapability(
        enabled: true,
        provider: _Provider(controller.stream),
      ).activateMessages(onMessage: (_) => received++);
      controller.add({'body': 'first'});
      controller.addError(StateError('private SDK payload'));
      controller.add({'title': 'later'});
      await handle.close();
      await controller.close();
      expect(received, 1);
      expect(handle.kind, PushMessageActivationKind.failure);
      expect(handle.code, 'push.message_failed');
    },
  );

  test('provider getter listen cancellation and host exceptions never escape raw details', () async {
    final getterProvider = _Provider(_LateStream())
      ..messagesError = StateError('private');
    final getterHandle = StarterPushCapability(
      enabled: true,
      provider: getterProvider,
    ).activateMessages(onMessage: (_) {});
    expect(getterHandle.code, 'push.message_failed');
    final failingListen = _LateStream()..listenError = StateError('private');
    final listenHandle = StarterPushCapability(
      enabled: true,
      provider: _Provider(failingListen),
    ).activateMessages(onMessage: (_) {});
    expect(listenHandle.code, 'push.message_failed');
    final stream = _LateStream();
    final printed = <String>[];
    late PushMessageActivation hostHandle;
    runZoned(
      () {
        hostHandle =
            StarterPushCapability(
              enabled: true,
              provider: _Provider(stream),
            ).activateMessages(
              onMessage: (_) => throw StateError('private payload'),
            );
        stream.send({'title': 'private payload'});
      },
      zoneSpecification: ZoneSpecification(
        print: (_, _, _, line) => printed.add(line),
      ),
    );
    expect(hostHandle.code, 'push.message_failed');
    expect(printed, isEmpty);
    await hostHandle.close();
    final badCancel = _LateStream()
      ..subscription.cancelError = StateError('private');
    final cancelHandle = StarterPushCapability(
      enabled: true,
      provider: _Provider(badCancel),
    ).activateMessages(onMessage: (_) {});
    await cancelHandle.close();
    await cancelHandle.close();
    expect(cancelHandle.code, 'push.message_failed');
    expect(badCancel.subscription.cancels, 1);
  });

  test('synchronous invalid event during listen still cancels returned subscription once', () async {
    final stream = _LateStream()
      ..duringListen = (stream) => stream.send({'title': ' '});
    final handle = StarterPushCapability(
      enabled: true,
      provider: _Provider(stream),
    ).activateMessages(onMessage: (_) => fail('invalid'));
    expect(handle.code, 'push.invalid_message');
    await handle.close();
    expect(stream.subscription.cancels, 1);
  });

  test('stream completion closes activation without automatic registration or replay', () async {
    final stream = _LateStream();
    final provider = _Provider(stream);
    var received = 0;
    final handle = StarterPushCapability(
      enabled: true,
      provider: provider,
    ).activateMessages(onMessage: (_) => received++);
    stream.done();
    stream.send({'title': 'late'});
    expect(handle.kind, PushMessageActivationKind.closed);
    expect(handle.code, 'push.messages_closed');
    expect(provider.registerCalls, 0);
    expect(received, 0);
    await handle.close();
  });
}

void _mock(Future<Object?> Function(MethodCall)? handler) =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, handler);

final class _Provider implements PushProvider {
  _Provider(this.stream);
  final Stream<Object?> stream;
  int registerCalls = 0;
  int messageReads = 0;
  Object? registrationError;
  Object? messagesError;
  PushProviderRegistration result = const PushProviderRegistration(
    PushProviderRegistrationKind.registered,
    token: 'OpaqueToken',
  );

  @override
  Future<PushProviderRegistration> register() async {
    registerCalls++;
    if (registrationError != null) throw registrationError!;
    return result;
  }

  @override
  Stream<Object?> get messages {
    messageReads++;
    if (messagesError != null) throw messagesError!;
    return stream;
  }
}

// Test-only stream intentionally permits a late callback after cancel.
final class _LateStream extends Stream<Object?> {
  final subscription = _Subscription();
  int listens = 0;
  Object? listenError;
  void Function(_LateStream)? duringListen;
  void Function(Object?)? _data;
  Function? _error;
  void Function()? _done;

  void send(Object? value) => _data?.call(value);
  void error(Object value) => _error?.call(value, StackTrace.empty);
  void done() => _done?.call();

  @override
  StreamSubscription<Object?> listen(
    void Function(Object?)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    listens++;
    if (listenError != null) throw listenError!;
    _data = onData;
    _error = onError;
    _done = onDone;
    duringListen?.call(this);
    return subscription;
  }
}

final class _Subscription implements StreamSubscription<Object?> {
  int cancels = 0;
  Object? cancelError;
  void Function()? duringCancel;
  @override
  Future<void> cancel() async {
    cancels++;
    if (cancels == 1) duringCancel?.call();
    if (cancelError != null) throw cancelError!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
