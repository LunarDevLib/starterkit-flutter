# Social Login

## Status and boundary

- Classification: Optional Dart OAuth authorization-code + PKCE service
- Default connected: No
- Bundled provider SDK, browser adapter, authorization endpoint, or credentials: None
- Provider registration, real system-browser/callback flow, backend, token storage,
  devices, signing, and iOS 13 runtime: **NOT RUN**

`StarterSocialLoginService` performs one explicit authorization-code flow through
product-supplied browser and token-transport ports. The default `SampleApp` does
not import, construct, or invoke it. Construction is inert; `enabled` defaults
to false, and no callback, browser, transport, or random source is accessed
until a product explicitly calls `signIn()`.

This is SDK-free, not dependency-free: the existing platform package declares
the Dart `crypto` library for SHA-256 PKCE challenge generation. No provider or
authentication SDK, native adapter, embedded WebView, default OAuth connection,
or production port implementation is included. Products must provide a real
system-browser implementation and configured token transport.

The service does not save tokens, identify users, refresh/revoke tokens, manage
sessions, or provide consent/UI. It has no automatic sign-in, global session,
retry, offline queue, or background flow. The provider remains responsible for
validating PKCE and the registered redirect.

## API and product ports

```dart
import 'package:starterkit_platform/starterkit_platform.dart';

final service = StarterSocialLoginService(
  enabled: true,
  configuration: productOAuthConfiguration,
  browser: productSystemBrowser, // Must use a system browser, not WebView.
  transport: productTokenTransport,
);

// Call from a deliberate user action, never during app/bootstrap construction.
Future<void> signInFromUserAction() async {
  final result = await service.signIn();
  if (result.kind == SocialLoginKind.authenticated) {
    // Hand the token to explicitly configured product-owned secure storage.
  }
}

// A separate product action may cancel the active browser flow.
Future<void> cancelFromUserAction() async {
  final result = await service.cancel();
}
```

`OAuthConfiguration` takes required raw `authorizationEndpoint`,
`tokenEndpoint`, `redirectUri`, `clientId`, and `allowedHosts`, plus an optional
`returnPath` defaulting to empty. Raw URI strings are retained for validation
before parsing; the host set is copied. Client IDs are public identifiers, not
client secrets. They and callback scheme/authority/path are product
configuration and must be replaceable; no template identity is embedded.

`OAuthBrowserAuthentication.authenticate(Uri authorizationUri, String
callbackScheme)` returns the raw callback string. Its `cancel()` future is an
acknowledgement that browser teardown has completed. The product must use a
system browser and handle actual OS callback registration/delivery. This package
does not supply a browser implementation or prove a registered scheme will be
delivered by the OS.

Normal `authenticate` completion or failure must also mean that browser session
has finished. This contract and cancellation acknowledgement prevent cleanup of
an old session from interfering with a new attempt.

`OAuthTokenTransport` exposes `Uri get baseEndpoint` and
`Future<OAuthTokenResponse> execute(OAuthTokenRequest request)`. Requests have a
relative path, immutable copied body, fixed POST method,
`application/x-www-form-urlencoded` content type, and JSON accept header. A
response has an integer status and immutable copied body bytes. The product
owns TLS, redirect behavior, credentials, timeouts, request/body acquisition
limits, actual routing, provider configuration, and server-side PKCE checks.
The getter's URI validation cannot prove the transport honors that URI or those
network policies.

An authenticated result alone contains an immutable `OAuthToken` with
`accessToken`, canonicalized Bearer `tokenType`, and optional integer
`expiresIn`. No token-bearing `toString`, logging, or automatic persistence is
provided.

## Configuration and endpoint validation

