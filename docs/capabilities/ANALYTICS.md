# Analytics

## Status and boundary

- Classification: Optional Dart service with a product-supplied transport port
- Default connected: No
- Bundled endpoint/client, vendor SDK, automatic collection, and default consent: None
- Production backend, privacy/consent flow, retention, and device behavior: **NOT RUN**

`StarterAnalyticsService` validates a small explicitly submitted event and sends
one request through a product-provided `TelemetryTransport`. It does not track
screens, actions, users, sessions, or devices automatically. The default
`SampleApp` does not import, construct, or call this service. Construction is
inert; `enabled` defaults to `false`, consent defaults to denied, and denied or
disabled submission makes zero transport getter or request calls.

The service is not a privacy filter or consent framework. Product owners remain
responsible for legal basis, consent storage/revocation UX, event selection,
backend access/retention, and review of every submitted value. Do not include
personal data, credentials, tokens, secrets, cookies, raw user text, exception
prose, or other sensitive information. A value that looks like a safe identifier
may still be sensitive.

## API and product transport

```dart
import 'package:starterkit_platform/starterkit_platform.dart';

// ProductTransport is the consuming product's configured implementation.
final analytics = StarterAnalyticsService(
  enabled: true,
  consent: AnalyticsConsent.granted,
  transport: productTelemetryTransport,
  endpoint: 'analytics/events',
  allowedHosts: productAllowedTelemetryHosts,
);

// Call only at an explicit product event point after product consent checks.
final result = await analytics.submit(
  AnalyticsEvent(
    name: 'checkout_complete',
    fields: {
      AnalyticsField.action: const AnalyticsFieldValue.text('complete'),
      AnalyticsField.success: const AnalyticsFieldValue.boolean(true),
    },
  ),
);
```

The product implements `TelemetryTransport`, which exposes
`Uri get baseEndpoint` and
`Future<TelemetryResponse> execute(TelemetryRequest request)`. The request has
an immutable copied body and fixed `POST` method with `application/json`
content type; callers cannot add arbitrary headers through this API. A response
contains an integer status code and an immutable copy of its body bytes. No
transport, endpoint origin, credential, direct HTTP adapter, or vendor SDK is
provided here.

`AnalyticsConsent` is `denied` or `granted`. `AnalyticsField` is limited to
`screen`, `action`, `category`, `value`, and `success`. Values use the closed
immutable types `AnalyticsFieldValue.text(String)`, `.integer(int)`,
`.decimal(double)`, or `.boolean(bool)`. `AnalyticsEvent` snapshots its fields
map; later caller mutation does not change the submitted event.

The service defaults are `enabled: false`, denied consent, no transport,
endpoint `analytics/events`, and an empty `allowedHosts`. Construction does not
read `baseEndpoint` or perform I/O. Consent and configuration are immutable per
instance; the service snapshots the host allowlist rather than retaining a
mutable caller set.

## Submission and bounded payload

The product explicitly calls `submit(AnalyticsEvent)`; construction and consent
configuration never submit an event. Each valid granted submission attempts
exactly one transport request. There is no retry, buffer, queue, offline cache,
or delivery guarantee. A `submitted` result means only that the transport
returned an accepted 2xx status, not that telemetry was persisted, delivered,
or retained by a backend.

- Event names use ASCII `[A-Za-z0-9._-]+`, at most 64 UTF-8 bytes.
- At most eight fields are accepted. The current enum exposes five keys; the
  bound does not imply extra keys are available.
- Text values are at most 128 UTF-8 bytes and reject C0, DEL, and C1 controls.
  Integers must fit signed 64-bit range; decimal values must be finite.
  Booleans are typed booleans, not strings.
- The exact JSON shape is `{name, fields}` and the serialized UTF-8 body is at
  most 2048 bytes. Unknown fields/types and malformed values are rejected, not
  silently removed. These constraints do not detect or redact sensitive content.

The product transport owns TLS and redirect behavior, request acquisition/body
limits, headers, credentials, timeouts, and backend privacy/retention. Its
`baseEndpoint` is read only for an enabled, granted submission. The endpoint
must be a relative nonempty path (≤2048 UTF-8 bytes) with safe ASCII path
segments; it cannot begin with `/`, contain query/fragment, whitespace,
controls, backslashes, encoded escapes, or dot segments. The joined URI is
bounded to 2048 UTF-8 bytes and remains under the configured base path.

