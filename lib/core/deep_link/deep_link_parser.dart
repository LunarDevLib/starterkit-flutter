import '../failure/app_failure.dart';

enum DeepLinkRouteKind { home, sampleDetail }

/// A route value that can be handed to an application router explicitly.
final class DeepLinkRoute {
  const DeepLinkRoute({required this.kind, this.id, this.returnTo});

  final DeepLinkRouteKind kind;
  final String? id;
  final String? returnTo;
}

sealed class DeepLinkParseResult {
  const DeepLinkParseResult();
}

final class DeepLinkParsed extends DeepLinkParseResult {
  const DeepLinkParsed(this.route);

  final DeepLinkRoute route;
}

final class DeepLinkRejected extends DeepLinkParseResult {
  const DeepLinkRejected(this.failure);

  final AppFailure failure;
}

/// Parses only the starter kit's two deliberate route shapes.
///
/// The scheme is supplied by the composing application. This parser neither
/// reads global identity nor configures OS delivery or a router.
final class DeepLinkParser {
  DeepLinkParser({required this.scheme, this.host = 'app'}) {
    if (!_schemePattern.hasMatch(scheme) || scheme != scheme.toLowerCase()) {
      throw ArgumentError.value(
        scheme,
        'scheme',
        'must be a lowercase URI scheme',
      );
    }
    if (host != 'app') {
      throw ArgumentError.value(host, 'host', 'must be app');
    }
  }

  final String scheme;
  final String host;

  static final RegExp _schemePattern = RegExp(r'^[a-z][a-z0-9+.-]{0,31}$');
  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,80}$');
  static final RegExp _detailPath = RegExp(r'^/samples/([A-Za-z0-9_-]{1,80})$');

  DeepLinkParseResult parse(String input) {
    if (input.length > 2048 ||
        _containsControl(input) ||
        RegExp(r'%(?![0-9a-fA-F]{2})').hasMatch(input)) {
      return _invalid();
    }

    final uri = Uri.tryParse(input);
    final rawPath = _rawPath(input);
    if (uri == null ||
        uri.scheme != scheme ||
        !uri.hasAuthority ||
        uri.authority != host ||
        uri.host != host ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.hasFragment ||
        input.contains('#') ||
        rawPath.contains('%') ||
        _hasEncodedSeparator(rawPath) ||
        _containsTraversal(rawPath)) {
      return _invalid();
    }

    final returnTo = _readReturnTo(uri);
    if (returnTo is _InvalidValue) return _invalid();

    if (rawPath == '/') {
      return DeepLinkParsed(
        DeepLinkRoute(
          kind: DeepLinkRouteKind.home,
          returnTo: returnTo as String?,
        ),
      );
    }
    final match = _detailPath.firstMatch(rawPath);
    if (match != null && _idPattern.hasMatch(match.group(1)!)) {
      return DeepLinkParsed(
        DeepLinkRoute(
          kind: DeepLinkRouteKind.sampleDetail,
          id: match.group(1),
          returnTo: returnTo as String?,
        ),
      );
    }
    if (rawPath.startsWith('/samples/')) return _invalid();
    return DeepLinkRejected(
      AppFailure(
        FailureKind.notFound,
        code: 'deep_link.not_found',
        localizationKey: 'failure.deep_link_not_found',
      ),
    );
  }

  Object? _readReturnTo(Uri uri) {
    if (!uri.hasQuery) return null;
    if (uri.query.isEmpty) return const _InvalidValue();

    String? returnTo;
    final seen = <String>{};
    for (final pair in uri.query.split('&')) {
      if (pair.isEmpty) return const _InvalidValue();
      final separator = pair.indexOf('=');
      if (separator <= 0) return const _InvalidValue();
      final key = _decodeQueryPart(pair.substring(0, separator));
      final value = _decodeQueryPart(pair.substring(separator + 1));
      if (key == null || value == null || !seen.add(key)) {
        return const _InvalidValue();
      }
      final normalizedKey = key.toLowerCase();
      if (_secretQueryKey.hasMatch(normalizedKey) || key != 'returnTo') {
        return const _InvalidValue();
      }
      if (value.length > 256 || !_isSafeReturnPath(value)) {
        return const _InvalidValue();
      }
      returnTo = value;
    }
    return returnTo;
  }

  static final RegExp _secretQueryKey = RegExp(
    r'(token|secret|password|credential|authorization|api[_-]?key)',
    caseSensitive: false,
  );

  static String? _decodeQueryPart(String value) {
    if (RegExp(r'%(?![0-9a-fA-F]{2})').hasMatch(value)) return null;
    try {
      final decoded = Uri.decodeQueryComponent(value);
      return _containsControl(decoded) ? null : decoded;
    } on FormatException {
      return null;
    }
  }

  bool _isSafeReturnPath(String path) {
    if (path.length > 256 ||
        !path.startsWith('/') ||
        path.startsWith('//') ||
        path.contains(r'\') ||
        path.contains('%') ||
        path.contains('?') ||
        path.contains('#') ||
        _containsControl(path)) {
      return false;
    }
    if (path == '/') return true;
    final match = _detailPath.firstMatch(path);
    return match != null && _idPattern.hasMatch(match.group(1)!);
  }

  static bool _hasEncodedSeparator(String path) =>
      RegExp(r'%(?:2f|5c)', caseSensitive: false).hasMatch(path);

  static bool _containsTraversal(String path) =>
      path.split('/').any((segment) => segment == '.' || segment == '..');

  static String _rawPath(String input) {
    final authorityStart = input.indexOf('://');
    if (authorityStart < 0) return '';
    final remainder = input.substring(authorityStart + 3);
    final delimiters = RegExp(r'[?#]').firstMatch(remainder);
    final authorityAndPath = delimiters == null
        ? remainder
        : remainder.substring(0, delimiters.start);
    final pathStart = authorityAndPath.indexOf('/');
    return pathStart < 0 ? '' : authorityAndPath.substring(pathStart);
  }

  static bool _containsControl(String value) =>
      value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f);

  static DeepLinkRejected _invalid() => DeepLinkRejected(
    AppFailure(
      FailureKind.validation,
      code: 'deep_link.invalid',
      localizationKey: 'failure.deep_link_invalid',
    ),
  );
}

final class _InvalidValue {
  const _InvalidValue();
}
