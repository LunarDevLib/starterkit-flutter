import 'dart:convert';

enum AppUpdateStore { android, ios }

/// Product identity only; construction performs no validation or I/O.
final class AppUpdateTarget {
  const AppUpdateTarget.android({required String this.applicationId})
    : store = AppUpdateStore.android,
      storeId = null;

  const AppUpdateTarget.ios({required String this.storeId})
    : store = AppUpdateStore.ios,
      applicationId = null;

  final AppUpdateStore store;
  final String? applicationId;
  final String? storeId;
}

/// An immutable snapshot of untrusted transport bytes, not decoded metadata.
final class AppUpdateMetadataResponse {
  AppUpdateMetadataResponse({required this.statusCode, required List<int> body})
    : body = List<int>.unmodifiable(body);

  final int statusCode;
  final List<int> body;
}

/// Product-owned HTTPS origin, transport, redirects, headers and time limits.
abstract interface class AppUpdateMetadataReader {
  Future<AppUpdateMetadataResponse> read(String path);
}

/// True means the product opener accepted a launch, not an installed update.
abstract interface class AppUpdateStoreOpener {
  Future<bool> open(Uri uri);
}

/// Public candidates are untrusted; [StarterAppUpdateCapability.openStore]
/// always revalidates the version, raw URL and current product identity.
final class AppUpdateCandidate {
  const AppUpdateCandidate({
    required this.latestVersion,
    required this.storeUrl,
  });

  final String latestVersion;
  final String storeUrl;
}

enum AppUpdateCheckKind {
  current,
  updateAvailable,
  invalid,
  unavailable,
  failure,
}

final class AppUpdateCheckResult {
  const AppUpdateCheckResult._(this.kind, this.code, [this.candidate]);

  final AppUpdateCheckKind kind;
  final String code;
  final AppUpdateCandidate? candidate;
}

enum AppUpdateOpenKind { opened, invalid, unavailable, failure }

final class AppUpdateOpenResult {
  const AppUpdateOpenResult._(this.kind, this.code);

  final AppUpdateOpenKind kind;
  final String code;
}

/// Dormant by default. Checking never opens; opening never fetches metadata.
final class StarterAppUpdateCapability {
  const StarterAppUpdateCapability({
    this.enabled = false,
    this.target,
    this.reader,
    this.opener,
  });

  final bool enabled;
  final AppUpdateTarget? target;
  final AppUpdateMetadataReader? reader;
  final AppUpdateStoreOpener? opener;

