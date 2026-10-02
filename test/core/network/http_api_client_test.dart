import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:flutter_starterkit/core/async/cancellation.dart';
import 'package:flutter_starterkit/core/failure/app_failure.dart';
import 'package:flutter_starterkit/core/network/api_client.dart';
import 'package:flutter_starterkit/core/network/http_api_client.dart';
import 'package:flutter_starterkit/core/network/network_policy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  group('HttpApiClient', () {
    test(
      'validates hostile path and reserved headers before auth or transport',
      () async {
        var authCalls = 0;
        var clientCreations = 0;
        final client = HttpApiClient(
          baseEndpoint: Uri.parse('https://api.example.test/v1/'),
          authorizationProvider: (_) async {
            authCalls++;
            return 'Bearer opaque';
          },
          clientFactory: () {
            clientCreations++;
            return _FakeClient((_) => _response(200, const []));
          },
        );

        for (final path in ['../escape', '%2e%2e/escape', 'a%2fb']) {
          expect(
            () => ApiRequest(
              method: ApiMethod.get,
              path: path,
              authenticated: true,
            ),
            throwsArgumentError,
          );
        }
        await expectLater(
          client.execute(
            ApiRequest(
              method: ApiMethod.get,
              path: 'a%252fb',
              authenticated: true,
            ),
          ),
          throwsA(
            isA<AppFailure>().having(
              (f) => f.kind,
              'kind',
              FailureKind.validation,
            ),
          ),
        );
        await expectLater(
          client.execute(
            ApiRequest(
              method: ApiMethod.get,
              path: 'safe',
              authenticated: true,
              headers: const {'aCcEpT-EnCoDiNg': 'gzip'},
            ),
          ),
          throwsA(
            isA<AppFailure>().having(
              (f) => f.kind,
              'kind',
              FailureKind.validation,
            ),
          ),
        );
        expect(authCalls, 0);
        expect(clientCreations, 0);
      },
    );

    test(
      'optional authorization is explicit and unauthenticated calls skip it',
      () async {
        var authCalls = 0;
        final transport = _FakeClient((request) {
          expect(request.url.host, 'api.example.test');
          expect(request.url.path, '/v1/items');
          expect(request.url.queryParameters['q'], 'a b&next=/../');
          expect(request.headers['authorization'], isNull);
          expect(request.headers['accept-encoding'], 'identity');
          return _response(200, [1, 2]);
        });
        final client = HttpApiClient(
          baseEndpoint: Uri.parse('https://api.example.test/v1/'),
          authorizationProvider: (_) async {
            authCalls++;
            return 'Bearer secret';
          },
          clientFactory: () => transport,
        );

        final result = await client.execute(
          ApiRequest(
            method: ApiMethod.get,
            path: 'items',
            query: const {'q': 'a b&next=/../'},
          ),
        );
        expect(result.body, Uint8List.fromList([1, 2]));
        expect(authCalls, 0);
        expect(transport.closed, isTrue);
      },
    );

    test(
      'deadline includes authorization lookup and reports timeout',
      () async {
        final client = HttpApiClient(
          baseEndpoint: Uri.parse('https://api.example.test/'),
          authorizationProvider: (_) => Completer<String?>().future,
          clientFactory: () => fail('transport must not be created'),
        );
        await expectLater(
          client.execute(
            ApiRequest(method: ApiMethod.get, path: 'x', authenticated: true),
            timeout: const Duration(milliseconds: 15),
          ),
          throwsA(
            isA<AppFailure>().having(
              (f) => f.kind,
              'kind',
              FailureKind.timeout,
            ),
          ),
        );
      },
    );

    test('elapsed deadline after synchronous authorization prevents transport creation', () async {
      var transportCreations = 0;
      final client = HttpApiClient(
        baseEndpoint: Uri.parse('https://api.example.test/'),
        authorizationProvider: (_) {
          _busyWait(const Duration(milliseconds: 40));
          return Future<String?>.value('Bearer token');
        },
        clientFactory: () {
          transportCreations++;
          return fail('expired authorization must not create transport');
        },
      );

      await expectLater(
        client.execute(
          ApiRequest(method: ApiMethod.get, path: 'x', authenticated: true),
          timeout: const Duration(milliseconds: 15),
        ),
        throwsA(
          isA<AppFailure>().having(
            (failure) => failure.kind,
            'kind',
            FailureKind.timeout,
          ),
        ),
      );
      expect(transportCreations, 0);
    });

    test(
      'expired synchronous authorization failure resolves as timeout',
      () async {
        var transportCreations = 0;
        final client = HttpApiClient(
          baseEndpoint: Uri.parse('https://api.example.test/'),
          authorizationProvider: (_) {
            _busyWait(const Duration(milliseconds: 40));
            throw AppFailure(
              FailureKind.unauthorized,
              code: 'auth.required',
              localizationKey: 'failure.auth.required',
            );
          },
          clientFactory: () {
            transportCreations++;
            return fail('expired authorization must not create transport');
          },
        );

        await expectLater(
          client.execute(
            ApiRequest(method: ApiMethod.get, path: 'x', authenticated: true),
            timeout: const Duration(milliseconds: 15),
          ),
          throwsA(
            isA<AppFailure>().having(
              (failure) => failure.kind,
              'kind',
              FailureKind.timeout,
            ),
          ),
        );
        expect(transportCreations, 0);
      },
    );

    test('late authorization error after timeout is consumed', () async {
      final auth = Completer<String?>();
      final client = HttpApiClient(
        baseEndpoint: Uri.parse('https://api.example.test/'),
        authorizationProvider: (_) => auth.future,
        clientFactory: () => fail('transport must not be created'),
      );
      await expectLater(
        client.execute(
          ApiRequest(method: ApiMethod.get, path: 'x', authenticated: true),
          timeout: const Duration(milliseconds: 10),
        ),
        throwsA(
          isA<AppFailure>().having((f) => f.kind, 'kind', FailureKind.timeout),
        ),
      );
      auth.completeError(StateError('late provider error'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });

    test(
      'outbound header budget reserves internal headers before auth',
      () async {
        var authCalls = 0;
        var transports = 0;
        final client = HttpApiClient(
          baseEndpoint: Uri.parse('https://api.example.test/'),
          authorizationProvider: (_) async {
            authCalls++;
            return 'Bearer token';
          },
          clientFactory: () {
            transports++;
            return _FakeClient((_) => _response(200, const []));
          },
        );
        final fullCountHeaders = {for (var i = 0; i < 32; i++) 'x-$i': 'v'};
        await expectLater(
          client.execute(
            ApiRequest(
              method: ApiMethod.get,
              path: 'x',
              headers: fullCountHeaders,
            ),
          ),
          throwsA(
            isA<AppFailure>().having(
              (f) => f.kind,
              'kind',
              FailureKind.validation,
            ),
          ),
        );
        await expectLater(
          client.execute(
            ApiRequest(
              method: ApiMethod.get,
              path: 'x',
              authenticated: true,
              headers: {'x-large': 'v' * 16000},
            ),
          ),
          throwsA(
            isA<AppFailure>().having(
              (f) => f.kind,
              'kind',
              FailureKind.validation,
            ),
          ),
        );
        expect(authCalls, 0);
        expect(transports, 0);
        for (final value in ['', 'Bearer\ninvalid', 'a' * 4097]) {
          final invalidAuthorization = HttpApiClient(
            baseEndpoint: Uri.parse('https://api.example.test/'),
            authorizationProvider: (_) async => value,
            clientFactory: () => fail('invalid authorization must not send'),
          );
          await expectLater(
            invalidAuthorization.execute(
              ApiRequest(method: ApiMethod.get, path: 'x', authenticated: true),
            ),
            throwsA(
              isA<AppFailure>().having(
                (failure) => failure.kind,
                'kind',
                FailureKind.validation,
              ),
            ),
          );
        }
      },
    );

    test('rejects unsafe base paths without exposing endpoint values', () {
      for (final path in ['/v1/%2fprivate/', '/v1/%252e/']) {
        final endpoint = Uri.parse('https://api.example.test$path');
        expect(
          () => HttpApiClient(baseEndpoint: endpoint),
          throwsArgumentError,
          reason: path,
        );
      }
    });

    test(
      'cancellation closes transport and cancels a stalled body subscription',
      () async {
        final source = CancellationSource();
        final stream = _StalledStream();
        late _FakeClient transport;
        final client = HttpApiClient(
          baseEndpoint: Uri.parse('https://api.example.test/'),
          clientFactory: () => transport = _FakeClient(
            (_) => http.StreamedResponse(
              stream,
              200,
              request: http.Request(
                'GET',
                Uri.parse('https://api.example.test/x'),
              ),
              headers: const {},
            ),
            throwOnClose: true,
          ),
        );
        final operation = client.execute(
          ApiRequest(method: ApiMethod.get, path: 'x'),
          cancellation: source.token,
          timeout: const Duration(seconds: 3),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        source.cancel();
        await expectLater(
          operation,
          throwsA(
            isA<AppFailure>().having(
              (f) => f.kind,
              'kind',
              FailureKind.cancelled,
            ),
          ),
        );
        expect(transport.closed, isTrue);
        expect(stream.cancelled, isTrue);
      },
    );

    test(
      'body cancellation closes client before never-completing cleanup',
      () async {
        final source = CancellationSource();
        final stream = _StubbornStream();
        late _FakeClient transport;
        final client = HttpApiClient(
          baseEndpoint: Uri.parse('https://api.example.test/'),
          clientFactory: () => transport = _FakeClient(
            (_) => http.StreamedResponse(
              stream,
              200,
              request: http.Request(
                'GET',
                Uri.parse('https://api.example.test/x'),
              ),
              headers: const {},
            ),
          ),
        );
        final operation = client.execute(
          ApiRequest(method: ApiMethod.get, path: 'x'),
          cancellation: source.token,
          timeout: const Duration(seconds: 2),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        source.cancel();
        await expectLater(
          operation,
          throwsA(
            isA<AppFailure>().having(
              (f) => f.kind,
              'kind',
              FailureKind.cancelled,
            ),
          ),
        );
        expect(transport.closed, isTrue);
        expect(stream.cancelStarted, isTrue);
      },
    );

    test('send deadline closes transport and aborts pending request', () async {
      late _FakeClient transport;
      final pending = Completer<http.StreamedResponse>();
      final client = HttpApiClient(
        baseEndpoint: Uri.parse('https://api.example.test/'),
        clientFactory: () => transport = _FakeClient((request) {
          transport.request = request as http.AbortableRequest;
          return pending.future;
        }),
      );
      await expectLater(
        client.execute(
          ApiRequest(method: ApiMethod.get, path: 'x'),
          timeout: const Duration(milliseconds: 15),
        ),
        throwsA(
          isA<AppFailure>().having((f) => f.kind, 'kind', FailureKind.timeout),
        ),
      );
      expect(transport.closed, isTrue);
      expect(transport.request!.abortTrigger, completes);
      pending.completeError(http.ClientException('late transport error'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });

    test(
      'expired synchronous send failure resolves as timeout and closes client',
      () async {
        late _FakeClient transport;
        final client = HttpApiClient(
          baseEndpoint: Uri.parse('https://api.example.test/'),
          clientFactory: () => transport = _FakeClient((_) {
            _busyWait(const Duration(milliseconds: 40));
            throw http.ClientException('synchronous send failure');
          }),
        );

        await expectLater(
          client.execute(
            ApiRequest(method: ApiMethod.get, path: 'x'),
            timeout: const Duration(milliseconds: 15),
          ),
          throwsA(
            isA<AppFailure>().having(
              (failure) => failure.kind,
              'kind',
              FailureKind.timeout,
            ),
          ),
        );
        expect(transport.closed, isTrue);
      },
    );

    test(
      'drip body deadline wins even when subscription cancellation throws',
      () async {
        final stream = _StubbornStream(drip: true, throwsOnCancel: true);
        late _FakeClient transport;
        final client = HttpApiClient(
          baseEndpoint: Uri.parse('https://api.example.test/'),
          clientFactory: () => transport = _FakeClient(
            (_) => http.StreamedResponse(
              stream,
              200,
              request: http.Request(
                'GET',
                Uri.parse('https://api.example.test/x'),
              ),
              headers: const {},
            ),
          ),
        );
        await expectLater(
          client.execute(
            ApiRequest(method: ApiMethod.get, path: 'x'),
            timeout: const Duration(milliseconds: 30),
          ),
          throwsA(
            isA<AppFailure>().having(
              (f) => f.kind,
              'kind',
              FailureKind.timeout,
            ),
          ),
        );
        expect(transport.closed, isTrue);
        expect(stream.cancelStarted, isTrue);
      },
    );

    test(
      'elapsed deadline is enforced when body delivery delays timer callback',
      () async {
        late _FakeClient transport;
        final client = HttpApiClient(
          baseEndpoint: Uri.parse('https://api.example.test/'),
          clientFactory: () => transport = _FakeClient(
            (_) => http.StreamedResponse(
              _DeadlineCrossingStream(const Duration(milliseconds: 40)),
              200,
              request: http.Request(
                'GET',
                Uri.parse('https://api.example.test/x'),
              ),
              headers: const {},
            ),
          ),
        );

        await expectLater(
          client.execute(
            ApiRequest(method: ApiMethod.get, path: 'x'),
            timeout: const Duration(milliseconds: 15),
          ),
          throwsA(
            isA<AppFailure>().having(
              (failure) => failure.kind,
              'kind',
              FailureKind.timeout,
            ),
          ),
        );
        expect(transport.closed, isTrue);
      },
    );

    test(
      'rejects oversized streamed response before accumulating it all',
      () async {
        final client = HttpApiClient(
          baseEndpoint: Uri.parse('https://api.example.test/'),
          clientFactory: () => _FakeClient(
            (_) => http.StreamedResponse(
              Stream<List<int>>.fromIterable([
                List<int>.filled(NetworkPolicy.maxResponseBodyBytes, 1),
                [2],
              ]),
              200,
              request: http.Request(
                'GET',
                Uri.parse('https://api.example.test/x'),
              ),
              headers: const {},
            ),
          ),
        );
        await expectLater(
          client.execute(ApiRequest(method: ApiMethod.get, path: 'x')),
          throwsA(
            isA<AppFailure>().having(
              (f) => f.code,
              'code',
              'response.too_large',
            ),
          ),
        );
      },
    );

    test(
      'rejects an oversized announced response length before reading body',
      () async {
        var listened = false;
        final client = HttpApiClient(
          baseEndpoint: Uri.parse('https://api.example.test/'),
          clientFactory: () => _FakeClient(
            (_) => http.StreamedResponse(
              Stream<List<int>>.multi((_) => listened = true),
              200,
              request: http.Request(
                'GET',
                Uri.parse('https://api.example.test/x'),
              ),
              headers: const {'content-length': '1048577'},
            ),
          ),
        );
        await expectLater(
          client.execute(ApiRequest(method: ApiMethod.get, path: 'x')),
          throwsA(
            isA<AppFailure>().having(
              (failure) => failure.code,
              'code',
              'response.too_large',
            ),
          ),
        );
        expect(listened, isFalse);
      },
    );

    test(
      'maps HTTP failure statuses centrally and does not retry mutations',
      () async {
        var sends = 0;
        final client = HttpApiClient(
          baseEndpoint: Uri.parse('https://api.example.test/'),
          clientFactory: () => _FakeClient((request) {
            sends++;
            expect(request.followRedirects, isFalse);
            expect(request.maxRedirects, 0);
            return _response(503, const []);
          }),
        );
        await expectLater(
          client.execute(ApiRequest(method: ApiMethod.post, path: 'mutate')),
          throwsA(
            isA<AppFailure>().having(
              (f) => f.kind,
              'kind',
              FailureKind.unavailable,
            ),
          ),
        );
        expect(sends, 1);
      },
    );

    test(
      'rejects encoded response bodies and maps package transport errors',
      () async {
        final encoded = HttpApiClient(
          baseEndpoint: Uri.parse('https://api.example.test/'),
          clientFactory: () => _FakeClient(
            (_) => http.StreamedResponse(
              Stream<List<int>>.value(const []),
              200,
              request: http.Request(
                'GET',
                Uri.parse('https://api.example.test/x'),
              ),
              headers: const {'content-encoding': 'gzip'},
            ),
          ),
        );
        await expectLater(
          encoded.execute(ApiRequest(method: ApiMethod.get, path: 'x')),
          throwsA(
            isA<AppFailure>().having(
              (f) => f.kind,
              'kind',
              FailureKind.validation,
            ),
          ),
        );

        for (final error in [
          http.ClientException('private detail'),
          const io.HttpException('private detail'),
        ]) {
          final transport = HttpApiClient(
            baseEndpoint: Uri.parse('https://api.example.test/'),
            clientFactory: () => _FakeClient((_) => throw error),
          );
          await expectLater(
            transport.execute(ApiRequest(method: ApiMethod.get, path: 'x')),
            throwsA(
              isA<AppFailure>()
                  .having(
                    (failure) => failure.kind,
                    'kind',
                    FailureKind.network,
                  )
                  .having(
                    (failure) => failure.toString().contains('private detail'),
                    'redacted diagnostic',
                    false,
                  ),
            ),
          );
        }
      },
    );
  });
}

http.StreamedResponse _response(int status, List<int> body) =>
    http.StreamedResponse(
      Stream<List<int>>.value(body),
      status,
      request: http.Request('GET', Uri.parse('https://api.example.test/')),
      headers: const {},
    );

void _busyWait(Duration duration) {
  final stopwatch = Stopwatch()..start();
  while (stopwatch.elapsed < duration) {}
}

final class _FakeClient extends http.BaseClient {
  _FakeClient(this.handler, {this.throwOnClose = false});
  final FutureOr<http.StreamedResponse> Function(http.BaseRequest) handler;
  final bool throwOnClose;
  bool closed = false;
  int sends = 0;
  http.AbortableRequest? request;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sends++;
    return await handler(request);
  }

  @override
  void close() {
    closed = true;
    if (throwOnClose) throw StateError('injected close failure');
  }
}

final class _StalledStream extends Stream<List<int>> {
  bool cancelled = false;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final controller = StreamController<List<int>>();
    final subscription = controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
    return _CancelTrackingSubscription(subscription, () => cancelled = true);
  }
}

final class _StubbornStream extends Stream<List<int>> {
  _StubbornStream({this.drip = false, this.throwsOnCancel = false});
  final bool drip;
  final bool throwsOnCancel;
  bool cancelStarted = false;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final controller = StreamController<List<int>>();
    Timer? timer;
    if (drip) {
      timer = Timer.periodic(const Duration(milliseconds: 5), (_) {
        if (!controller.isClosed) controller.add([1]);
      });
    }
    final inner = controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
    return _CancelTrackingSubscription(
      inner,
      () {
        cancelStarted = true;
        timer?.cancel();
      },
      cancelFuture: () => throwsOnCancel
          ? Future<void>.error(StateError('cancel failed'))
          : Completer<void>().future,
    );
  }
}

