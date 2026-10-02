# Shared Core foundations

These small contracts are inert values and interfaces. They do not create a
transport, persistence adapter, session manager, dependency container, or app
startup work. Failures are thrown through ordinary `Future<T>` APIs; there is
no generic result or use-case layer.

## Failure and cancellation

`FailureKind` follows the frozen shared contract's 11 values: `validation`,
`unauthorized`, `forbidden`, `notFound`, `conflict`, `network`, `timeout`,
`cancelled`, `server`, `unavailable`, and `unknown`. `AppFailure` exposes only
the kind, a developer-authored lowercase code, and a localization key. Public
strings are limited to 64 safe ASCII characters. The private diagnostic cause
is omitted from `toString`; HTTP and exception mapping never copies source
messages into the public failure.

`CancellationSource.cancel()` synchronously marks its token cancelled, invokes
each active listener once, clears registrations, and is idempotent. A late
listener runs immediately. The returned unsubscribe callback is safe to invoke
repeatedly and can suppress a listener that has not yet been delivered.

## Configuration

`AppConfig.fromEnvironment` parses `environment`, optional `baseEndpoint`, and
optional `useMock` (`true`/`false`, default false). A missing endpoint is valid
until an API client needs one. `production` requires HTTPS and rejects mock
behavior; `mock` requires `useMock=true`. Endpoints with user info, query,
fragment, unsafe authority characters, missing host, or unsupported schemes are
rejected visibly. Nothing reads process globals or compile-time secrets.

## Logging

`Logger` has `debug`, `info`, `warning`, and `error` methods. `SafeLogger` sends
only safe event identifiers and allowlisted primitive fields to an injected
vendor-neutral sink. Field names are normalized before filtering; sensitive
substrings such as token, authorization, cookie, password, secret, API key, and
credential are dropped. Keys that collide after normalization are all
discarded. Strings must be short safe identifiers; arbitrary objects, URI,
exceptions, and body-like fields are never stringified or forwarded. Nested
payloads have depth 3, 16 fields/items per collection, and a conservative 4 KiB
serialized-payload budget. Sink errors are best-effort and do not escape.

## API boundary

`ApiMethod`, `ApiRequest`, `ApiResponse`, `AuthorizationProvider`, and
`ApiClient` are contracts only. A request has a relative path, separate copied
query/header maps, optional copied bytes, and `authenticated=false` by default.
Request bounds are URI 2 KiB, body 256 KiB, 32 headers, and 16 KiB aggregate
header text. Unsafe paths, normalized duplicate headers, and transport-managed
headers (cookies, Host, framing, connection, and proxy fields) are rejected.
Responses copy bytes and multi-value headers, bounded to 1 MiB, 128 header
values, and 32 KiB aggregate header text. `ApiClient.baseEndpoint` is a
side-effect-free property; `execute` accepts optional cancellation and timeout.
There is no transport implementation or implicit credential restore here.

The optional authorization seam is
`Future<String?> Function(CancellationToken cancellation)`. Its caller must
choose explicitly whether and when to invoke it for an authenticated request.

## Storage and session values

`PreferenceStore` is for non-sensitive strings; missing values are `null`,
failures throw, and UTF-8 values are capped at 4 KiB. `SecureStore` reads and
writes copied `Uint8List` values capped at 64 KiB; missing values are `null`
and failures throw. Adapters use `copyPreferenceValue` and `copySecureValue` to
apply these bounds and defensive-copy rules.

`LogoutIntentStore` consists only of `readPending`, `markPending`, and `clear`.
`Credential` copies 1..65,536 bytes and provides explicit copied access for
authorization or storage boundaries; its string form is redacted.
`SessionState` is a sealed observable value (`unknown`, `signedOut`, `signedIn`,
or safe failure); signed-in state never contains a credential. No restore or
session behavior is implemented by this contract layer.
