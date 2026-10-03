import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

final class OAuthConfiguration {
  OAuthConfiguration({
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    required this.redirectUri,
    required this.clientId,
    required Set<String> allowedHosts,
    this.returnPath = '',
  }) : allowedHosts = Set<String>.unmodifiable(allowedHosts);

  final String authorizationEndpoint;
  final String tokenEndpoint;
  final String redirectUri;
  final String clientId;
  final Set<String> allowedHosts;
  final String returnPath;
}

/// Product system-browser integration. Completion/failure means the session is
/// finished; cancel must acknowledge teardown. No OS adapter is supplied here.
abstract interface class OAuthBrowserAuthentication {
  Future<String> authenticate(Uri authorizationUri, String callbackScheme);
  Future<void> cancel();
}

/// Product transport must execute beneath a stable base and own TLS, redirects,
/// credentials, acquisition limits and timeouts. Getter checks cannot prove that.
/// Join relative paths beneath the base directory (append a slash if absent).
abstract interface class OAuthTokenTransport {
  Uri get baseEndpoint;
  Future<OAuthTokenResponse> execute(OAuthTokenRequest request);
}

final class OAuthTokenRequest {
  OAuthTokenRequest({required this.path, required List<int> body})
    : body = List<int>.unmodifiable(body);

  final String path;
  final List<int> body;
  final String method = 'POST';
  final String contentType = 'application/x-www-form-urlencoded';
  final String accept = 'application/json';
}

final class OAuthTokenResponse {
  OAuthTokenResponse({required this.statusCode, required List<int> body})
    : body = List<int>.unmodifiable(body);

  final int statusCode;
  final List<int> body;
}

final class OAuthPKCE {
  const OAuthPKCE._(this.verifier, this.challenge);

  factory OAuthPKCE.fromVerifier(String verifier) {
    if (verifier.length < 43 ||
        verifier.length > 128 ||
        !_matches(verifier, r'[A-Za-z0-9._~-]+')) {
      throw ArgumentError('Invalid PKCE verifier.');
    }
    return OAuthPKCE._(
      verifier,
      _base64Url(sha256.convert(ascii.encode(verifier)).bytes),
    );
  }

  final String verifier;
  final String challenge;
}

final class OAuthToken {
  const OAuthToken._(this.accessToken, this.tokenType, this.expiresIn);

  final String accessToken;
  final String tokenType;
  final int? expiresIn;
}

enum SocialLoginKind {
  authenticated,
  invalid,
  unavailable,
  failure,
  cancelled,
  inProgress,
}

final class SocialLoginResult {
  const SocialLoginResult._(this.kind, this.code, [this.token]);

  final SocialLoginKind kind;
  final String code;
  final OAuthToken? token;
}

enum SocialLoginCancelKind { idle, cancelled, failure }

final class SocialLoginCancelResult {
  const SocialLoginCancelResult._(this.kind, this.code);

  final SocialLoginCancelKind kind;
  final String code;
}

/// Explicit, disabled by default, with one active generation. There is no token
/// storage, refresh, physical HTTP abort, revocation or memory-zeroization API.
final class StarterSocialLoginService {
  StarterSocialLoginService({
    this.enabled = false,
    this.configuration,
    this.browser,
    this.transport,
  });

  final bool enabled;
  final OAuthConfiguration? configuration;
  final OAuthBrowserAuthentication? browser;
  final OAuthTokenTransport? transport;
  _Attempt? _active;
  bool _cleanupFailed = false;

  // Not async: publish the guard before any external getter/call can reenter.
  Future<SocialLoginResult> signIn() {
    if (!enabled) return Future.value(_unavailable('social.disabled'));
    if (_cleanupFailed) {
      return Future.value(_unavailable('social.cleanup_failed'));
    }
    if (_active != null) {
      return Future.value(
        const SocialLoginResult._(
          SocialLoginKind.inProgress,
          'social.in_progress',
        ),
      );
    }
    final config = configuration;
    if (config == null) {
      return Future.value(_unavailable('social.configuration_not_configured'));
    }
    if (browser == null) {
      return Future.value(_unavailable('social.browser_not_configured'));
    }
    if (transport == null) {
      return Future.value(_unavailable('social.transport_not_configured'));
    }
    final validated = _validateConfiguration(config);
    if (validated == null) return Future.value(_invalidConfiguration);
    final attempt = _Attempt();
    _active = attempt;
    unawaited(_drive(attempt, validated));
    return attempt.result.future;
  }