final class _DeadlineCrossingStream extends Stream<List<int>> {
  _DeadlineCrossingStream(this.blockDuration);
  final Duration blockDuration;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final controller = StreamController<List<int>>(sync: true);
    final subscription = controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
    Timer(const Duration(milliseconds: 1), () {
      _busyWait(blockDuration);
      if (!controller.isClosed) {
        controller.add([1]);
        controller.close();
      }
    });
    return subscription;
  }
}

final class _CancelTrackingSubscription<T> implements StreamSubscription<T> {
  _CancelTrackingSubscription(this.inner, this.onCancel, {this.cancelFuture});
  final StreamSubscription<T> inner;
  final void Function() onCancel;
  final Future<void> Function()? cancelFuture;
  @override
  Future<void> cancel() {
    onCancel();
    final cleanup = inner.cancel();
    return cancelFuture?.call() ?? cleanup;
  }

  @override
  void onData(void Function(T data)? handleData) => inner.onData(handleData);
  @override
  void onError(Function? handleError) => inner.onError(handleError);
  @override
  void onDone(void Function()? handleDone) => inner.onDone(handleDone);
  @override
  void pause([Future<void>? resumeSignal]) => inner.pause(resumeSignal);
  @override
  void resume() => inner.resume();
  @override
  bool get isPaused => inner.isPaused;
  @override
  Future<E> asFuture<E>([E? futureValue]) => inner.asFuture<E>(futureValue);
}
