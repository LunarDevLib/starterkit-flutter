import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

const _viewType = 'starterkit/webview';
const _bundledLocalStart = 'BUNDLED_LOCAL';
const _localHost = 'appassets.starterkit.invalid';
const _localOrigin = 'https://appassets.starterkit.invalid';
const _localPathPrefix = '/starterkit-webview/';

@immutable
class TrustedOrigin {
  const TrustedOrigin._(this.host, this.port);

  final String host;
  final int port;

  static TrustedOrigin? tryParse(String raw) {
    if (raw.isEmpty || raw != raw.trim() || RegExp(r'\s').hasMatch(raw)) {
      return null;
    }
    final schemeBoundary = raw.indexOf('://');
    if (schemeBoundary <= 0 ||
        raw.substring(0, schemeBoundary).toLowerCase() != 'https') {
      return null;
    }
    final authorityStart = schemeBoundary + 3;
    final authorityEnd = _authorityEnd(raw, authorityStart);
    final authority = raw.substring(authorityStart, authorityEnd);
    if (authority.isEmpty ||
        authority.contains('%') ||
        authority.endsWith(':')) {
      return null;
    }
    final suffix = raw.substring(authorityEnd);
    if (suffix.isNotEmpty && suffix != '/') return null;

    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.host.isEmpty) {
      return null;
    }
    final int port;
    try {
      port = uri.port;
    } on FormatException {
      return null;
    }
    if (port < 1 || port > 65535) return null;
    return TrustedOrigin._(uri.host.toLowerCase(), port);
  }

  factory TrustedOrigin.parse(String raw) {
    return tryParse(raw) ??
        (throw ArgumentError.value(raw, 'raw', 'Invalid trusted HTTPS origin'));
  }

  String get rule {
    final normalizedHost = host.contains(':') ? '[$host]' : host;
    final portSuffix = port == 443 ? '' : ':$port';
    return 'https://$normalizedHost$portSuffix';
  }

  bool matches(Uri uri) {
    final int uriPort;
    try {
      uriPort = uri.port;
    } on FormatException {
      return false;
    }
    if (uri.scheme.toLowerCase() != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.host.toLowerCase() != host ||
        uriPort != port) {
      return false;
    }
    final authority = uri.authority;
    return authority.isNotEmpty &&
        !authority.contains('%') &&
        !authority.endsWith(':');
  }

  @override
  bool operator ==(Object other) =>
      other is TrustedOrigin && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);
}

int _authorityEnd(String raw, int start) {
  var end = raw.length;
  for (final marker in const ['/', '?', '#']) {
    final index = raw.indexOf(marker, start);
    if (index >= 0 && index < end) end = index;
  }
  return end;
}

enum StarterWebViewNavigationDecision {
  internal,
  localAsset,
  externalBrowser,
  externalApp,
  blocked,
}

class StarterWebViewNavigationPolicy {
  StarterWebViewNavigationPolicy({
    required this.trustedOrigin,
    Iterable<String> allowedExternalSchemes = const [],
  }) : allowedExternalSchemes = allowedExternalSchemes
           .map(_normalizeExternalScheme)
           .toSet();

  final TrustedOrigin trustedOrigin;
  final Set<String> allowedExternalSchemes;

  StarterWebViewNavigationDecision decide(
    String raw, {
    bool mainFrame = true,
    bool userGesture = false,
  }) {
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme.isEmpty) {
      return StarterWebViewNavigationDecision.blocked;
    }
    if (_isAllowedLocalUri(uri)) {
      return StarterWebViewNavigationDecision.localAsset;
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'https') {
      if (trustedOrigin.matches(uri)) {
        return StarterWebViewNavigationDecision.internal;
      }
      return mainFrame &&
              userGesture &&
              uri.host.isNotEmpty &&
              uri.userInfo.isEmpty &&
              !uri.authority.contains('%') &&
              !uri.authority.endsWith(':')
          ? StarterWebViewNavigationDecision.externalBrowser
          : StarterWebViewNavigationDecision.blocked;
    }
    if (allowedExternalSchemes.contains(scheme) &&
        mainFrame &&
        userGesture &&
        uri.userInfo.isEmpty) {
      return StarterWebViewNavigationDecision.externalApp;
    }
    return StarterWebViewNavigationDecision.blocked;
  }
}

