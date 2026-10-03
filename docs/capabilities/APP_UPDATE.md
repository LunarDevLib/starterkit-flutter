# App Update

## Status and boundary

- Classification: Optional Dart capability with product-supplied ports
- Dart validation facade and contract tests are provided
- Default connected: No
- Production metadata service, network adapter, store opener, store availability, installation, and device behavior: **NOT RUN**

App Update checks version metadata and can ask an explicitly composed product
opener to launch a store listing. It does not download, install, or verify an
update. The default `SampleApp` does not import, create, route to, or initialize
this capability. Construction is inert; `StarterAppUpdateCapability` defaults
to disabled and disabled actions make zero reader/opener calls.

There is no bundled metadata endpoint/client, store SDK, default product reader,
or production store opener. The facade owns input, response, version, identity,
and canonical-URL validation; the consuming product supplies configured ports.
No automatic check, navigation, store launch, forced upgrade, background job,
cache, retry, binary transfer, permission, or new SDK is added.

## API and product ports

```dart
import 'package:starterkit_platform/starterkit_platform.dart';

// These are product implementations, not adapters supplied by Starter Kit.
final capability = StarterAppUpdateCapability(
  enabled: true,
  target: AppUpdateTarget.android(
    applicationId: productAndroidApplicationId,
  ),
  reader: productMetadataReader,
  opener: productStoreOpener,
);

final result = await capability.check(
  metadataPath: '/mobile/update',
  currentVersion: productVersion,
);
// Invoke openStore(candidate) only from a separate, explicit user action.
final candidate = result.candidate;
```

The API includes `AppUpdateStore.android/ios`, immutable
`AppUpdateTarget.android({required applicationId})` and
`AppUpdateTarget.ios({required storeId})`,
`AppUpdateMetadataReader.read(String path)`, and
`AppUpdateStoreOpener.open(Uri uri) -> Future<bool>`. Android application IDs
and iOS store IDs come from the consuming product; they are not starter-kit
identities or template literals.

The reader returns an `AppUpdateMetadataResponse` containing an integer HTTP
`statusCode` and an immutable copy of the response body bytes. The opener's
boolean means only that the product opener accepted an explicit launch request:
`true` does not mean the app is installed, an update was downloaded, or an
update completed. `false` is reported as unavailable/no handler.

`check(metadataPath:, currentVersion:)` returns a typed result with `kind`,
fixed `code`, and nullable `candidate`. The kinds distinguish `current`,
`updateAvailable`, `invalid`, `unavailable`, and `failure`; only an
`updateAvailable` result contains an `AppUpdateCandidate` with `latestVersion`
and `storeUrl`.
`openStore(candidate)` is a separate action returning a typed `opened`,
`invalid`, `unavailable`, or `failure` result. It revalidates the candidate's
version, target identity, and store URL before calling the product opener.
Candidates are untrusted input even when they came from an earlier check.

The port implementations belong at the product composition boundary. A product
may adapt its existing configured API client to `read(path)`; that client owns
the metadata origin, HTTPS and redirect policy, headers, credentials, and
transport timeouts. This facade performs no HTTP request and has no fixed
endpoint or trust-policy override. The product opener owns OS launch behavior.
Injected test fakes are test-only, not production defaults.

## Check and validation policy

- A disabled call returns `unavailable/update.disabled` before validation or
  port access. Missing target/reader/opener configuration returns its fixed
  unavailable code without calling an absent port.
- `metadataPath` is a root-relative path with one leading `/`, at most 2048
  UTF-8 bytes. It rejects query/fragment, controls, whitespace, encoded escapes,
  backslashes, dot segments, and origin overrides. A path cannot select a new
  host or replace the product reader's configured origin.
- Current/latest versions are ASCII numeric dotted versions: 1–4 components,
  at most 64 characters total and 18 digits per component. Comparison uses
  integer components with zero-padding, so `1.2` equals `1.2.0`; leading zeros
  are accepted. Values are never compared lexicographically or coerced through
  floating point.
