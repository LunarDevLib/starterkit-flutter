# Remote Config

## Status and boundary

- Classification: Optional typed configuration reader/service
- Default connected: No
- Default reader/origin, background fetch, persistence, polling, retry, or vendor SDK: None
- Production backend, reader, expiry clock, product consumer, and device: **NOT RUN**

`StarterRemoteConfigService` fetches a typed snapshot only after an explicit
product call to `fetch()`. `SampleApp` and the immutable local boolean-only
`FeatureFlags` remain unchanged. Construction is inert: no reader, base URI,
or clock is accessed. The service defaults disabled and has no bundled reader,
backend, endpoint origin, persistence, polling, or retry.

Remote values are **not a security boundary**. Never drive authentication,
permissions, trust roots, endpoints, credentials, secrets, or security-sensitive
behavior from remote flags. Name filtering and types do not make values safe for
those decisions. There is no product adapter or root-app composition supplied.

## API and product reader

```dart
import 'package:starterkit_platform/starterkit_platform.dart';

final remoteConfig = StarterRemoteConfigService(
  enabled: true,
  reader: productRemoteConfigReader, // Product implementation, not bundled.
  endpoint: 'config/snapshot',
  allowedHosts: productConfigHosts,
  defaults: const {'new_checkout': RemoteValue.boolean(false)},
  allowedSchema: const {'new_checkout': RemoteValueType.boolean},
);

// Call only at an explicit product decision point, not during startup/polling.
Future<RemoteConfigFetchResult> fetchFromProductAction() =>
    remoteConfig.fetch();

final newCheckout = remoteConfig.flags.value('new_checkout');
```

`RemoteValueType` is `boolean`, `integer`, or `text`.
`RemoteValue` has immutable const `.boolean(bool)`, `.integer(int)`, and
`.text(String)` constructors with final `type` and `value`; no arbitrary dynamic
value constructor is provided. `FeatureFlagReading.value(String key)` returns a
typed `RemoteValue?`; an unknown key returns null.

`RemoteConfigReader` exposes `Uri get baseEndpoint` and
`Future<RemoteConfigResponse> read(String relativePath)`. Its contract is GET
with `Accept: application/json`. `RemoteConfigResponse` contains a status code
and immutable copied body bytes. The product owns the actual configured reader,
TLS/redirect policy, headers/credentials, acquisition limits, timeouts, stable
routing, and backend retention. No reader, HTTP client, origin, SDK, or network
adapter is bundled.

Constructor defaults: `enabled: false`, nullable reader, endpoint
`config/snapshot`, empty `allowedHosts`, `defaults`, and `allowedSchema`, and
`DateTime.now` as a clock function. Caller maps/sets are snapshotted. The clock
is not called at construction. Configuration/enabled state are immutable per
instance. A disabled fetch returns `remote.disabled` without reader or clock
calls.

## Snapshots, defaults, and schema

`RemoteConfigSnapshot` has immutable `version`, nullable `expiresAt`, and an
unmodifiable copied `Map<String, RemoteValue> values`. Initial state is version
0, no expiry, and local defaults. `snapshot` returns the stored snapshot for
inspection; it may be expired. Consumers use `flags.value(key)`, not an expired
snapshot's values, to decide current behavior.

`fetch()` returns `RemoteConfigFetchResult(kind, code, snapshot?)`; only
`applied` includes a snapshot. A valid payload is merged into a fresh copy of
the original defaults. Remote values replace matching defaults; omitted values
revert to original defaults, not a previous remote value. Publish one complete
immutable snapshot only after every check passes. Errors never partially apply.

The JSON object has exactly `version`, `expires_at`, and `values`:

- `version`: integer `1..2^63-1`; bool/double/null/out-of-range values reject.
  Versions need not increase; rollback prevention is not provided.
- `expires_at`: finite numeric Unix epoch **seconds** (integer or double, not
  bool/string/ISO text). Convert to UTC; require a strictly future time and
  TTL ≤31,536,000 seconds from the injected clock; unrepresentable timestamps
  reject.
- `values`: object of at most 64 safe keys, each present in `allowedSchema` with
  an exact bool/int/text type. Integers fit signed 64-bit range. Text is ≤128
  UTF-8 bytes and rejects C0, DEL, C1 controls, and malformed Unicode. Unknown,
  disallowed, mistyped, or invalid values reject the entire response.

Defaults may contain benign local flags absent from the remote schema. Both
maps use ASCII keys `[A-Za-z][A-Za-z0-9_.-]{0,63}`; default values use the same
typed bounds. If a key is in both maps, types must match. Local config is
validated before accessing the reader; invalid config returns a fixed invalid
result while preserving local defaults.

Schema keys are lowercased and separators removed before checking protected
substrings: `endpoint`, `host`, `url`, `permission`, `authorization`, `auth`,
`token`, `secret`, `credential`, `security`, `trust`, `certificate`, `pinning`,
and `tls`. Reject protected names even if accidentally allowlisted. This
name-based filter is not a semantic privacy/security guarantee.

