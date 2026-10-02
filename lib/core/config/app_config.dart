enum AppEnvironment { development, staging, production, mock }

final class AppConfig {
  AppConfig({
    required this.environment,
    required this.useMock,
    this.baseEndpoint,
  }) {
    if (environment == AppEnvironment.production && useMock) {
      throw const FormatException('Production cannot enable mock behavior.');
    }
    if (environment == AppEnvironment.mock && !useMock) {
      throw const FormatException(
        'The mock environment requires useMock=true.',
      );
    }
    final endpoint = baseEndpoint;
    if (endpoint != null) _validateEndpoint(endpoint, environment);
  }

  final AppEnvironment environment;
  final Uri? baseEndpoint;
  final bool useMock;

  static AppConfig fromEnvironment(Map<String, String> values) {
    final rawEnvironment = values['environment'];
    if (rawEnvironment == null) {
      throw const FormatException('Missing environment configuration.');
    }
    final environment = switch (rawEnvironment) {
      'development' => AppEnvironment.development,
      'staging' => AppEnvironment.staging,
      'production' => AppEnvironment.production,
      'mock' => AppEnvironment.mock,
      _ => throw const FormatException('Invalid environment configuration.'),
    };

    final rawUseMock = values['useMock'];
    final useMock = switch (rawUseMock) {
      null || 'false' => false,
      'true' => true,
      _ => throw const FormatException('Invalid useMock configuration.'),
    };

    Uri? endpoint;
    final rawEndpoint = values['baseEndpoint'];
    if (rawEndpoint != null) {
      try {
        endpoint = Uri.parse(rawEndpoint);
      } on FormatException {
        throw const FormatException('Invalid baseEndpoint URI.');
      }
    }

    return AppConfig(
      environment: environment,
      useMock: useMock,
      baseEndpoint: endpoint,
    );
  }

  static void _validateEndpoint(Uri endpoint, AppEnvironment environment) {
    final authority = endpoint.authority;
    if (!endpoint.isAbsolute ||
        !endpoint.hasAuthority ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        endpoint.port > 65535 ||
        authority.contains('@') ||
        authority.contains('\\') ||
        authority.contains('%') ||
        authority.contains(' ') ||
        authority.contains('\t') ||
        authority.contains('\n') ||
        authority.contains('\r')) {
      throw const FormatException(
        'Unsafe baseEndpoint authority or URI parts.',
      );
    }
    if (endpoint.scheme != 'https' &&
        !(environment != AppEnvironment.production &&
            endpoint.scheme == 'http')) {
      throw const FormatException('baseEndpoint must use HTTPS.');
    }
  }
}