- A reader response requires an integer status in 100–599 and a body no larger
  than 16 KiB. Non-2xx status is a fixed network failure. A 2xx body must be
  strict UTF-8 JSON containing exactly the string fields `version` and
  `storeURL`; extra/missing keys, wrong types, malformed JSON/UTF-8, or invalid
  field values fail closed. Oversized bodies have their own invalid result.
- Store URLs are at most 512 UTF-8 bytes and use the canonical ASCII HTTPS
  listing forms below. Scheme, host, and path use the required lowercase
  spelling; optional port 443 is accepted. Userinfo, fragments, extra query
  parameters, encoded alternatives, trailing-dot hosts, other ports, locale
  paths, whitespace, and controls are rejected.

| Target | Canonical listing URL |
| --- | --- |
| Android | `https://play.google.com/store/apps/details?id=APPLICATION_ID` |
| iOS | `https://apps.apple.com/app/idSTORE_ID` |

The Android query is exactly `id` with the configured application ID. The iOS
store ID is an opaque 1–20 digit string, not a number to normalize. A
well-formed canonical listing for a different configured identity is reported
as `update.identity_mismatch`; other unsafe/noncanonical URLs are invalid.
Products must provide their canonical listing URL rather than broaden this
policy to alternate URL forms.

An Android application ID is a dot-separated sequence of labels containing
ASCII letters, digits, or underscores, at most 200 characters. iOS store IDs
contain 1–20 digits and remain strings throughout validation.

Wrong target, path, or current-version inputs are rejected before reading.
Malformed metadata and wrong store identity are distinct from transport
failure. Checking never opens a store; opening never reads metadata or fetches
anything. No raw exception messages, response bodies, or credentials are
returned or logged by the facade.

## Typed outcomes

Results expose fixed codes, not raw errors. Check codes include:

| Outcome | Codes |
| --- | --- |
| Disabled/unconfigured | `update.disabled`, `update.target_not_configured`, `update.reader_not_configured` |
| Current / available | `update.current`, `update.available` |
| Invalid input or response | `update.invalid_target`, `update.invalid_path`, `update.invalid_version`, `update.invalid_metadata`, `update.response_too_large`, `update.invalid_store_url`, `update.identity_mismatch` |
| Transport failure | `update.network_failed` |

Store-open results use `update.opened`, `update.no_handler`,
`update.opener_not_configured`, `update.target_not_configured`, and
`update.open_failed`, with invalid candidate and target errors reported as fixed invalid outcomes. Treat unavailable, invalid,
and failure as different states; a current result is not an error. None of these
outcomes promises store availability, successful installation, or update
completion.

## Activation and removal

1. Keep `SampleApp` disconnected. Compose the enabled facade only in the product
   feature that needs version metadata and a store action. Use the product's
   replaceable application/store identity and real, configured port
   implementations; do not ship placeholder endpoints or fake production ports.
2. Call `check` only at an explicit product decision point. Present an update
   action when the result is available; call `openStore(candidate)` from that
   separate user action, never merely because metadata reports an update.
3. Handle all typed results. A launched store is not an installed update. Keep
   endpoint security, redirect policy, transport limits, store listing setup,
   and product UX with the product integrations that own them.
4. Add network permissions/configuration only if the product's chosen metadata
   transport requires them and only in that explicit product scope. This
   capability itself adds no permission or platform component.

To deactivate, remove the product's capability composition, prompt/action,
reader/opener wiring, endpoint and any product-specific SDK/configuration when
unused. Remove network permission only if no other product feature needs it.
Keep the shared `starterkit_platform` dependency while other capabilities use
it.

## Verification boundary

Focused contract tests are in
[`packages/starterkit_platform/test/app_update_test.dart`](../../packages/starterkit_platform/test/app_update_test.dart);
the facade is in
[`packages/starterkit_platform/lib/app_update.dart`](../../packages/starterkit_platform/lib/app_update.dart).
Unit tests can exercise injected ports and deterministic validation outcomes;
they do not establish a production metadata service, network/redirect policy,
real store launch, listing availability, physical-device behavior, signing,
distribution, installation, or update completion. Those product integrations
remain **NOT RUN** unless separately verified with their actual implementations.