bool _isAllowedLocalUri(Uri uri) {
  final int port;
  try {
    port = uri.port;
  } on FormatException {
    return false;
  }
  return uri.scheme.toLowerCase() == 'https' &&
      uri.userInfo.isEmpty &&
      uri.host.toLowerCase() == _localHost &&
      port == 443 &&
      uri.query.isEmpty &&
      uri.fragment.isEmpty &&
      uri.path.startsWith(_localPathPrefix) &&
      !uri.pathSegments.any(
        (segment) =>
            segment == '.' ||
            segment == '..' ||
            segment.contains('%') ||
            segment.contains(r'\'),
      );
}

String _normalizeExternalScheme(String raw) {
  final scheme = raw.toLowerCase();
  if (!RegExp(r'^[a-z][a-z0-9+.-]*$').hasMatch(scheme) ||
      const {
        'http',
        'https',
        'file',
        'content',
        'javascript',
        'data',
        'about',
      }.contains(scheme)) {
    throw ArgumentError.value(raw, 'allowedExternalSchemes');
  }
  return scheme;
}

@immutable
class StarterWebViewConfiguration {
  const StarterWebViewConfiguration._({
    required this.trustedOrigin,
    required this.startUrl,
    required this.bridgeEnabled,
    required this.allowedExternalSchemes,
  });

  factory StarterWebViewConfiguration({
    required String trustedOrigin,
    String? startUrl,
    bool bridgeEnabled = false,
    Iterable<String> allowedExternalSchemes = const [],
  }) {
    final origin = TrustedOrigin.parse(trustedOrigin);
    String? normalizedStart;
    if (startUrl != null) {
      final uri = Uri.tryParse(startUrl);
      if (uri == null || !origin.matches(uri)) {
        throw ArgumentError.value(
          startUrl,
          'startUrl',
          'Remote start URL must match trustedOrigin exactly',
        );
      }
      normalizedStart = uri.toString();
    }
    final schemes = allowedExternalSchemes
        .map(_normalizeExternalScheme)
        .toSet();
    return StarterWebViewConfiguration._(
      trustedOrigin: origin,
      startUrl: normalizedStart,
      bridgeEnabled: bridgeEnabled,
      allowedExternalSchemes: Set.unmodifiable(schemes),
    );
  }

  final TrustedOrigin trustedOrigin;
  final String? startUrl;
  final bool bridgeEnabled;
  final Set<String> allowedExternalSchemes;

  bool get usesBundledLocalStart => startUrl == null;

  Map<String, Object?> toCreationParams() => {
    'trustedOrigin': trustedOrigin.rule,
    'startUrl': startUrl ?? _bundledLocalStart,
    'bridgeEnabled': bridgeEnabled,
    'allowedExternalSchemes': allowedExternalSchemes.toList(growable: false),
  };
}

class StarterWebViewController {
  StarterWebViewController._(int viewId, this.configuration)
    : _channel = MethodChannel('starterkit/webview/$viewId');

  final MethodChannel _channel;
  final StarterWebViewConfiguration configuration;
  bool _disposed = false;

  Future<void> loadStart() async {
    _ensureActive();
    await _channel.invokeMethod<void>('loadStart');
  }

  Future<void> load(Uri url) async {
    _ensureActive();
    if (!configuration.trustedOrigin.matches(url)) {
      throw ArgumentError.value(url, 'url', 'URL is outside trustedOrigin');
    }
    await _channel.invokeMethod<void>('load', {'url': url.toString()});
  }

  Future<bool> bridgeAvailable() async {
    _ensureActive();
    return await _channel.invokeMethod<bool>('bridgeAvailable') ?? false;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _channel.invokeMethod<void>('dispose');
  }

  void _ensureActive() {
    if (_disposed) {
      throw StateError('StarterWebViewController is disposed');
    }
  }
}

class StarterWebView extends StatefulWidget {
  const StarterWebView({
    required this.configuration,
    this.onCreated,
    super.key,
  });

  final StarterWebViewConfiguration configuration;
  final ValueChanged<StarterWebViewController>? onCreated;

  @override
  State<StarterWebView> createState() => _StarterWebViewState();
}

class _StarterWebViewState extends State<StarterWebView> {
  void _created(int viewId) {
    widget.onCreated?.call(
      StarterWebViewController._(viewId, widget.configuration),
    );
  }

  @override
  Widget build(BuildContext context) {
    final creationParams = widget.configuration.toCreationParams();
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidView(
        viewType: _viewType,
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: _created,
      );
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return UiKitView(
        viewType: _viewType,
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: _created,
      );
    }
    throw UnsupportedError('starterkit_webview supports only Android and iOS');
  }
}

const starterWebViewBundledLocalOrigin = _localOrigin;
