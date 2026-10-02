/// Resource and transport limits for [HttpApiClient].
///
/// The policy is intentionally vendor-neutral and performs no I/O.
final class NetworkPolicy {
  const NetworkPolicy({this.requestTimeout = const Duration(seconds: 30)});

  static const int maxUriBytes = 2048;
  static const int maxRequestBodyBytes = 256 * 1024;
  static const int maxResponseBodyBytes = 1024 * 1024;
  static const int maxRequestHeaderCount = 32;
  static const int maxRequestHeaderBytes = 16 * 1024;
  static const int maxResponseHeaderCount = 128;
  static const int maxResponseHeaderBytes = 32 * 1024;

  final Duration requestTimeout;
}
