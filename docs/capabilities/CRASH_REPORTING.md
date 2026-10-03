# Handled Crash Reporting

## Status and boundary

- Classification: Optional handled-issue reporting service with a product transport
- Default connected: No
- Uncaught/fatal capture, global error hooks, stack traces, and automatic collection: None
- Production backend, consent flow, retention, and device behavior: **NOT RUN**

`StarterCrashReportingService` accepts only reports explicitly supplied by
product code. It does not install a global handler, intercept uncaught/fatal
errors, collect crashes automatically, or provide stack capture, symbolication,
user/device identity, or a vendor SDK. The default `SampleApp` does not import,
construct, or call this service. Construction is inert; `enabled` defaults to
`false`, consent defaults to denied, and disabled/denied submissions make zero
transport getter or request calls.

This is not a crash-capture SDK or privacy filter. The product owns consent and
its legal basis, backend access/retention, report selection, and review of every
context value. Never send PII, credentials, tokens, secrets, cookies, raw user
text, exception prose, stack traces, or any other sensitive content. A short
identifier-shaped string is not automatically safe.

## API and product transport

```dart
import 'package:starterkit_platform/starterkit_platform.dart';

// This transport is implemented/configured by the consuming product.
final crashReports = StarterCrashReportingService(
  enabled: true,
  consent: CrashConsent.granted,
  transport: productTelemetryTransport,
  endpoint: 'crash/handled',
  allowedHosts: productAllowedTelemetryHosts,
);

// Call only at a deliberate handled-error boundary after product consent checks.
final result = await crashReports.submit(
  HandledReport(
    issue: HandledIssue.parsing,
    code: 'catalog.decode_failed',
    context: const {
      'operation': 'decode',
      'component': 'catalog',
    },
  ),
);
```

The product implements `TelemetryTransport`, which exposes
`Uri get baseEndpoint` and
`Future<TelemetryResponse> execute(TelemetryRequest request)`. Requests use an
immutable copied body and fixed `POST` / `application/json`; callers cannot
provide arbitrary headers through this API. Responses contain an integer status
and immutable copied body bytes. No transport, endpoint origin, credentials,
direct HTTP adapter, or SDK is supplied.

`CrashConsent` is `denied` or `granted`. `HandledIssue` is limited to
`assertion`, `parsing`, `network`, `persistence`, `authentication`, and `other`.
`HandledReport` has a required issue and safe code plus an optional context map;
its map is snapshotted. Unknown context keys reject the report instead of being
silently discarded.

`StarterCrashReportingService` defaults to `enabled: false`, denied consent, no
transport, endpoint `crash/handled`, and an empty `allowedHosts`. Construction
does no I/O and does not read the transport's `baseEndpoint`. Consent and
configuration are immutable per instance; the host allowlist is copied rather
than retained as a mutable caller set.

## Explicit submission and bounded report

Product code explicitly calls `submit(HandledReport)` for a selected handled
issue. The service does not hook the process error path. Each valid granted
submission attempts exactly one transport request; there is no retry, buffer,
queue, offline cache, or delivery guarantee. A `submitted` result means only
that the transport returned an accepted 2xx status, not that a backend persisted
or delivered the report or that a crash was captured.

- `code` uses ASCII `[A-Za-z0-9._-]+` and is at most 48 bytes.
- Context has at most four entries, with only the exact keys `operation`,
  `screen`, `component`, and `stage`. Each value uses the same
  `[A-Za-z0-9._-]+` safe-code alphabet and is at most 64 bytes. Unknown keys
  reject the entire report.
- The exact JSON shape is `{issue, code, context}` and the serialized UTF-8 body
  is at most 1024 bytes. Invalid values are rejected, not silently stripped.
- These bounds constrain syntax and size; they do not redact data or prove a
  value is nonsensitive. Never place identities, user input, credentials, raw
  exception messages, stack traces, tokens, secrets, cookies, or PII in fields.

