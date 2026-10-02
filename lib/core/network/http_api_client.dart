import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../async/cancellation.dart';
import '../failure/app_failure.dart';
import 'api_client.dart';
import 'network_policy.dart';

/// A request-scoped, bounded HTTP implementation of [ApiClient].
///
/// Each call owns and closes its transport, so cancellation also tears down
/// the underlying connection. Construction itself performs no I/O.
final class HttpApiClient implements ApiClient {
  HttpApiClient({
    required Uri baseEndpoint,
    this.authorizationProvider,
    this.policy = const NetworkPolicy(),
    http.Client Function()? clientFactory,
  }) : baseEndpoint = _validateBaseEndpoint(baseEndpoint),
       _clientFactory = clientFactory ?? _newIoClient {
    if (policy.requestTimeout <= Duration.zero) {
      throw ArgumentError.value(policy.requestTimeout, 'requestTimeout');
    }
  }

  @override
  final Uri baseEndpoint;
  final AuthorizationProvider? authorizationProvider;
  final NetworkPolicy policy;
  final http.Client Function() _clientFactory;

  @override
  Future<ApiResponse> execute(
    ApiRequest request, {
    CancellationToken? cancellation,
    Duration? timeout,
  }) async {
    final deadline = timeout ?? policy.requestTimeout;
    if (deadline <= Duration.zero) {
      throw _failure(FailureKind.validation, 'request.invalid');
    }

    // Compose and fully validate before invoking credentials or creating a
    // transport. ApiRequest's value checks are intentionally repeated here
    // because it is a caller-controlled boundary.
    final uri = _composeUri(request);
    _validateRequest(request);

    final source = CancellationSource();
    final terminalFailure = Completer<AppFailure>();
    AppFailure? terminal;
    final abort = Completer<void>();
    final elapsed = Stopwatch()..start();
    http.Client? client;
    StreamSubscription<List<int>>? bodySubscription;

    void closeClient() {
      final activeClient = client;
      if (activeClient == null) return;
      client = null;
      try {
        activeClient.close();
      } on Object {
        // Teardown is best-effort and must never replace the terminal result.
      }
    }

    void cancelBodySubscription() {
      final activeSubscription = bodySubscription;
      if (activeSubscription == null) return;
      try {
        unawaited(
          activeSubscription.cancel().then<void>(
            (_) {},
            onError: (Object _, StackTrace __) {},
          ),
        );
      } on Object {
        // Some implementations throw before returning their cancellation
        // future. Physical transport close still proceeds synchronously.
      }
    }

    void finish(AppFailure failure) {
      if (terminal != null) return;
      terminal = failure;
      terminalFailure.complete(failure);
      source.cancel();
    }

    void expireIfElapsed() {
      if (terminal == null && elapsed.elapsed >= deadline) {
        finish(_failure(FailureKind.timeout, 'request.timeout'));
      }
    }

    void throwIfTerminalOrExpired() {
      expireIfElapsed();
      _throwIfTerminal(terminal);
    }

    // Set up transport cancellation before the deadline and auth lookup so a
    // single terminal transition aborts work in every phase.
    final removeAbortListener = source.token.onCancel(() {
      if (!abort.isCompleted) abort.complete();
      cancelBodySubscription();
      closeClient();
    });
    final unsubscribe = cancellation?.onCancel(
      () => finish(_failure(FailureKind.cancelled, 'operation.cancelled')),
    );
    final timer = Timer(deadline, () {
      finish(_failure(FailureKind.timeout, 'request.timeout'));
    });

    try {
      if (cancellation?.isCancelled ?? false) {
        finish(_failure(FailureKind.cancelled, 'operation.cancelled'));
      }
      _throwIfTerminal(terminal);

      final headers = Map<String, String>.of(request.headers)
        ..['accept-encoding'] = 'identity';
      if (request.authenticated) {
        final provider = authorizationProvider;
        if (provider == null) {
          throw _failure(FailureKind.unauthorized, 'auth.required');
        }
        final auth = await _untilTerminal(
          Future<String?>.sync(() => provider(source.token)),
          terminalFailure.future,
        );
        throwIfTerminalOrExpired();
        if (auth == null) {
          throw _failure(FailureKind.unauthorized, 'auth.required');
        }
        _validateAuthorization(auth);
        headers['authorization'] = auth;
      }
      _validateOutboundHeaderBudget(headers);
      throwIfTerminalOrExpired();

      client = _clientFactory();
      expireIfElapsed();
      if (terminal != null) {
        closeClient();
        _throwIfTerminal(terminal);
      }
      final body = request.body;
      final abortable =
          http.AbortableRequest(
              request.method.name.toUpperCase(),
              uri,
              abortTrigger: abort.future,
            )
            ..followRedirects = false
            ..maxRedirects = 0
            ..headers.addAll(headers);
      if (body != null) abortable.bodyBytes = body;

      throwIfTerminalOrExpired();
      final responseFuture = client!.send(abortable);
      final streamed = await _untilTerminal(
        responseFuture,
        terminalFailure.future,
      );
      throwIfTerminalOrExpired();
      _validateResponseHeaders(streamed.headers);
      final encoding = _headerValue(streamed.headers, 'content-encoding');
      if (encoding != null && encoding.trim().toLowerCase() != 'identity') {
        throw _failure(FailureKind.validation, 'response.invalid');
      }
      final announcedLength = _headerValue(streamed.headers, 'content-length');
      if (announcedLength != null) {
        final parsed = int.tryParse(announcedLength);
        if (parsed == null ||
            parsed < 0 ||
            parsed > NetworkPolicy.maxResponseBodyBytes) {
          throw _failure(FailureKind.validation, 'response.too_large');
        }
      }

      final bytes = BytesBuilder(copy: false);
      final received = Completer<void>();
      var byteCount = 0;
      bodySubscription = streamed.stream.listen(
        (chunk) {
          expireIfElapsed();
          if (terminal != null || received.isCompleted) return;
          byteCount += chunk.length;
          if (byteCount > NetworkPolicy.maxResponseBodyBytes) {
            finish(_failure(FailureKind.validation, 'response.too_large'));
            return;
          }
          bytes.add(chunk);
        },
        onError: (Object error, StackTrace stack) {
          expireIfElapsed();
          if (!received.isCompleted) received.completeError(error, stack);
        },
        onDone: () {
          expireIfElapsed();
          if (!received.isCompleted) received.complete();
        },
        cancelOnError: true,
      );
      await _untilTerminal(received.future, terminalFailure.future);
      throwIfTerminalOrExpired();

      final failure = AppFailure.fromHttpStatus(streamed.statusCode);
      if (failure != null) throw failure;
      final normalizedHeaders = <String, List<String>>{};
      for (final entry in streamed.headers.entries) {
        // package:http exposes combined values for some headers. Preserve each
        // exposed field as one value rather than guessing comma semantics.
        normalizedHeaders[entry.key] = [entry.value];
      }
      throwIfTerminalOrExpired();
      return ApiResponse(
        statusCode: streamed.statusCode,
        headers: normalizedHeaders,
        body: Uint8List.fromList(bytes.takeBytes()),
      );
    } on AppFailure {
      throwIfTerminalOrExpired();
      rethrow;
    } on http.RequestAbortedException {
      throwIfTerminalOrExpired();
      throw _failure(FailureKind.cancelled, 'operation.cancelled');
    } on Object catch (error) {
      throwIfTerminalOrExpired();
      throw _mapException(error);
    } finally {
      timer.cancel();
      unsubscribe?.call();
      removeAbortListener();
      cancelBodySubscription();
      closeClient();
    }
  }