  // Publish the shared cancellation future before invoking browser cleanup.
  Future<SocialLoginCancelResult> cancel() {
    final attempt = _active;
    if (attempt == null) {
      return Future.value(
        const SocialLoginCancelResult._(
          SocialLoginCancelKind.idle,
          'social.idle',
        ),
      );
    }
    final pending = attempt.cancellation;
    if (pending != null) return pending;
    final completion = Completer<SocialLoginCancelResult>();
    attempt.cancellation = completion.future;
    attempt.cancelled = true;
    attempt.clearSecrets();
    attempt.result.complete(_cancelled);
    unawaited(_cancelBrowser(attempt, completion));
    return completion.future;
  }

  Future<void> _cancelBrowser(
    _Attempt attempt,
    Completer<SocialLoginCancelResult> completion,
  ) async {
    try {
      await browser!.cancel();
      if (identical(_active, attempt)) _active = null;
      completion.complete(
        const SocialLoginCancelResult._(
          SocialLoginCancelKind.cancelled,
          'social.cancelled',
        ),
      );
    } on Object {
      if (identical(_active, attempt)) {
        _cleanupFailed = true;
        _active = null;
      }
      completion.complete(
        const SocialLoginCancelResult._(
          SocialLoginCancelKind.failure,
          'social.cleanup_failed',
        ),
      );
    }
  }

  bool _current(_Attempt attempt) =>
      identical(_active, attempt) && !attempt.cancelled;

  void _finish(_Attempt attempt, SocialLoginResult result) {
    if (!_current(attempt)) return;
    attempt.clearSecrets();
    _active = null;
    attempt.result.complete(result);
  }

  String? _transportPath(_Attempt attempt, _Configuration config) {
    final Uri base;
    try {
      base = transport!.baseEndpoint;
    } on Object {
      _finish(attempt, _failure('social.transport_failed'));
      return null;
    }
    if (!_current(attempt)) return null;
    final path = _relativeTokenPath(base, config);
    if (!_current(attempt)) return null;
    if (path == null) _finish(attempt, _invalidConfiguration);
    return path;
  }

  Future<void> _drive(_Attempt attempt, _Configuration config) async {
    if (_transportPath(attempt, config) == null || !_current(attempt)) return;
    Uri authorization;
    try {
      final random = Random.secure();
      attempt.state = _randomValue(random);
      attempt.verifier = _randomValue(random);
      authorization = config.authorization.replace(
        queryParameters: {
          'response_type': 'code',
          'client_id': config.raw.clientId,
          'redirect_uri': config.raw.redirectUri,
          'state': attempt.state!,
          'code_challenge': OAuthPKCE.fromVerifier(attempt.verifier!).challenge,
          'code_challenge_method': 'S256',
          if (config.raw.returnPath.isNotEmpty)
            'return_path': config.raw.returnPath,
        },
      );
    } on Object {
      _finish(attempt, _failure('social.entropy_failed'));
      return;
    }
    if (utf8.encode(authorization.toString()).length > 4096) {
      _finish(attempt, _invalidConfiguration);
      return;
    }
    if (!_current(attempt)) return;
    final String callback;
    try {
      callback = await browser!.authenticate(
        authorization,
        config.redirect.scheme,
      );
    } on Object {
      _finish(attempt, _failure('social.browser_failed'));
      return;
    }
    if (!_current(attempt)) return;
    final rejection = _acceptCallback(
      attempt,
      callback,
      config.raw.redirectUri,
    );
    if (rejection != null) {
      _finish(attempt, rejection);
      return;
    }
    final path = _transportPath(attempt, config);
    if (path == null || !_current(attempt)) return;
    final body = utf8.encode(
      Uri(
        queryParameters: {
          'grant_type': 'authorization_code',
          'client_id': config.raw.clientId,
          'code': attempt.code!,
          'redirect_uri': config.raw.redirectUri,
          'code_verifier': attempt.verifier!,
        },
      ).query,
    );
    if (body.length > 8192) {
      _finish(attempt, _invalidCallback);
      return;
    }
    final request = OAuthTokenRequest(path: path, body: body);
    attempt.clearSecrets();
    if (!_current(attempt)) return;
    final OAuthTokenResponse response;
    try {
      response = await transport!.execute(request);
    } on Object {
      _finish(attempt, _failure('social.transport_failed'));
      return;
    }
    if (!_current(attempt)) return;
    _finish(attempt, _decodeToken(response));
  }
}

final class _Attempt {
  final result = Completer<SocialLoginResult>();
  Future<SocialLoginCancelResult>? cancellation;
  bool cancelled = false;
  String? state;
  String? verifier;
  String? code;

  void clearSecrets() {
    state = null;
    verifier = null;
    code = null;
  }
}

