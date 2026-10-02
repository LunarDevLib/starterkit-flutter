import 'dart:convert';
import 'dart:typed_data';

import '../async/cancellation.dart';

enum ApiMethod { get, post, put, patch, delete, head, options }

final class ApiRequest {
  ApiRequest({
    required this.method,
    required this.path,
    Map<String, String> query = const {},
    Map<String, String> headers = const {},
    Uint8List? body,
    this.authenticated = false,
  }) : query = _copyQuery(query),
       headers = _copyHeaders(headers),
       _body = _copyRequestBody(body) {
    _validatePath(path);
    _validateQuery(this.query);
    _validateRequestHeaders(this.headers);
    final encodedUri = Uri(path: path, queryParameters: this.query).toString();
    if (utf8.encode(encodedUri).length > maxUriBytes) {
      throw ArgumentError(
        'Request path and query exceed the allowed URI limit.',
      );
    }
  }

  static const int maxUriBytes = 2048;
  static const int maxRequestBodyBytes = 256 * 1024;
  static const int maxRequestHeaderCount = 32;
  static const int maxRequestHeaderBytes = 16 * 1024;

  final ApiMethod method;
  final String path;
  final Map<String, String> query;
  final Map<String, String> headers;
  final Uint8List? _body;
  final bool authenticated;

  Uint8List? get body => _body == null ? null : Uint8List.fromList(_body);

  static Map<String, String> _copyQuery(Map<String, String> input) {
    if (input.length > maxUriBytes) {
      throw ArgumentError('Request query has too many parameters.');
    }
    return Map<String, String>.unmodifiable(input);
  }

  static Map<String, String> _copyHeaders(Map<String, String> input) {
    if (input.length > maxRequestHeaderCount) {
      throw ArgumentError('Request headers exceed the allowed count.');
    }
    return Map<String, String>.unmodifiable(input);
  }

  static Uint8List? _copyRequestBody(Uint8List? body) {
    if (body == null) return null;
    if (body.length > maxRequestBodyBytes) {
      throw ArgumentError('Request body exceeds the allowed byte limit.');
    }
    return Uint8List.fromList(body);
  }

  static void _validatePath(String path) {
    if (path.isEmpty ||
        path.startsWith('/') ||
        utf8.encode(path).length > maxUriBytes ||
        path.contains('\\') ||
        path.contains('?') ||
        path.contains('#') ||
        path.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      throw ArgumentError('Request path must be a safe relative API path.');
    }
    final uri = Uri.tryParse(path);
    if (uri == null ||
        uri.hasScheme ||
        uri.hasAuthority ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw ArgumentError('Request path must be a safe relative API path.');
    }
    for (final segment in path.split('/')) {
      String decoded;
      try {
        decoded = Uri.decodeComponent(segment);
      } on FormatException {
        throw ArgumentError('Request path contains invalid encoding.');
      }
      if (decoded == '.' ||
          decoded == '..' ||
          decoded.contains('/') ||
          decoded.contains('\\') ||
          decoded.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
        throw ArgumentError('Request path contains an unsafe path segment.');
      }
    }
  }

  static void _validateQuery(Map<String, String> query) {
    var byteCount = 0;
    for (final entry in query.entries) {
      if (entry.key.isEmpty ||
          entry.key.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f) ||
          entry.value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
        throw ArgumentError('Request query contains invalid data.');
      }
      byteCount +=
          utf8.encode(entry.key).length + utf8.encode(entry.value).length;
      if (byteCount > maxUriBytes) {
        throw ArgumentError('Request query exceeds the allowed URI limit.');
      }
    }
  }

  static void _validateRequestHeaders(Map<String, String> headers) {
    if (headers.length > maxRequestHeaderCount) {
      throw ArgumentError.value(
        headers.length,
        'headers',
        'too many request headers',
      );
    }
    var bytes = 0;
    final normalizedNames = <String>{};
    for (final entry in headers.entries) {
      final name = entry.key;
      final value = entry.value;
      final normalized = name.toLowerCase();
      if (!RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$").hasMatch(name) ||
          !normalizedNames.add(normalized) ||
          _isForbiddenHeader(normalized) ||
          value.codeUnits.any(
            (unit) => unit < 0x20 && unit != 0x09 || unit == 0x7f,
          )) {
        throw ArgumentError('Request headers contain an unsafe field.');
      }
      bytes += utf8.encode(name).length + utf8.encode(value).length;
    }
    if (bytes > maxRequestHeaderBytes) {
      throw ArgumentError('Request headers exceed the allowed byte limit.');
    }
  }
}