- Authorization and token endpoint strings are each at most 2048 UTF-8 bytes.
  They must be canonical HTTPS URLs with lowercase ASCII DNS hosts present in
  the exact `allowedHosts` set (at most 16 valid DNS names, labels ≤63 and
  hosts ≤253 bytes; no wildcards),
  valid ports 1–65535, and safe ASCII path segments
  (`[A-Za-z0-9._~-]+`). Userinfo, query, fragment, empty raw `?`/`#`, encoded
  escapes, dot segments, whitespace, controls, malformed Unicode, backslashes,
  and credentials are rejected.
- The redirect URI is a raw canonical custom-scheme URI: lowercase scheme
  matching `[a-z][a-z0-9+.-]*`, not HTTP(S); exact DNS authority; no port,
  userinfo, query, fragment, encoded alternatives, or dot segments; safe ASCII
  slash-path segments only. Configure and register this product-owned callback
  consistently with the provider. Scheme registration alone is not proof of
  OS callback delivery or uniqueness.
- `clientId` is nonempty, at most 128 UTF-8 bytes, and rejects controls and
  malformed Unicode. It is a public client identifier; never configure an app
  secret in a mobile client.
- Optional `returnPath` is omitted when empty. If supplied, it is a safe
  root-relative path of at most 128 bytes, with no authority or dot segments.

Raw spelling is validated before URI parsing to preserve evidence against
normalization. The product transport's `baseEndpoint` is checked before browser
launch and freshly before token exchange; its joined relative request must
reproduce the configured token endpoint under the validated base path. The
product port must provide a stable base contract. URI getter validation cannot
enforce actual TLS, redirects, routing, or request acquisition limits.

Relative token paths are joined below the base directory, appending a slash if
the base path lacks one. The transport must use this same joining rule and keep
its execution base stable. A supplied base `Uri` may already have normalized
original spelling; product configuration provenance remains product-owned.

## Authorization, callback, and token bounds

Each flow generates independent 32-byte state and verifier values from
`Random.secure`, encodes them as unpadded base64url, and derives the S256
challenge with `crypto`. There is no injectable production entropy source.
`OAuthPKCE.fromVerifier` is a pure helper for valid RFC verifier strings
(43–128 allowed characters); invalid input raises a fixed `ArgumentError` that
does not echo the verifier. This does not establish provider-side PKCE
enforcement.

The authorization request contains exactly `response_type=code`, `client_id`,
`redirect_uri`, `state`, `code_challenge`, and
`code_challenge_method=S256`; nonempty `return_path` is the only optional
extension. The final authorization URI is at most 4096 UTF-8 bytes. No provider
scopes or arbitrary authorization parameters are added by the service.

The raw callback is at most 4096 UTF-8 bytes and must have no controls, malformed
Unicode, or fragment. Raw scheme, authority, and path must exactly match the
configured redirect before normalization; ports and userinfo are forbidden.
The query has at most four pairs. Pairs are split and percent-decoded
individually with strict escapes/UTF-8; duplicate decoded names and unknown
names are rejected. Only `code`, `state`, `error`, and `error_description` are
accepted. Exactly one matching state is required; code and error cannot coexist;
an error description cannot appear without an error. Provider errors become a
fixed authorization-rejected result without exposing provider prose. A code is
nonempty, at most 2048 bytes, and rejects controls/malformed Unicode.
State comparison uses a fixed-length constant-work algorithm; this is not a
formal timing-proof claim.

Only a fully validated callback causes one token exchange. The bounded
form-encoded body (≤8192 bytes) contains `grant_type`, `client_id`, `code`,
`redirect_uri`, and `code_verifier`; no client secret, provider framework
parameter, refresh/revoke request, retry, token cache, or automatic storage is
added. The response status must be 100–599; non-2xx maps to fixed transport
failure. Response body bytes must be valid byte values. The strict UTF-8 JSON
body is at most 16 KiB and contains exactly
`access_token`, `token_type`, and optional `expires_in`. Token is nonempty,
≤8192 UTF-8 bytes, and control/malformed-Unicode free. Token type must be
Bearer (canonicalized case-insensitively). Optional expiry is an integer—not a
boolean, double, or null—in the range 1–31,536,000 seconds.