Responses require integer status 100–599; non-2xx is transport failure. Body
bytes must be 0–255, at most 16 KiB, and strict UTF-8 JSON. Extra/missing top
keys, malformed JSON, oversize, unknown keys, or any invalid item reject the
whole response. Bodies and exception text are not returned or logged.

## Expiry and generation policy

Each enabled `fetch()` synchronously advances its generation before product
getters, reads, or clock calls. The newest-started valid result may apply; an
older request cannot overwrite it. If the latest request fails, the prior stored
snapshot remains, but older responses still cannot replace it. Check generation
after awaits/errors and immediately before the one synchronous snapshot
assignment. Reentrant getters, reads, clocks, fetch, or reset are fenced. This
is atomic publication within one Dart isolate, not cross-isolate consistency.

At flag-read time a snapshot is current only while `expiresAt > now()`. At or
after expiry, `flags.value` returns local default (or null); the stored snapshot
remains for inspection. Initial/default/disabled reads do not call the clock. A
clock exception returns defaults rather than stale remote values; fetch reports
`remote.clock_failed`. The clock is rechecked before apply, and reentrant
invalidation prevents publication.

`reset()` synchronously invalidates pending generations and restores version
0/local defaults/no expiry without reader or clock calls. It does not physically
abort network I/O or promise to settle a future whose product read hangs. Reset
does not disable the service. For opt-out, remove fetch/consumer calls and
replace/remove the immutable enabled instance as appropriate.

## Endpoint and results

The endpoint is a nonempty relative ASCII path ≤2048 UTF-8 bytes: no
leading/trailing slash, query, fragment, authority, controls, whitespace,
backslash, encoded escape, or dot segment. The supplied reader base must be
HTTPS with a canonical lowercase ASCII DNS host in the exact allowlist (≤16
valid hosts, each ≤253 bytes with labels ≤63), valid port 1–65535, no userinfo,
query/fragment/empty raw `?` or `#`, and safe base path with optional trailing
slash. Base path segments are safe ASCII `[A-Za-z0-9._~-]+`, optionally with a
trailing slash. Snapshot the base URI once per fetch; join the endpoint as a
directory under the same origin/path; final URI ≤2048 bytes.
The reader must honor the joined path and provide a stable base contract.

Validation sees the supplied `Uri` serialization; parsing may already normalize
spelling. It cannot prove original text, transport routing, TLS, or redirects.
The product owns those guarantees. Remote values never select origins, trust
roots, permissions, or authorization policy. Base getter errors map to
`remote.transport_failed`.

| Result kind | Fixed codes |
| --- | --- |
| disabled | `remote.disabled` |
| unavailable | `remote.reader_not_configured` |
| invalid | `remote.invalid_configuration`, `remote.invalid_schema`, `remote.expired` |
| failure | `remote.transport_failed`, `remote.clock_failed`, `remote.response_too_large`, `remote.invalid_response` |
| superseded | `remote.superseded` |
| applied | `remote.applied` |

An invalid latest result does not erase a prior snapshot; older responses are
superseded. There is no cache, retry, batch, queue, persistence, polling, push
invalidation, signature/rollback protocol, or experiment framework.

## Activation and removal

1. Keep `SampleApp` and root `FeatureFlags` unchanged. Compose the service
   only where product code explicitly needs benign remote values.
2. Implement a real reader with HTTPS origin, exact host allowlist, stable
   routing, TLS/redirect, and acquisition policy. Supply safe typed defaults and
   only the schema keys required. Adapt a root client at the product composition
   boundary; the platform package must not import app-core.
3. Fetch only from deliberate product behavior. Handle every typed result;
   consult expiry through the `flags` view. Never make security decisions from
   remote values or consume expired stored values.
4. Add network permission only if the product reader needs it and only in that
   product scope. This service adds no permission or platform component.

To deactivate, remove fetch calls and consumers, reset to defaults as needed,
and replace/remove the instance. Remove unused reader/backend configuration and
network permission only when no other feature needs them. Keep
`starterkit_platform` while other capabilities use it.

## Verification boundary

Focused tests are in
[`packages/starterkit_platform/test/remote_config_test.dart`](../../packages/starterkit_platform/test/remote_config_test.dart);
the service API is in
[`packages/starterkit_platform/lib/remote_config.dart`](../../packages/starterkit_platform/lib/remote_config.dart).
Tests may cover strict schemas, expiry, snapshots, generation races,
reentrancy, reset, and zero-call defaults; no test count/pass is claimed here.
They do not establish a production reader/backend, TLS/redirect behavior,
wall-clock correctness, product consumers, device behavior, signing, or iOS 13
runtime. Those integrations remain **NOT RUN** unless verified with real
product implementations.