final class _Configuration {
  const _Configuration(this.raw, this.authorization, this.token, this.redirect);

  final OAuthConfiguration raw;
  final Uri authorization;
  final Uri token;
  final Uri redirect;
}

const _invalidConfiguration = SocialLoginResult._(
  SocialLoginKind.invalid,
  'social.invalid_configuration',
);
const _invalidCallback = SocialLoginResult._(
  SocialLoginKind.invalid,
  'social.invalid_callback',
);
const _cancelled = SocialLoginResult._(
  SocialLoginKind.cancelled,
  'social.cancelled',
);
SocialLoginResult _unavailable(String code) =>
    SocialLoginResult._(SocialLoginKind.unavailable, code);
SocialLoginResult _failure(String code) =>
    SocialLoginResult._(SocialLoginKind.failure, code);

bool _matches(String value, String pattern) {
  final match = RegExp(pattern).firstMatch(value);
  return match != null && match.start == 0 && match.end == value.length;
}

bool _validText(String value, int maxBytes, {bool nonempty = false}) {
  if ((nonempty && value.isEmpty) || value.length > maxBytes) return false;
  for (var index = 0; index < value.length; index++) {
    final unit = value.codeUnitAt(index);
    if (unit <= 0x1f || (unit >= 0x7f && unit <= 0x9f)) return false;
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++index >= value.length) return false;
      final low = value.codeUnitAt(index);
      if (low < 0xdc00 || low > 0xdfff) return false;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return false;
    }
  }
  return utf8.encode(value).length <= maxBytes;
}