  static http.Client _newIoClient() =>
      IOClient(HttpClient()..autoUncompress = false);

  Uri _composeUri(ApiRequest request) {
    final path = request.path;
    _validateRelativePath(path);
    final relative = Uri(path: path, queryParameters: request.query);
    final uri = baseEndpoint.resolveUri(relative);
    if (utf8.encode(uri.toString()).length > NetworkPolicy.maxUriBytes ||
        uri.scheme != 'https' ||
        uri.host != baseEndpoint.host ||
        uri.port != baseEndpoint.port ||
        uri.userInfo.isNotEmpty ||
        !uri.path.startsWith(baseEndpoint.path)) {
      throw _failure(FailureKind.validation, 'request.invalid');
    }
    return uri;
  }

  static Uri _validateBaseEndpoint(Uri endpoint) {
    if (!endpoint.isAbsolute ||
        !endpoint.hasAuthority ||
        endpoint.scheme.toLowerCase() != 'https' ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        !endpoint.path.endsWith('/') ||
        endpoint.authority.contains('%') ||
        endpoint.authority.contains('\\')) {
      throw ArgumentError('baseEndpoint must be a safe HTTPS endpoint.');
    }
    _validateEndpointPath(endpoint.path);
    return endpoint;
  }

  static void _validateRequest(ApiRequest request) {
    _validateRelativePath(request.path);
    if (request.body?.length case final length?
        when length > NetworkPolicy.maxRequestBodyBytes) {
      throw _failure(FailureKind.validation, 'request.invalid');
    }
    final internalHeaderSlots = request.authenticated ? 2 : 1;
    if (request.headers.length + internalHeaderSlots >
        NetworkPolicy.maxRequestHeaderCount) {
      throw _failure(FailureKind.validation, 'request.invalid');
    }
    var bytes = 0;
    final seen = <String>{};
    for (final entry in request.headers.entries) {
      final name = entry.key.toLowerCase();
      if (!_headerName.hasMatch(entry.key) ||
          !seen.add(name) ||
          _reservedHeaders.contains(name) ||
          name.startsWith('proxy-') ||
          entry.value.codeUnits.any(
            (unit) => unit < 0x20 && unit != 9 || unit == 127,
          )) {
        throw _failure(FailureKind.validation, 'request.invalid');
      }
      bytes += utf8.encode(entry.key).length + utf8.encode(entry.value).length;
    }
    if (bytes > NetworkPolicy.maxRequestHeaderBytes) {
      throw _failure(FailureKind.validation, 'request.invalid');
    }
    const identityHeaderBytes = 15 + 8;
    const authorizationHeaderBytes = 13 + 4096;
    if (bytes +
            identityHeaderBytes +
            (request.authenticated ? authorizationHeaderBytes : 0) >
        NetworkPolicy.maxRequestHeaderBytes) {
      throw _failure(FailureKind.validation, 'request.invalid');
    }
    for (final entry in request.query.entries) {
      if (entry.key.isEmpty ||
          _hasControl(entry.key) ||
          _hasControl(entry.value)) {
        throw _failure(FailureKind.validation, 'request.invalid');
      }
    }
  }