const Set<String> _forbiddenHeaders = {
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
};

bool _isForbiddenHeader(String normalized) =>
    _forbiddenHeaders.contains(normalized) || normalized.startsWith('proxy-');

final class ApiResponse {
  ApiResponse({
    required this.statusCode,
    Map<String, List<String>> headers = const {},
    required Uint8List body,
  }) : headers = _copyMultiHeaders(headers),
       _body = _copyResponseBody(body) {
    if (statusCode < 100 || statusCode > 599) {
      throw ArgumentError.value(
        statusCode,
        'statusCode',
        'must be an HTTP status',
      );
    }
    if (this.headers.length > maxResponseHeaderCount) {
      throw ArgumentError.value(
        headers.length,
        'headers',
        'too many response headers',
      );
    }
    var headerBytes = 0;
    for (final entry in this.headers.entries) {
      headerBytes +=
          utf8.encode(entry.key).length +
          entry.value.fold<int>(
            0,
            (sum, value) => sum + utf8.encode(value).length,
          );
    }
    if (headerBytes > maxResponseHeaderBytes) {
      throw ArgumentError.value(
        headers,
        'headers',
        'exceeds response header byte limit',
      );
    }
  }

  static const int maxResponseHeaderCount = 128;
  static const int maxResponseHeaderBytes = 32 * 1024;
  static const int maxResponseBodyBytes = 1024 * 1024;

  final int statusCode;
  final Map<String, List<String>> headers;
  final Uint8List _body;

  Uint8List get body => Uint8List.fromList(_body);

  static Uint8List _copyResponseBody(Uint8List body) {
    if (body.length > maxResponseBodyBytes) {
      throw ArgumentError('Response body exceeds the allowed byte limit.');
    }
    return Uint8List.fromList(body);
  }

  static Map<String, List<String>> _copyMultiHeaders(
    Map<String, List<String>> input,
  ) {
    var valueCount = 0;
    var headerBytes = 0;
    for (final entry in input.entries) {
      valueCount += entry.value.length;
      if (valueCount > maxResponseHeaderCount) {
        throw ArgumentError('Response has too many header values.');
      }
      if (!RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$").hasMatch(entry.key)) {
        throw ArgumentError('Response contains an invalid header name.');
      }
      for (final value in entry.value) {
        if (value.codeUnits.any(
          (unit) => unit < 0x20 && unit != 0x09 || unit == 0x7f,
        )) {
          throw ArgumentError('Response contains an invalid header value.');
        }
        headerBytes +=
            utf8.encode(entry.key).length + utf8.encode(value).length;
        if (headerBytes > maxResponseHeaderBytes) {
          throw ArgumentError(
            'Response headers exceed the allowed byte limit.',
          );
        }
      }
    }
    final result = <String, List<String>>{};
    for (final entry in input.entries) {
      final key = entry.key.toLowerCase();
      result.update(
        key,
        (existing) => List<String>.unmodifiable([...existing, ...entry.value]),
        ifAbsent: () => List<String>.unmodifiable(entry.value),
      );
    }
    return Map<String, List<String>>.unmodifiable(result);
  }
}

typedef AuthorizationProvider = Future<String?> Function(
  CancellationToken cancellation,
);

abstract interface class ApiClient {
  Uri get baseEndpoint;

  Future<ApiResponse> execute(
    ApiRequest request, {
    CancellationToken? cancellation,
    Duration? timeout,
  });
}