bool _validHost(String host) =>
    host.length <= 253 &&
    host
        .split('.')
        .every(
          (label) => _matches(label, r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?'),
        );

bool _safePath(String path, {bool relative = false}) {
  if (path.length > 2048) return false;
  var parts = path;
  if (relative) {
    if (parts.isEmpty || parts.startsWith('/')) return false;
  } else {
    if (parts.isEmpty) return true;
    if (!parts.startsWith('/')) return false;
    parts = parts.substring(1);
  }
  if (parts.endsWith('/')) parts = parts.substring(0, parts.length - 1);
  if (parts.isEmpty) return !relative && path == '/';
  return parts
      .split('/')
      .every(
        (part) =>
            part != '.' && part != '..' && _matches(part, r'[A-Za-z0-9._~-]+'),
      );
}

Uri? _https(String raw, Set<String> hosts) {
  if (!_validText(raw, 2048)) return null;
  final match = RegExp(r'https://([a-z0-9.-]+)(?::([0-9]+))?(/[^?#]*)?')
      .firstMatch(raw);
  if (match == null || match.start != 0 || match.end != raw.length) return null;
  final host = match.group(1)!;
  final port = match.group(2);
  if (!_validHost(host) || !hosts.contains(host)) return null;
  if (port != null) {
    if (port.length > 5) return null;
    final number = int.parse(port);
    if (number < 1 || number > 65535) return null;
  }
  if (!_safePath(match.group(3) ?? '')) return null;
  return Uri.parse(raw);
}

_Configuration? _validateConfiguration(OAuthConfiguration config) {
  if (config.allowedHosts.isEmpty ||
      config.allowedHosts.length > 16 ||
      !config.allowedHosts.every(_validHost) ||
      !_validText(config.clientId, 128, nonempty: true) ||
      (config.returnPath.isNotEmpty &&
          (config.returnPath.length > 128 || !_safePath(config.returnPath)))) {
    return null;
  }
  final authorization = _https(
    config.authorizationEndpoint,
    config.allowedHosts,
  );
  final token = _https(config.tokenEndpoint, config.allowedHosts);
  final raw = config.redirectUri;
  if (authorization == null || token == null || !_validText(raw, 2048)) {
    return null;
  }
  final redirectMatch = RegExp(r'([a-z][a-z0-9+.-]*)://([a-z0-9.-]+)(/[^?#]*)')
      .firstMatch(raw);
  if (redirectMatch == null ||
      redirectMatch.start != 0 ||
      redirectMatch.end != raw.length ||
      redirectMatch.group(1) == 'http' ||
      redirectMatch.group(1) == 'https' ||
      !_validHost(redirectMatch.group(2)!) ||
      !_safePath(redirectMatch.group(3)!)) {
    return null;
  }
  return _Configuration(config, authorization, token, Uri.parse(raw));
}

String? _relativeTokenPath(Uri suppliedBase, _Configuration config) {
  try {
    // Validate the supplied serialization before parsing, not original spelling
    // that a product may already have erased while constructing its Uri.
    final base = _https(suppliedBase.toString(), config.raw.allowedHosts);
    final token = config.token;
    if (base == null || base.origin != token.origin) return null;
    final prefix = base.path.endsWith('/') ? base.path : '${base.path}/';
    if (!token.path.startsWith(prefix)) return null;
    final relative = token.path.substring(prefix.length);
    if (!_safePath(relative, relative: true) ||
        base.replace(path: prefix).resolve(relative).toString() !=
            token.toString()) {
      return null;
    }
    return relative;
  } on Object {
    return null;
  }
}

String _base64Url(List<int> bytes) =>
    base64UrlEncode(bytes).replaceAll('=', '');
String _randomValue(Random random) => _base64Url(
  List<int>.generate(32, (_) => random.nextInt(256), growable: false),
);

String? _queryComponent(String value) {
  for (var index = 0; index < value.length; index++) {
    if (value.codeUnitAt(index) != 0x25) continue;
    if (index + 2 >= value.length ||
        !_matches(value.substring(index + 1, index + 3), r'[0-9A-Fa-f]{2}')) {
      return null;
    }
    index += 2;
  }
  try {
    final decoded = Uri.decodeQueryComponent(value, encoding: utf8);
    return _validText(decoded, 4096) ? decoded : null;
  } on Object {
    return null;
  }
}

bool _stateMatches(String expected, String actual) {
  var difference = actual.length ^ 43;
  for (var index = 0; index < 43; index++) {
    difference |=
        expected.codeUnitAt(index) ^
        (index < actual.length ? actual.codeUnitAt(index) : 0);
  }
  return difference == 0;
}

SocialLoginResult? _acceptCallback(
  _Attempt attempt,
  String raw,
  String redirect,
) {
  if (!_validText(raw, 4096) || raw.contains('#')) return _invalidCallback;
  final separator = raw.indexOf('?');
  if (separator < 0 || raw.substring(0, separator) != redirect) {
    return _invalidCallback;
  }
  final pairs = raw.substring(separator + 1).split('&');
  if (pairs.length > 4) return _invalidCallback;
  final values = <String, String>{};
  const keys = {'code', 'state', 'error', 'error_description'};
  for (final pair in pairs) {
    final equals = pair.indexOf('=');
    if (equals <= 0) return _invalidCallback;
    final name = _queryComponent(pair.substring(0, equals));
    final value = _queryComponent(pair.substring(equals + 1));
    if (name == null ||
        value == null ||
        !keys.contains(name) ||
        values.containsKey(name)) {
      return _invalidCallback;
    }
    values[name] = value;
  }
  final state = values['state'];
  if (state == null) return _invalidCallback;
  if (!_stateMatches(attempt.state!, state)) {
    return const SocialLoginResult._(
      SocialLoginKind.invalid,
      'social.state_mismatch',
    );
  }
  final code = values['code'];
  final error = values['error'];
  if ((code != null && error != null) ||
      (error == null && values.containsKey('error_description'))) {
    return _invalidCallback;
  }
  if (error != null) {
    return error.isEmpty
        ? _invalidCallback
        : _failure('social.authorization_rejected');
  }
  if (code == null || !_validText(code, 2048, nonempty: true)) {
    return _invalidCallback;
  }
  attempt.code = code;
  return null;
}

SocialLoginResult _decodeToken(OAuthTokenResponse response) {
  final invalid = _failure('social.token_response_invalid');
  if (response.statusCode < 100 || response.statusCode > 599) return invalid;
  if (response.statusCode < 200 || response.statusCode >= 300) {
    return _failure('social.transport_failed');
  }
  final bytes = response.body;
  if (bytes.length > 16384 || bytes.any((byte) => byte < 0 || byte > 255)) {
    return invalid;
  }
  final Object? json;
  try {
    json = jsonDecode(utf8.decode(bytes, allowMalformed: false));
  } on Object {
    return invalid;
  }
  if (json is! Map ||
      json.length < 2 ||
      json.length > 3 ||
      json.keys.any(
        (key) =>
            key != 'access_token' && key != 'token_type' && key != 'expires_in',
      )) {
    return invalid;
  }
  final token = json['access_token'];
  final type = json['token_type'];
  final expires = json['expires_in'];
  if (token is! String ||
      !_validText(token, 8192, nonempty: true) ||
      type is! String ||
      type.toLowerCase() != 'bearer' ||
      (json.containsKey('expires_in') &&
          (expires is! int || expires < 1 || expires > 31536000))) {
    return invalid;
  }
  return SocialLoginResult._(
    SocialLoginKind.authenticated,
    'social.authenticated',
    OAuthToken._(token, 'Bearer', expires as int?),
  );
}