  static void _validateRelativePath(String path) {
    if (path.isEmpty ||
        path.startsWith('/') ||
        path.startsWith('//') ||
        path.contains('\\') ||
        path.contains('?') ||
        path.contains('#') ||
        _hasControl(path) ||
        utf8.encode(path).length > NetworkPolicy.maxUriBytes ||
        path.toLowerCase().contains('%25')) {
      throw _failure(FailureKind.validation, 'request.invalid');
    }
    final parsed = Uri.tryParse(path);
    if (parsed == null ||
        parsed.hasScheme ||
        parsed.hasAuthority ||
        parsed.hasQuery ||
        parsed.hasFragment) {
      throw _failure(FailureKind.validation, 'request.invalid');
    }
    for (final segment in path.split('/')) {
      String decoded;
      try {
        decoded = Uri.decodeComponent(segment);
      } on FormatException {
        throw _failure(FailureKind.validation, 'request.invalid');
      }
      if (decoded == '.' ||
          decoded == '..' ||
          decoded.contains('/') ||
          decoded.contains('\\') ||
          _hasControl(decoded)) {
        throw _failure(FailureKind.validation, 'request.invalid');
      }
    }
  }

  static void _validateEndpointPath(String path) {
    if (!path.startsWith('/') ||
        path.contains('\\') ||
        _hasControl(path) ||
        path.toLowerCase().contains('%25')) {
      throw ArgumentError('baseEndpoint path is unsafe.');
    }
    for (final segment in path.split('/').skip(1)) {
      String decoded;
      try {
        decoded = Uri.decodeComponent(segment);
      } on FormatException {
        throw ArgumentError('baseEndpoint path is unsafe.');
      }
      if (decoded == '.' ||
          decoded == '..' ||
          decoded.contains('/') ||
          decoded.contains('\\') ||
          _hasControl(decoded)) {
        throw ArgumentError('baseEndpoint path is unsafe.');
      }
    }
  }