## Concurrency, cancellation, and results

Only one flow is active. A concurrent sign-in returns `inProgress`; the attempt
and completion state are published before any product getter or port call.
Disabled/missing configuration makes no port calls. All raw callbacks,
authorization codes, state, verifier, form bodies, provider error text, and
tokens are excluded from logs and failure results. A token is exposed only on
an authenticated result and has no token-bearing string representation or
automatic persistence.

Cancellation invalidates the active attempt and logical state/verifier, settles
the pending sign-in as cancelled even if a browser/token future is hanging, and
calls browser cancellation once. Repeated active cancellation shares the same
future; idle cancellation calls no browser port. Late callbacks/responses are
discarded. The active guard remains held until teardown acknowledgement; cleanup
failure leaves the instance unavailable, and a hanging teardown remains busy.
There is no implicit timeout. Product browser ports must settle cancellation.

Cancellation does not promise to abort an already-dispatched HTTP request,
revoke an issued token, or zeroize every copy in memory/provider stacks. The
product owns secure token storage, cleanup, provider lifecycle, and server-side
revocation. Do not infer those guarantees from a cancelled result.

| Result kind | Fixed code family |
| --- | --- |
| authenticated | `social.authenticated` |
| invalid | `social.invalid_configuration`, `social.invalid_callback`, `social.state_mismatch` |
| unavailable | `social.disabled`, `social.configuration_not_configured`, `social.browser_not_configured`, `social.transport_not_configured`, `social.cleanup_failed` (subsequent sign-in after teardown failure) |
| failure | `social.entropy_failed`, `social.browser_failed`, `social.transport_failed`, `social.authorization_rejected`, `social.token_response_invalid` |
| cancelled / busy | `social.cancelled`, `social.in_progress` |
| cancel idle | `social.idle` |
| cancel cleanup failure | `social.cleanup_failed` |

Missing configuration, malformed callback/token response, provider rejection,
transport failure, cancellation, and concurrent operation are distinct typed
outcomes. Codes are fixed; raw exception/provider messages are not returned.

## Activation and removal

1. Keep the default app disconnected. Compose the enabled service only from an
   explicit sign-in UI action with product-specific endpoints, allowed hosts,
   custom callback, browser adapter, and token transport. Do not use embedded
   WebView or ship an example/fake production provider port.
2. Configure the provider's public client and exact redirect registration; keep
   provider credentials out of the app. Implement a genuine system-browser
   flow and callback handling. Verify OS delivery, PKCE behavior, and exact
   provider configuration in the product's real environment.
3. Supply a transport that enforces origin, TLS/redirect policy, timeouts, and
   acquisition limits. Own secure token storage, logout/revocation, user
   consent, and lifecycle outside this facade. Handle every typed result.
4. Add callback URL registration and network permission only in the consuming
   product, and only when required. Registration and permission configuration
   are not runtime callback/network evidence.

To deactivate, remove sign-in UI/call sites and service/port composition, then
remove unused callback registration, endpoint configuration, and network
permission. Keep `starterkit_platform` while other capabilities use it. Remove
the `crypto` dependency only in a separately scoped change if no remaining
capability requires it.

## Verification boundary

Focused Dart contract tests are in
[`packages/starterkit_platform/test/social_login_test.dart`](../../packages/starterkit_platform/test/social_login_test.dart);
the service and API are in
[`packages/starterkit_platform/lib/social_login.dart`](../../packages/starterkit_platform/lib/social_login.dart).
Tests may cover deterministic PKCE vectors, strict validation, inert defaults,
concurrency, cancellation, and stale-result fences; this documentation does not
claim any test count or pass result. They do not establish provider registration,
real browser UX/callback delivery, server PKCE enforcement, TLS/backend behavior,
token storage/revocation, device behavior, signing, distribution, or iOS 13
runtime. Those production integrations remain **NOT RUN** until independently
verified using their real implementations.