  Future<AppUpdateCheckResult> check({
    required String metadataPath,
    required String currentVersion,
  }) async {
    if (!enabled) {
      return const AppUpdateCheckResult._(
        AppUpdateCheckKind.unavailable,
        'update.disabled',
      );
    }
    final configuredTarget = target;
    if (configuredTarget == null) {
      return const AppUpdateCheckResult._(
        AppUpdateCheckKind.unavailable,
        'update.target_not_configured',
      );
    }
    if (!_validTarget(configuredTarget)) {
      return const AppUpdateCheckResult._(
        AppUpdateCheckKind.invalid,
        'update.invalid_target',
      );
    }
    if (!_validPath(metadataPath)) {
      return const AppUpdateCheckResult._(
        AppUpdateCheckKind.invalid,
        'update.invalid_path',
      );
    }
    final current = _versionParts(currentVersion);
    if (current == null) {
      return const AppUpdateCheckResult._(
        AppUpdateCheckKind.invalid,
        'update.invalid_version',
      );
    }
    final configuredReader = reader;
    if (configuredReader == null) {
      return const AppUpdateCheckResult._(
        AppUpdateCheckKind.unavailable,
        'update.reader_not_configured',
      );
    }
    final AppUpdateMetadataResponse response;
    try {
      response = await configuredReader.read(metadataPath);
    } on Object {
      return const AppUpdateCheckResult._(
        AppUpdateCheckKind.failure,
        'update.network_failed',
      );
    }
    if (response.statusCode < 100 || response.statusCode > 599) {
      return const AppUpdateCheckResult._(
        AppUpdateCheckKind.invalid,
        'update.invalid_metadata',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return const AppUpdateCheckResult._(
        AppUpdateCheckKind.failure,
        'update.network_failed',
      );
    }
    final bytes = response.body;
    if (bytes.length > 16384) {
      return const AppUpdateCheckResult._(
        AppUpdateCheckKind.invalid,
        'update.response_too_large',
      );
    }
    if (bytes.any((byte) => byte < 0 || byte > 255)) {
      return const AppUpdateCheckResult._(
        AppUpdateCheckKind.invalid,
        'update.invalid_metadata',
      );
    }
    final Object? metadata;
    try {
      metadata = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    } on Object {
      return const AppUpdateCheckResult._(
        AppUpdateCheckKind.invalid,
        'update.invalid_metadata',
      );
    }
    if (metadata is! Map ||
        metadata.length != 2 ||
        metadata['version'] is! String ||
        metadata['storeURL'] is! String) {
      return const AppUpdateCheckResult._(
        AppUpdateCheckKind.invalid,
        'update.invalid_metadata',
      );
    }
    final latestVersion = metadata['version'] as String;
    final latest = _versionParts(latestVersion);
    if (latest == null) {
      return const AppUpdateCheckResult._(
        AppUpdateCheckKind.invalid,
        'update.invalid_version',
      );
    }
    final storeUrl = metadata['storeURL'] as String;
    final invalidUrl = _storeUrlError(storeUrl, configuredTarget);
    if (invalidUrl != null) {
      return AppUpdateCheckResult._(AppUpdateCheckKind.invalid, invalidUrl);
    }
    if (!_isNewer(latest, current)) {
      return const AppUpdateCheckResult._(
        AppUpdateCheckKind.current,
        'update.current',
      );
    }
    return AppUpdateCheckResult._(
      AppUpdateCheckKind.updateAvailable,
      'update.available',
      AppUpdateCandidate(latestVersion: latestVersion, storeUrl: storeUrl),
    );
  }

  Future<AppUpdateOpenResult> openStore(AppUpdateCandidate candidate) async {
    if (!enabled) {
      return const AppUpdateOpenResult._(
        AppUpdateOpenKind.unavailable,
        'update.disabled',
      );
    }
    final configuredTarget = target;
    if (configuredTarget == null) {
      return const AppUpdateOpenResult._(
        AppUpdateOpenKind.unavailable,
        'update.target_not_configured',
      );
    }
    if (!_validTarget(configuredTarget)) {
      return const AppUpdateOpenResult._(
        AppUpdateOpenKind.invalid,
        'update.invalid_target',
      );
    }
    if (_versionParts(candidate.latestVersion) == null) {
      return const AppUpdateOpenResult._(
        AppUpdateOpenKind.invalid,
        'update.invalid_version',
      );
    }
    final invalidUrl = _storeUrlError(candidate.storeUrl, configuredTarget);
    if (invalidUrl != null) {
      return AppUpdateOpenResult._(AppUpdateOpenKind.invalid, invalidUrl);
    }
    final configuredOpener = opener;
    if (configuredOpener == null) {
      return const AppUpdateOpenResult._(
        AppUpdateOpenKind.unavailable,
        'update.opener_not_configured',
      );
    }
    try {
      final opened = await configuredOpener.open(Uri.parse(candidate.storeUrl));
      return opened
          ? const AppUpdateOpenResult._(
              AppUpdateOpenKind.opened,
              'update.opened',
            )
          : const AppUpdateOpenResult._(
              AppUpdateOpenKind.unavailable,
              'update.no_handler',
            );
    } on Object {
      return const AppUpdateOpenResult._(
        AppUpdateOpenKind.failure,
        'update.open_failed',
      );
    }
  }
}

bool _matches(String value, String pattern) {
  final match = RegExp(pattern).firstMatch(value);
  return match != null && match.start == 0 && match.end == value.length;
}

bool _validApplicationId(String value) =>
    value.length <= 200 &&
    _matches(value, r'[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+');

bool _validStoreId(String value) => _matches(value, r'[0-9]{1,20}');

bool _validTarget(AppUpdateTarget target) => switch (target.store) {
  AppUpdateStore.android => _validApplicationId(target.applicationId!),
  AppUpdateStore.ios => _validStoreId(target.storeId!),
};

bool _validText(String value, int maxBytes) {
  if (value.length > maxBytes || RegExp(r'\s', unicode: true).hasMatch(value)) {
    return false;
  }
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

bool _validPath(String value) =>
    _validText(value, 2048) &&
    value.startsWith('/') &&
    !value.startsWith('//') &&
    !RegExp(r'[%?#\\]').hasMatch(value) &&
    !value.split('/').any((part) => part == '.' || part == '..');

List<BigInt>? _versionParts(String value) {
  if (value.length > 64 ||
      !_matches(value, r'[0-9]{1,18}(?:\.[0-9]{1,18}){0,3}')) {
    return null;
  }
  return value.split('.').map(BigInt.parse).toList(growable: false);
}

bool _isNewer(List<BigInt> latest, List<BigInt> current) {
  for (var index = 0; index < 4; index++) {
    final comparison = (index < latest.length ? latest[index] : BigInt.zero)
        .compareTo(index < current.length ? current[index] : BigInt.zero);
    if (comparison != 0) return comparison > 0;
  }
  return false;
}

String? _storeUrlError(String value, AppUpdateTarget target) {
  if (!_validText(value, 512)) return 'update.invalid_store_url';
  final pattern = switch (target.store) {
    AppUpdateStore.android => r'https://play\.google\.com(?::443)?/store/apps/details\?id=([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+)',
    AppUpdateStore.ios =>
      r'https://apps\.apple\.com(?::443)?/app/id([0-9]{1,20})',
  };
  final match = RegExp(pattern).firstMatch(value);
  if (match == null || match.start != 0 || match.end != value.length) {
    return 'update.invalid_store_url';
  }
  final identity = match.group(1)!;
  if (target.store == AppUpdateStore.android &&
      !_validApplicationId(identity)) {
    return 'update.invalid_store_url';
  }
  return identity == (target.applicationId ?? target.storeId)
      ? null
      : 'update.identity_mismatch';
}