  static void _validateOutboundHeaderBudget(Map<String, String> headers) {
    if (headers.length > NetworkPolicy.maxRequestHeaderCount) {
      throw _failure(FailureKind.validation, 'request.invalid');
    }
    var bytes = 0;
    for (final entry in headers.entries) {
      bytes += utf8.encode(entry.key).length + utf8.encode(entry.value).length;
    }
    if (bytes > NetworkPolicy.maxRequestHeaderBytes) {
      throw _failure(FailureKind.validation, 'request.invalid');
    }
  }

  static void _validateAuthorization(String value) {
    if (value.isEmpty ||
        utf8.encode(value).length > 4096 ||
        _hasControl(value)) {
      throw _failure(FailureKind.validation, 'auth.invalid');
    }
  }

  static void _validateResponseHeaders(Map<String, String> headers) {
    if (headers.length > NetworkPolicy.maxResponseHeaderCount) {
      throw _failure(FailureKind.validation, 'response.invalid');
    }
    var bytes = 0;
    for (final entry in headers.entries) {
      if (!_headerName.hasMatch(entry.key) ||
          entry.value.codeUnits.any(
            (unit) => unit < 0x20 && unit != 9 || unit == 127,
          )) {
        throw _failure(FailureKind.validation, 'response.invalid');
      }
      bytes += utf8.encode(entry.key).length + utf8.encode(entry.value).length;
    }
    if (bytes > NetworkPolicy.maxResponseHeaderBytes) {
      throw _failure(FailureKind.validation, 'response.invalid');
    }
  }

  static String? _headerValue(Map<String, String> headers, String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name) return entry.value;
    }
    return null;
  }

  static bool _hasControl(String value) =>
      value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f);

  static Future<T> _untilTerminal<T>(
    Future<T> operation,
    Future<AppFailure> terminal,
  ) {
    // Attach an error handler to the losing operation so a late failure cannot
    // escape as an unhandled asynchronous error after timeout/cancellation.
    final observed = operation.then<T>(
      (value) => value,
      onError: (Object error, StackTrace stack) {
        Error.throwWithStackTrace(error, stack);
      },
    );
    return Future.any<T>([
      observed,
      terminal.then<T>((failure) => throw failure),
    ]);
  }

  static void _throwIfTerminal(AppFailure? failure) {
    if (failure != null) throw failure;
  }

  static AppFailure _failure(FailureKind kind, String code) =>
      AppFailure(kind, code: code, localizationKey: 'failure.$code');

  static AppFailure _mapException(Object error) {
    if (error is http.ClientException ||
        error is HttpException ||
        error is SocketException) {
      return _failure(FailureKind.network, 'network.error');
    }
    return AppFailure.fromException(error);
  }

  static final RegExp _headerName = RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$");
  static const Set<String> _reservedHeaders = {
    'host',
    'authorization',
    'cookie',
    'set-cookie',
    'content-length',
    'connection',
    'keep-alive',
    'proxy-authorization',
    'proxy-authenticate',
    'transfer-encoding',
    'te',
    'trailer',
    'upgrade',
    'accept-encoding',
  };
}