The product transport owns TLS/redirect policy, headers, credentials, request
acquisition limits, timeouts, and backend privacy/retention. Its `baseEndpoint`
is read only during enabled, granted submission. The endpoint must be a
nonempty relative path ≤2048 UTF-8 bytes with safe ASCII segments. It cannot
start with `/` or contain query/fragment, controls, whitespace, backslash,
encoded escapes, or dot segments. The joined URI is limited to 2048 bytes and
remains below the configured base path.

The base endpoint must use HTTPS and a canonical lowercase ASCII DNS host in
the exact `allowedHosts` set, with no userinfo/query/fragment and a valid
1–65535 explicit port. Its path is empty or slash-prefixed safe ASCII segments
(`[A-Za-z0-9._~-]+`), optionally with a trailing slash; encoded escapes and dot
segments are rejected, as are empty raw `?` or `#` delimiters. Up to 16 valid
DNS names of at most 253 bytes are accepted; malformed entries fail closed and
wildcard hosts are not supported. There is no default origin or trust-policy
override. The product owns its chosen secure origin and transport behavior.

Validation applies to the supplied `Uri` serialization. Dart may already have
normalized host casing, escapes or dot segments when constructing that `Uri`;
the original spelling cannot be recovered here. The relative endpoint string
is checked before joining. Products must validate their original configuration
and enforce transport origin/redirect policy; this facade is not proof of URL
construction provenance.

HTTP status must be an integer from 100 through 599; non-2xx is a fixed
failure. Response bodies are ignored, not parsed; byte values must be valid and
the body must not exceed 65536 bytes. Invalid/oversized responses, payload
errors, and transport/getter exceptions map to fixed outcomes without logging
or returning exception text.

## Consent, outcomes, and lifecycle

Disabled returns `disabled/telemetry.disabled`; denied consent returns
`denied/telemetry.consent_denied`. Both occur before reading the transport
getter or executing a request. Missing transport/configuration, invalid
payload, oversized payload/response, invalid response, and transport failure
remain distinct. Fixed codes are:

| Outcome | Fixed code |
| --- | --- |
| disabled / denied | `telemetry.disabled`, `telemetry.consent_denied` |
| unavailable | `telemetry.transport_not_configured` |
| invalid | `telemetry.invalid_configuration`, `telemetry.invalid_payload`, `telemetry.payload_too_large` |
| failure | `telemetry.transport_failed`, `telemetry.invalid_response`, `telemetry.response_too_large` |
| submitted | `telemetry.submitted` |

On consent revocation, product code must replace instances and remove old submit
call sites. An old instance is not mutated or revoked, and an already dispatched
request cannot be cancelled by this service. Consent storage, legal basis,
revocation UX, and cancellation are not supplied.

## Activation and removal

1. Keep `SampleApp` disconnected. Compose the service only at an explicit
   product-handled-error boundary, with real product transport and exact HTTPS
   host allowlisting. Do not supply a fake production adapter, credentials, or
   a starter-kit origin.
2. Check product consent before composition and each reporting decision. Send
   only deliberately selected handled issues; never add a fatal/global hook or
   automatic collection. Replace instances and remove call sites on revocation.
3. Review the issue, code, and each context value for product privacy. Safe
   character sets and size limits are not universal redaction or permission to
   transmit PII, credentials, tokens, secrets, cookies, user text, or stacks.
4. Add network permission/configuration only if the product's transport
   requires it and only for that product. This service adds no permission,
   background worker, or platform component.

To deactivate, remove product service composition and report call sites, then
remove unused transport/backend configuration and network permission. Keep
`starterkit_platform` while other capabilities still depend on it.

## Verification boundary

Focused deterministic tests are in
[`packages/starterkit_platform/test/analytics_crash_test.dart`](../../packages/starterkit_platform/test/analytics_crash_test.dart);
the services and ports are in
[`packages/starterkit_platform/lib/analytics_crash.dart`](../../packages/starterkit_platform/lib/analytics_crash.dart).
Unit tests can cover inert defaults, denied/disabled zero-call behavior,
serialization bounds, snapshots, endpoint validation, and fixed outcomes.
They do not establish uncaught/fatal capture, a production backend, consent
workflow, network/redirect/TLS policy, backend retention, delivery, physical
device behavior, signing, or iOS 13 runtime. Those product integrations remain
**NOT RUN** unless tested using their real implementations.