The base endpoint must be HTTPS, have a canonical lowercase ASCII DNS host in
the exact `allowedHosts` set, and contain no userinfo, query, or fragment. A
valid explicit port is 1–65535. The base path is empty or slash-prefixed safe
ASCII segments (`[A-Za-z0-9._~-]+`), optionally ending in `/`; encoded escapes
and dot segments are rejected. Empty raw `?` or `#` delimiters are rejected
too. Host allowlists are limited to 16 valid DNS names (≤253 bytes each);
malformed entries fail closed and wildcards are not supported. There is no
default origin or trust-policy override. The product chooses and secures the
origin; an event endpoint cannot replace it.

Validation applies to the supplied `Uri` serialization. Dart may already have
normalized host casing, escapes or dot segments when constructing that `Uri`;
the original spelling cannot be recovered here. The relative endpoint string
is checked before joining. Products must validate their original configuration
and enforce transport origin/redirect policy; this facade is not proof of URL
construction provenance.

Transport status must be an integer from 100 through 599. Non-2xx status is a
fixed failure. Response bytes must be valid byte values and no larger than
65536 bytes; response content is ignored, not parsed. Oversized/malformed
responses and transport/getter exceptions map to fixed codes without logging or
returning exception text.

## Consent, outcomes, and lifecycle

Disabled submission returns `disabled/telemetry.disabled`; denied consent
returns `denied/telemetry.consent_denied`. Both happen before reading the
transport getter or executing a request. Missing transport/configuration,
invalid payload, oversized payload/response, invalid response, and transport
failure are distinct fixed outcomes. The code family is:

| Outcome | Fixed code |
| --- | --- |
| disabled / denied | `telemetry.disabled`, `telemetry.consent_denied` |
| unavailable | `telemetry.transport_not_configured` |
| invalid | `telemetry.invalid_configuration`, `telemetry.invalid_payload`, `telemetry.payload_too_large` |
| failure | `telemetry.transport_failed`, `telemetry.invalid_response`, `telemetry.response_too_large` |
| submitted | `telemetry.submitted` |

For consent revocation, the product must replace service instances and remove
the old submit call sites. Existing instances are immutable; retaining an old
granted instance does not make it revoked. An already dispatched request cannot
be cancelled by this service. The API provides no consent storage, legal basis,
revocation UI, or cancellation guarantee.

## Activation and removal

1. Keep `SampleApp` disconnected. Compose this service only in the product
   feature that owns explicit event submission, with a real product transport,
   HTTPS origin, and exact host allowlist. Do not use fake production transports,
   placeholder credentials, or a starter-kit default endpoint.
2. Obtain and enforce product consent before composition/submission. On denial,
   do not submit. On revocation, replace the instance and remove call sites;
   account for requests already handed to the product transport.
3. Review event names and every field against product privacy requirements.
   Fixed safe shapes are not universal redaction; never pass PII, credentials,
   tokens, secrets, cookies, raw user text, exception strings, or stacks.
4. Add networking permission/configuration only if the product's chosen
   transport needs it and only in that product's scope. This service adds no
   permission, background worker, or platform component.

To deactivate, remove product composition and event call sites, then remove
product transport configuration and any no-longer-needed network permission.
Keep `starterkit_platform` while other capabilities still use it.

## Verification boundary

Focused deterministic contract tests are in
[`packages/starterkit_platform/test/analytics_crash_test.dart`](../../packages/starterkit_platform/test/analytics_crash_test.dart);
the service and ports are in
[`packages/starterkit_platform/lib/analytics_crash.dart`](../../packages/starterkit_platform/lib/analytics_crash.dart).
Unit tests can cover injected transports, consent/disabled zero-call behavior,
validation, snapshots, and fixed outcomes. They do not establish a production
endpoint, legal consent flow, redirect/TLS behavior, backend retention,
physical-device behavior, delivery, signing, or iOS 13 runtime. Those product
integrations remain **NOT RUN** unless verified with their real implementations.
